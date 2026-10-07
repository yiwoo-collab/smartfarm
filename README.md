# 스마트팜 RMU (캡스톤 디자인)

SNMP v2c 기반 스마트팜 환경감시장치(RMU, 라즈베리파이 4B)를 스마트폰 앱으로 감시·제어합니다.
자세한 요구사항·규칙·임시 결정 사항은 **CLAUDE.md**에 있습니다.

## 바로 실행 (Windows)

1. Python 3, Flutter 설치 (웹 빌드가 이미 있으면 Flutter 없이도 실행됨)
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

```
cd app
flutter build apk --release
```
→ `app/build/app/outputs/flutter-apk/app-release.apk`를 폰에 설치. 농장 연결에서 PC(또는 라즈베리파이) IP를 입력합니다.
