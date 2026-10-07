# 스마트팜 시연용 실행 스크립트 (Windows)
#  - 모의 RMU 2대 (8080: 방울토마토 1동, 8081: 상추 2동)
#  - 웹 앱 (5000번 포트, build/web이 없으면 먼저 빌드)
# 종료: 이 창에서 Enter

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# Python 찾기 (python → py 순서)
$py = $null
foreach ($cand in @("python", "py")) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notlike "*WindowsApps\python.exe") { $py = $cmd.Source; break }
}
if (-not $py) {
    $found = Get-ChildItem "$env:LOCALAPPDATA\Python" -Recurse -Filter python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $py = $found.FullName }
}
if (-not $py) { Write-Host "Python을 찾을 수 없습니다. Python을 설치하세요." -ForegroundColor Red; Read-Host; exit 1 }

# 웹 앱이 빌드되어 있지 않으면 빌드
$web = Join-Path $root "app\build\web"
if (-not (Test-Path (Join-Path $web "index.html"))) {
    Write-Host "웹 앱을 빌드합니다 (처음 한 번, 1분 정도)..."
    Push-Location (Join-Path $root "app"); flutter build web; Pop-Location
}

# 이미 켜져 있는 포트는 건너뛴다
function PortBusy($port) { [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) }

$procs = @()
foreach ($p in @(@{port=8080; name="방울토마토 1동"}, @{port=8081; name="상추 2동"})) {
    if (PortBusy $p.port) { Write-Host "포트 $($p.port)은 이미 사용 중 (기존 RMU 사용)"; continue }
    $procs += Start-Process -PassThru -WindowStyle Minimized -FilePath $py `
        -ArgumentList @("-u", "rmu\server.py", "--port", $p.port, "--farm-name", "`"$($p.name)`"")
}
if (-not (PortBusy 5000)) {
    $procs += Start-Process -PassThru -WindowStyle Minimized -FilePath $py `
        -ArgumentList @("-m", "http.server", "5000", "--bind", "0.0.0.0", "-d", "`"$web`"")
}
Start-Sleep 2

$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.PrefixOrigin -ne "WellKnown" } |
    Select-Object -ExpandProperty IPAddress

Write-Host ""
Write-Host "==== 스마트팜 시연 실행 중 ====" -ForegroundColor Green
Write-Host "PC 브라우저:  http://localhost:5000"
foreach ($ip in $ips) { Write-Host "폰(같은 와이파이): http://${ip}:5000   /  APK 앱의 RMU 주소: ${ip}:8080, ${ip}:8081" }
Write-Host "앱에서 설정 > 농장 연결 > '예시 농장 추가 (개발용)'을 누르면 두 농장이 연결됩니다."
Write-Host "Windows 방화벽 창이 뜨면 '허용'을 눌러야 폰에서 접속됩니다."
Write-Host "확인 순서는 '확인_체크리스트.md'를 보세요."
Write-Host ""
Start-Process "http://localhost:5000"
Read-Host "종료하려면 Enter"
foreach ($proc in $procs) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Write-Host "종료했습니다."
