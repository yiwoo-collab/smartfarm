# 라즈베리파이 게이트웨이 설치 (v3.0, 1단계)

라즈베리파이 4B + Raspberry Pi OS Lite 기준입니다. PC에서 쓰는 모의 서버와 **같은 코드**를 옵션만 바꿔 실행합니다.

```
[RMU 실물] ──SNMP Get/Trap──> [라즈베리파이: server.py] <──REST── [앱]
                                  └ 직결 감지기: 온습도·화재·수위, 릴레이
```

- `--rmu-host`: RMU 실물을 SNMP v2c로 5초마다 조회하고, RMU의 `addTrap`(R.4.1)에 `라즈베리파이IP:1162`를 써서 Trap을 받습니다.
- `--hardware`: 라즈베리파이에 직접 연결한 감지기(`hardware_config.json`)와 릴레이를 씁니다.
- 둘 중 하나라도 쓰면 **실사용(live) 모드**로 시작합니다 (앱 설정 > 농장 관리 > AI 모드에서 바꿀 수 있음).
- 연결하지 않은 감지기는 읽기 실패로 "센서 오류", 감지기가 없는 항목(CO2·토양수분·양분)은 "정보없음"으로 표시됩니다.

## 1. RMU 먼저 점검 (네트워크만 있으면 됨)

라즈베리파이(또는 같은 네트워크의 PC)에서:

```bash
python3 rmu/rmu_check.py --host <RMU IP>            # 전체 항목: raw 값과 변환값 (예: temp1 750 → 25.0℃)
python3 rmu/rmu_check.py --host <RMU IP> --trap     # addTrap 등록 후 30초 동안 Trap 기다리기
```

- 읽기 커뮤니티 `public`, 쓰기 커뮤니티 `private`이 기본값입니다 (`--community`, `--write-community`로 변경).
- 값이 이상하면 `oids.json`의 `scale`/`offset`을 고칩니다 (코드에는 숫자를 쓰지 않음).
- Trap이 안 오면: RMU의 addTrap 값(`IP:포트`), 라즈베리파이 방화벽(UDP 1162), RMU 펌웨어가 addTrap을 지원하는지 교수님께 확인.

## 2. 직결 감지기 배선 (제안, `hardware_config.json`에서 변경)

| 장치 | 연결 | 비고 |
|---|---|---|
| 온습도감지기 | BME280: I2C SDA=GPIO2, SCL=GPIO3, 주소 0x76 / DHT22: GPIO4 | `humidity_sensor.type`. 연결 방식 확인 필요 |
| 화재감지기 | 접점 출력 → GPIO5 | `active_low` true면 LOW일 때 화재 (제안) |
| 수위감지기 | 플로트 스위치 → GPIO6 (`digital`) 또는 ADS1115 A0 (`analog`) | 출력 형식·의미 확인 필요. analog는 `empty_raw`, `full_raw` 보정 |
| 라즈베리파이 CPU 온도 | `/sys/class/thermal/thermal_zone0/temp` | 자동 (`vcgencmd measure_temp`와 같은 값) |
| 릴레이: 메인 환풍기 / 예비 환풍기 / 쿨링팬 / 펌프 | GPIO 17 / 27 / 22 / 23 (BCM) | 팬·펌프는 **외부 전원**. 220V 기기는 연결하지 않는다 |
| (선택) 팬 회전 신호 | `fan_tach.pins` | 3선/4선 팬만. 없으면 null |

온도(temp1)와 전원(acv1·ach1)은 **RMU 쪽 감지기**라 라즈베리파이에 배선하지 않습니다.

## 3. 설치

```bash
sudo raspi-config nonint do_i2c 0          # I2C 켜기 (BME280·ADS1115를 쓸 때)
sudo apt update && sudo apt install -y python3-venv snmp i2c-tools
i2cdetect -y 1                             # 0x76(BME280), 0x48(ADS1115)이 보이면 배선 정상

sudo mkdir -p /opt/smartfarm && sudo chown pi:pi /opt/smartfarm
# 프로젝트 폴더(oids.json, rmu/)를 /opt/smartfarm 에 복사
python3 -m venv --system-site-packages /opt/smartfarm/venv
/opt/smartfarm/venv/bin/pip install -r /opt/smartfarm/rmu/requirements-pi.txt
/opt/smartfarm/venv/bin/python /opt/smartfarm/rmu/check_hardware.py    # 직결 감지기·릴레이 점검
```

