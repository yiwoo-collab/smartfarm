# 모바일 스마트팜 앱 v3.0 (캡스톤 디자인)

SNMP v2c 기반 스마트팜 환경감시장치를 스마트폰 앱으로 감시·제어합니다.
**RMU 실물(교수님 MIB) + 라즈베리파이 4B(게이트웨이) + 공유기 + 핸드폰 앱** 구성입니다.
라즈베리파이가 RMU를 SNMP로 조회하고 Trap을 받으며, 직접 연결한 감지기(습도·화재·수위)와 합쳐 등급을 계산합니다.
앱은 라즈베리파이의 REST API에만 접속합니다. 자세한 요구사항·규칙·임시 결정 사항은 **CLAUDE.md**에 있습니다.

## 파일 하나로 바로 보기 (v3)

`v3/스마트팜 RMU 앱 v3 (실제 앱 체험).html`을 Chrome·Edge로 열면 설치 없이 실제 앱(v3.0)이 열립니다 (약 15MB).
APK·시작하기.bat과 똑같이 "농장 연결하기" 화면부터 시작합니다.
- 같은 PC에서 `시작하기.bat`을 켰다면: 농장 연결하기 → 예시 농장 추가 (또는 농장 추가에 `localhost` 입력)
- 서버 없이 보려면: 데모 농장으로 바로 체험

메신저 미리보기에서는 안 열릴 수 있으니 저장한 뒤 브라우저로 여세요.

## 서버 없이 바로 체험 (데모 모드)

앱(APK·웹) 첫 화면의 **"데모 농장으로 바로 체험"** 또는 설정 > 농장 연결 > **"데모 농장 추가"**를 누르면
앱 안의 모의 게이트웨이(`app/lib/demo/demo_rmu.dart`, `rmu/rmu_model.py`를 옮긴 것)로 동작합니다.
PC·와이파이 연결 없이 폰 하나로 시나리오 1~29를 확인할 수 있습니다. 관리자 계정: `admin` / `admin1234` (개발용).

## 바로 실행 (Windows)

1. Python 3 설치 (Flutter는 필요 없음: 미리 빌드한 웹 앱 `release/web`을 사용)
2. `시작하기.bat` 더블클릭 → 모의 게이트웨이 2대 + 웹 앱이 켜지고 브라우저가 열림
3. 앱에서 설정 > 농장 연결 > "예시 농장 추가 (개발용)"
4. `확인_체크리스트.md` 순서대로 시나리오 1~29 확인

교수님 RMU를 흉내 내는 모의 RMU까지 띄워 SNMP 조회·Trap을 확인하려면:

```
python rmu/mock_pelkorea_rmu.py
python rmu/server.py --rmu-host 127.0.0.1 --rmu-port 1161
```
→ 브라우저에서 `http://localhost:8091/alarm?code=61` (UPS 배터리 낮음 Trap), `/clear?code=61` (해제)

## 폴더

| 폴더/파일 | 내용 |
|---|---|
| `rmu/` | 라즈베리파이 게이트웨이 (PC에서는 모의, 라즈베리파이에서는 `--hardware --rmu-host`). 설치: `rmu/SETUP_PI.md` |
| `app/` | Flutter 앱 v3.0 (웹·안드로이드) |
| `oids.json` | 이름 ↔ OID, 값 변환(scale/offset), 알람 코드 표 (유일한 OID 정의 위치) |
| `SMARTFARM-EXT-MIB.mib` | 우리 확장 `{ rmu 6 }` MIB, `python rmu/gen_mib.py`로 생성 |
| `release/` | 미리 빌드한 웹 앱과 APK |
| `v3/` | 실제 앱을 HTML 파일 하나로 묶은 체험판 |
| `스마트팜 v1/` | 첫 화면 시안 (smartfarm-app, smartfarm-web HTML) |
| `스마트팜 v1.1/` | 피드백 반영 앱 시안 v2 HTML |
| `스마트팜 v1.2/` | 기획 문서: 모바일 앱 변경 및 시나리오 구상 (한글 .hwp) |

## 테스트

```
cd rmu && python -m unittest test_scenarios test_snmp test_storage test_push -v
cd app && flutter test
```

## 안드로이드 APK

바로 설치: `release/smartfarm-rmu-arm64.apk` (대부분의 폰), 아주 오래된 폰은 `release/smartfarm-rmu-armv7.apk`.
안드로이드 7.0 이상. 설치할 때 "출처를 알 수 없는 앱" 허용이 필요합니다.
농장 연결에는 라즈베리파이(또는 모의 서버를 켠 PC)의 `IP:8080`을 입력합니다.

직접 빌드 (OneDrive 폴더 밖으로 복사해서):

```
cd app
flutter build apk --release --split-per-abi
```
