# 라즈베리파이 RMU 설치 (1단계)

라즈베리파이 4B + Raspberry Pi OS Lite 기준입니다. PC에서 쓰는 모의 RMU와 **같은 코드**를 `--hardware` 옵션으로 실행합니다.
연결하지 않은 센서는 자동으로 시뮬레이션 값을 쓰므로, 센서를 하나씩 붙여 가며 확인할 수 있습니다.

## 1. 배선 (제안, `hardware_config.json`에서 변경)

| 장치 | 연결 | 비고 |
|---|---|---|
| BME280 (온습도) | I2C SDA=GPIO2, SCL=GPIO3, 주소 0x76 | 3.3V |
| ADS1115 + 토양수분 센서 | I2C 주소 0x48, A0 | 보정값 `soil_dry_raw`, `soil_wet_raw` 측정 필요 |
| INA219 (공급 전압·전류) | I2C 주소 0x40 | 외부 전원(팬·펌프) 쪽 + 선에 직렬 연결, 약 26V·3.2A 한도 |
| 릴레이: 메인 환풍기 / 예비 환풍기 / 쿨링팬 / 펌프 | GPIO 17 / 27 / 22 / 23 (BCM) | 팬·펌프는 **외부 전원** 사용. 220V 기기는 연결하지 않는다 |
| (선택) 팬 회전 신호 | `fan_tach.pins`에 핀 번호 | 3선/4선 팬만. 없으면 null |

## 2. 설치

```bash
sudo raspi-config nonint do_i2c 0          # I2C 켜기
sudo apt update && sudo apt install -y python3-venv snmpd snmp i2c-tools
i2cdetect -y 1                             # 0x40, 0x48, 0x76이 보이면 배선 정상

sudo mkdir -p /opt/smartfarm && sudo chown pi:pi /opt/smartfarm
# 프로젝트 폴더(oids.json, rmu/)를 /opt/smartfarm 에 복사
python3 -m venv --system-site-packages /opt/smartfarm/venv
/opt/smartfarm/venv/bin/pip install -r /opt/smartfarm/rmu/requirements-pi.txt
```

`/opt`에 두는 이유: snmpd(Debian-snmp 사용자)가 `/home/pi`에는 들어갈 수 없기 때문입니다.

## 3. 관리자 계정

`/opt/smartfarm/rmu/admin.json`을 만들어 앱 로그인 계정을 정합니다 (없으면 개발용 계정으로 동작하고 경고가 나옵니다).

```json
{"username": "관리자 아이디", "password": "비밀번호"}
```

## 4. 직접 실행해 보기

```bash
cd /opt/smartfarm/rmu
/opt/smartfarm/venv/bin/python server.py --hardware
```

시작할 때 `실물 연결: bme280, ads1115, ...` 줄에서 어떤 장치가 잡혔는지 확인합니다.
PC 브라우저에서 `http://<라즈베리파이 IP>:8080/api/status` 가 보이면 앱의 농장 연결에 `<IP>:8080`을 입력합니다.

## 5. 자동 실행과 SNMP

```bash
sudo cp smartfarm-rmu.service /etc/systemd/system/      # --trap-host를 NMS 주소로 수정
sudo systemctl daemon-reload && sudo systemctl enable --now smartfarm-rmu

sudo cp snmpd.conf.example /etc/snmp/snmpd.conf          # 커뮤니티·허용 대역 수정
sudo systemctl restart snmpd
```

## 6. SNMP 확인 (같은 네트워크의 PC 또는 라즈베리파이에서)

```bash
# 현재값 전체 (스칼라는 .0을 붙여 조회)
snmpwalk -v2c -c public <IP> .1.3.6.1.4.1.99999.1
# 온도 (0.1℃ 단위: 253 = 25.3℃)
snmpget -v2c -c public <IP> .1.3.6.1.4.1.99999.1.1.1.1.1.0
# 제어 모드를 수동(0)으로 → 쿨링팬 켜기 (자동 모드에서는 inconsistentValue로 거부)
snmpset -v2c -c private <IP> .1.3.6.1.4.1.99999.1.1.3.10.0 i 0
snmpset -v2c -c private <IP> .1.3.6.1.4.1.99999.1.1.3.3.0 i 1
# Trap 받기 (NMS 쪽, /etc/snmp/snmptrapd.conf 에 'disableAuthorization yes')
sudo snmptrapd -f -Lo
```

NMS에 MIB를 넣으면 이름으로 보입니다: 프로젝트 폴더의 `SMARTFARM-MIB.mib`.
OID가 바뀌면 `oids.json`만 고치고 `python rmu/gen_mib.py`로 MIB를 다시 만듭니다.

## 7. 앱이 꺼져 있을 때 알림 (선택)

`smartfarm-rmu.service`의 ExecStart 끝에 `--push-url <ntfy 토픽 URL> --farm-name "방울토마토 1동"`을 붙이면
경보가 ntfy로 갑니다. 폰에 ntfy 앱을 설치하고 같은 토픽을 구독하세요.

## 8. 실물 / 시뮬레이션 구분 (CLAUDE.md 9장)

- 실물: 온습도, 토양수분, 공급 전압·전류, RMU 온도, 환풍기 2개·쿨링팬·펌프 릴레이, (선택) 팬 회전 감지
- 시뮬레이션: 에어컨, 히터, 덮개, 전구, CCTV 움직임, CO2, 양분, 온실 전체 전력, 팬·쿨링팬 장비 온도
- 앱의 설정 > 시뮬레이션은 실물에서도 동작합니다. 시뮬레이션 중인 센서는 실물 값 대신 시뮬레이션 값을 쓰고, 정상 복귀하면 다시 실물 값을 씁니다.