RMU와의 SNMP 통신은 표준 라이브러리(`snmp_lite.py`)라 따로 설치할 것이 없습니다.
라즈베리파이 고정 IP는 공유기의 DHCP 예약으로 정합니다 (RMU addTrap에 이 IP가 들어갑니다).

## 4. 관리자 계정

`/opt/smartfarm/rmu/admin.json`을 만들어 앱 로그인 계정을 정합니다 (없으면 개발용 계정으로 동작하고 경고가 나옵니다).

```json
{"username": "관리자 아이디", "password": "비밀번호"}
```

## 5. 직접 실행해 보기

```bash
cd /opt/smartfarm/rmu
/opt/smartfarm/venv/bin/python server.py --hardware --rmu-host <RMU IP>
```

시작 로그에서 직결 장치, RMU 조회 성공, addTrap 등록 결과를 확인합니다.
PC 브라우저에서 `http://<라즈베리파이 IP>:8080/api/status`가 보이면 앱의 농장 연결에 `<IP>:8080`을 입력합니다.
앱 세부 정보 화면에 "RMU 연결됨 (SNMP v2c)"이 보이면 정상입니다.

## 6. 자동 실행

```bash
sudo cp smartfarm-rmu.service /etc/systemd/system/      # --rmu-host를 RMU 주소로 수정
sudo systemctl daemon-reload && sudo systemctl enable --now smartfarm-rmu
journalctl -u smartfarm-rmu -f                           # 로그
```

## 7. (선택) 우리 확장 MIB를 SNMP로 제공

NMS에서 라즈베리파이 값(습도·수위·화재·등급 등)도 SNMP로 보려면 snmpd를 켭니다. RMU 실물 MIB는 RMU가 직접 응답합니다.

```bash
sudo apt install -y snmpd
sudo cp snmpd.conf.example /etc/snmp/snmpd.conf          # 커뮤니티·허용 대역 수정
sudo systemctl restart snmpd

snmpwalk -v2c -c public <라즈베리파이 IP> .1.3.6.1.4.1.61123730.1.6
snmpget  -v2c -c public <라즈베리파이 IP> .1.3.6.1.4.1.61123730.1.6.1.1.0    # 습도 (0.1% 단위: 652 = 65.2%)
snmpget  -v2c -c public <라즈베리파이 IP> .1.3.6.1.4.1.61123730.1.6.1.13.0   # 알람 등급
```

NMS에 넣을 MIB: 교수님 PELKOREA-RMU-MIB + 프로젝트 폴더의 `SMARTFARM-EXT-MIB.mib`.
우리 경보를 NMS로도 보내려면 `--trap-host <NMS IP>` (farmAlarm Trap). OID가 바뀌면 `oids.json`만 고치고 `python rmu/gen_mib.py`로 MIB를 다시 만듭니다.

## 8. 앱이 꺼져 있을 때 알림 (선택)

`smartfarm-rmu.service`의 ExecStart 끝에 `--push-url <ntfy 토픽 URL> --farm-name "방울토마토 1동"`을 붙이면
경보가 ntfy로 갑니다. 폰에 ntfy 앱을 설치하고 같은 토픽을 구독하세요.

## 9. 실물 / 시뮬레이션 / 정보없음 (CLAUDE.md 5-2)

- RMU 실물: 온도(temp1), 온도2, AC 전압·주파수(acv1·ach1), 전면 도어, UPS, 알람 코드(Trap·alarm)
- 라즈베리파이 실물: 습도(+온습도감지기 온도), 화재, 수위, CPU 온도, 환풍기 2개·쿨링팬·펌프 릴레이, (선택) 팬 회전 감지
- 시뮬레이션: 에어컨, 히터, 덮개, 전구, CCTV 움직임, 온실 전체 전력, 환풍기·쿨링팬 장비 온도
- 정보없음: CO2, 토양수분, 양분 (감지기를 붙이면 `oids.json`의 `available`을 true로)
- 앱의 시뮬레이션은 실사용 모드에서도 동작합니다. 시뮬레이션 중인 항목은 실제 값 대신 시뮬레이션 값을 쓰고, 정상으로 돌리면 다시 실제 값을 씁니다.

## PC에서 미리 연습 (RMU 없이)

```bash
python rmu/mock_pelkorea_rmu.py                                   # 교수님 RMU 흉내 (UDP 1161, HTTP 8091)
python rmu/server.py --rmu-host 127.0.0.1 --rmu-port 1161         # 게이트웨이 (8080)
python rmu/rmu_check.py --host 127.0.0.1 --port 1161 --trap       # 점검 도구 연습
```
