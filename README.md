# 스마트팜 RMU (캡스톤 디자인)

SNMP v2c 기반 스마트팜 환경감시장치(RMU, 라즈베리파이 4B)를 스마트폰 앱으로 감시·제어합니다.
자세한 요구사항·규칙·임시 결정 사항은 **CLAUDE.md**에 있습니다.

## 파일 하나로 바로 보기 (v3)

`v3/스마트팜 RMU 앱 v3 (실제 앱 체험).html`을 Chrome·Edge로 열면 설치·서버 없이 실제 앱이 열립니다 (약 15MB, 데모 모드).
메신저 미리보기에서는 안 열릴 수 있으니 저장한 뒤 브라우저로 여세요.

## 서버 없이 바로 체험 (데모 모드)

앱(APK·웹) 첫 화면의 **"데모 농장으로 바로 체험"** 또는 설정 > 농장 연결 > **"데모 농장 추가"**를 누르면
앱 안의 모의 RMU(`app/lib/demo/demo_rmu.dart`, `rmu/rmu_model.py`를 옮긴 것)로 동작합니다.
PC·와이파이 연결 없이 폰 하나로 시나리오 1~22를 확인할 수 있습니다. 관리자 계정은 모의 서버와 같습니다.

## 바로 실행 (Windows)

1. Python 3 설치 (Flutter는 필요 없음: 미리 빌드한 웹 앱 `release/web`을 사용)
2. `시작하기.bat` 더블클릭 → 모의 RMU 2대 + 웹 앱이 켜지고 브라우저가 열림
3. 앱에서 설정 > 농장 연결 > "예시 농장 추가 (개발용)"
4. `확인_체크리스트.md` 순서대로 시나리오 1~22 확인

## 폴더

| 폴더/파일 | 내용 |
|---|---|
| `rmu/` | RMU 서버 (PC에서는 모의, 라즈베리파이에서는 `--hardware`로 실물). 설치: `rmu/SETUP_PI.md` |
| `app/` | Flutter 앱 (웹·안드로이드) |
| `oids.json` | 이름 ↔ OID (유일한 OID 정의 위치) |
| `SMARTFARM-MIB.mib` | `python rmu/gen_mib.py`로 생성 |

## 테스트

```
cd rmu && python -m unittest test_scenarios test_snmp test_storage test_push -v
cd app && flutter test
```

## 안드로이드 APK

바로 설치: `release/smartfarm-rmu-arm64.apk` (대부분의 폰), 아주 오래된 폰은 `release/smartfarm-rmu-armv7.apk`.
안드로이드 7.0 이상. 설치할 때 "출처를 알 수 없는 앱" 허용이 필요합니다.

직접 빌드:

```
cd app
flutter build apk --release
```
→ `app/build/app/outputs/flutter-apk/app-release.apk`를 폰에 설치. 농장 연결에서 PC(또는 라즈베리파이) IP를 입력합니다.
