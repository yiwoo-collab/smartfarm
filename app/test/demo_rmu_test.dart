// 앱 안 데모 RMU가 rmu/test_scenarios.py 와 같은 결과를 내는지 확인한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartfarm_app/demo/demo_rmu.dart';

void main() {
  late DemoRmu m;
  late DateTime now;

  void tick() {
    now = now.add(const Duration(seconds: 1));
    m.tick(now);
  }

  setUp(() {
    m = DemoRmu(); // 타이머 없이 직접 tick
    now = DateTime(2026, 10, 7, 12);
    for (var i = 0; i < 5; i++) {
      tick();
    }
  });

  void runUntil(bool Function() check, String what, [int max = 300]) {
    for (var i = 0; i < max; i++) {
      tick();
      if (check()) return;
    }
    fail('$max초 안에 조건을 만족하지 않음: $what');
  }

  String actions() => m.events.expand((e) => e['actions'] as List).join(' / ');

  test('시나리오 1: 정상', () {
    for (var i = 0; i < 120; i++) {
      tick();
    }
    expect(m.alarmLevel(), 0);
    expect(m.events, isEmpty);
  });

  test('시나리오 2: 고온 → 냉방 → 복구', () {
    m.simulate('high_temp', {});
    runUntil(() => m.alarmLevel() == 2, '고온 경보');
    expect(m.control['aircon_setpoint'], 22.0);
    expect(m.control['cooling_fan'], 1);
    expect(actions(), contains('25.0℃에서 22.0℃로 낮췄습니다'));
    runUntil(() => m.alarmLevel() == 0, '복구');
    expect(m.control['aircon_setpoint'], 25.0);
    expect(m.control['cooling_fan'], 0);
  });

  test('시나리오 3: 고온 지속 → 긴급, 히터·전구 정지', () {
    m.simulate('high_temp', {'severe': true});
    runUntil(() => m.alarmLevel() == 3, '고온 긴급');
    expect(m.control['cooling_fan'], 1);
    expect(m.control['lights'], 0);
  });

  test('시나리오 4·5: 저온 난방 복구 / 긴급', () {
    m.simulate('low_temp', {});
    runUntil(() => m.alarmLevel() == 2, '저온 경보');
    expect(m.control['heater'], 1);
    runUntil(() => m.alarmLevel() == 0, '복구');
    m.simulate('low_temp', {'severe': true});
    runUntil(() => m.alarmLevel() == 3, '저온 긴급');
    expect(m.control['heater'], 1);
    expect(m.control['aircon'], 0);
  });

  test('시나리오 7: 메인 환풍기 고장 → 예비 대체, 수리 후 사용자 전환', () {
    m.simulate('main_fan_fail', {});
    tick();
    expect(m.alarmLevel(), 2);
    expect(m.control['backup_fan'], 1);
    m.simulate('fan_repair', {});
    tick();
    expect(m.control['main_fan'], 0); // 자동으로 되돌리지 않음
    m.applyControl('restore_main_fan', null);
    expect(m.control['main_fan'], 1);
  });

  test('시나리오 9: 토양 건조 → 펌프', () {
    m.simulate('soil_dry', {});
    tick();
    expect(m.control['pump'], 1);
    runUntil(() => m.alarmLevel() == 0, '토양 복구', 60);
    expect(m.control['pump'], 0);
  });

  test('시나리오 14: 야간 모드', () {
    m.simulate('night_on', {});
    tick();
    expect(m.control['cover'], 1);
    expect(m.control['lights'], 0);
  });

  test('시나리오 21: 자동 모드 잠금', () {
    expect(() => m.applyControl('heater', 1), throwsA(isA<DemoRmuError>()));
    m.applyControl('control_mode', 0);
    m.applyControl('heater', 1);
    expect(m.control['heater'], 1);
  });

  test('시나리오 22: AI 선가동, 경보 없이 지나감', () {
    m.simulate('slow_heat', {});
    runUntil(() => m.aiActive, 'AI 시작', 60);
    expect(m.values['temperature'], lessThan(30));
    expect(m.ai['reason'] as String, contains('상한'));
    var maxLevel = 0;
    runUntil(() {
      maxLevel = maxLevel > m.alarmLevel() ? maxLevel : m.alarmLevel();
      return !m.aiActive;
    }, 'AI 종료');
    expect(maxLevel, 0);
  });

  test('REST 흉내: 로그인, 제어 권한, 통신 두절, 기록', () {
    expect(
      () => m.handle('POST', '/api/control', {
        'device': 'pump',
        'value': 1,
      }, null),
      throwsA(isA<DemoRmuError>().having((e) => e.statusCode, 'code', 401)),
    );
    final token =
        m.handle('POST', '/api/login', {
              'username': 'admin',
              'password': 'admin1234',
            }, null)['token']
            as String;
    m.handle('POST', '/api/control', {
      'device': 'control_mode',
      'value': 0,
    }, token);
    expect(
      m.handle('GET', '/api/status', null, null)['control']['control_mode'],
      0,
    );

    final events = m.handle('GET', '/api/events?since=0', null, null);
    expect(events['last_id'], greaterThan(0));

    expect(m.handle('GET', '/api/crops', null, null).keys, contains('방울토마토'));

    m.simulate('comm_loss', {'seconds': 30});
    expect(
      () => m.handle('GET', '/api/status', null, null),
      throwsA(isA<DemoRmuError>().having((e) => e.statusCode, 'code', 503)),
    );
    m.simulate('comm_restore', {});
    expect(
      m.handle('GET', '/api/status', null, null)['alarm_level'],
      isA<int>(),
    );
  });
}
