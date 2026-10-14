// 앱 안 데모 게이트웨이(v3.0)가 rmu/test_scenarios.py 와 같은 결과를 내는지 확인한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartfarm_app/demo/demo_rmu.dart';

void main() {
  late DemoRmu m;
  late DateTime now;

  void tick() {
    now = now.add(const Duration(seconds: 1));
    m.tick(now);
  }

  void ticks(int n) {
    for (var i = 0; i < n; i++) {
      tick();
    }
  }

  setUp(() {
    m = DemoRmu(); // 타이머 없이 직접 tick
    now = DateTime(2026, 10, 14, 12);
    ticks(5);
  });

  void runUntil(bool Function() check, String what, [int max = 300]) {
    for (var i = 0; i < max; i++) {
      tick();
      if (check()) return;
    }
    fail('$max초 안에 조건을 만족하지 않음: $what');
  }

  Set<int> codes() => {for (final c in m.active.values) c['code'] as int};
  String actions() => m.events.expand((e) => e['actions'] as List).join(' / ');

  test('시나리오 1: 정상', () {
    ticks(120);
    expect(m.alarmLevel(), 0);
    expect(m.events.where((e) => e['type'] == 'alarm'), isEmpty);
  });

  test('시나리오 2: 고온 → 냉방 → 복구, 해제 코드 109', () {
    m.simulate('high_temp', {});
    runUntil(() => m.alarmLevel() == 2, '고온 경보');
    expect(m.control['aircon_setpoint'], 22.0);
    expect(m.control['cooling_fan'], 1);
    expect(codes(), contains(9));
    expect(actions(), contains('25.0℃에서 22.0℃로 낮췄습니다'));
    runUntil(() => m.alarmLevel() == 0, '복구');
    expect(m.control['aircon_setpoint'], 25.0);
    final clear = m.events.lastWhere((e) => e['type'] == 'clear');
    expect(clear['code'], 109);
  });

  test('시나리오 3: 고온 지속 → 긴급, 히터·전구 정지', () {
    m.simulate('high_temp', {'severe': true});
    runUntil(() => m.alarmLevel() == 3, '고온 긴급');
    expect(m.control['cooling_fan'], 1);
    expect(m.control['heater'], 0);
    expect(m.control['lights'], 0);
  });

  test('시나리오 3: 값이 갑자기 뛰어도 60초 뒤에 긴급, 복귀 후 AI 오판 없음', () {
    m.sim.stuck = true; // 물리 흉내를 멈추고 값을 직접 고정
    m.values['temperature'] = 35.0;
    ticks(5);
    expect(m.alarmLevel(), 2);
    ticks(40);
    expect(m.alarmLevel(), 2);
    runUntil(() => m.alarmLevel() == 3, '60초 뒤 긴급', 30);
    m.values['temperature'] = 25.0;
    runUntil(() => m.tempState == 'normal', '정상 복귀', 5);
    m.sim.stuck = false;
    ticks(30);
    expect(m.aiActive, isFalse);
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

  test('시나리오 6: 라즈베리파이 온도 주의 (207)', () {
    m.simulate('part_high', {'part': 'pi_temp'});
    runUntil(() => m.alarmLevel() == 1, '라즈베리파이 온도 주의');
    expect(codes(), contains(207));
    runUntil(() => m.alarmLevel() == 0, '복구');
  });

  test('시나리오 7·8: 메인 고장 → 예비 대체, 수리 후 사용자 전환, 둘 다 고장 긴급', () {
    m.simulate('main_fan_fail', {});
    tick();
    expect(m.alarmLevel(), 2);
    expect(m.control['backup_fan'], 1);
    expect(codes(), contains(208));
    m.simulate('fan_repair', {});
    ticks(2);
    expect(m.control['main_fan'], 0); // 자동으로 되돌리지 않음
    m.applyControl('restore_main_fan', null);
    expect(m.control['main_fan'], 1);
    m.simulate('fans_fail', {});
    tick();
    expect(m.alarmLevel(), 3);
  });

  test('시나리오 9: 수위 부족 → 펌프 제한', () {
    m.simulate('water_low', {});
    tick();
    expect(m.active['water_low']!['code'], 202);
    expect(m.control['pump'], 0);
    m.simulate('water_refill', {});
    runUntil(() => !m.active.containsKey('water_low'), '수위 복구');
  });

  test('시나리오 10: 화재 → 긴급, 열원 정지', () {
    m.base['heater'] = 1;
    m.simulate('fire', {});
    tick();
    expect(m.alarmLevel(), 3);
    expect(m.active['fire']!['code'], 203);
    expect(m.control['heater'], 0);
    expect(m.control['lights'], 0);
    final first = m.events.firstWhere((e) => e['key'] == 'fire');
    expect((first['actions'] as List).join(), contains('오감지'));
    m.simulate('fire_clear', {});
    tick();
    expect(m.active.containsKey('fire'), isFalse);
  });

  test('시나리오 11: AC 전압 이상 / 차단', () {
    m.simulate('power_abnormal', {});
    runUntil(() => m.active.containsKey('power'), 'AC 전압 이상');
    expect(m.active['power']!['code'], 1);
    expect(m.status()['power']['power_ok'], isFalse);
    m.simulate('power_cut', {});
    tick();
    expect(m.active['power']!['message'], contains('차단'));
    expect(m.running('main_fan'), isFalse);
    m.simulate('power_restore', {});
    runUntil(() => !m.active.containsKey('power'), '전원 복구');
  });

  test('시나리오 12: 정보없음 (null + nodata, 판정 제외)', () {
    final st = m.status();
    for (final name in ['co2', 'soil_moisture', 'nutrient_ec']) {
      expect(st['sensors'][name], isNull);
      expect(st['states'][name], 'nodata');
    }
    expect(codes(), isNot(contains(204)));
  });

  test('시나리오 13: RMU 두절 흉내 → RMU 항목만 마지막 값 회색', () {
    m.simulate('rmu_offline', {});
    final frozen = m.status()['sensors']['temperature'];
    m.simulate('high_temp', {});
    ticks(60);
    final st = m.status();
    expect(st['states']['temperature'], 'offline');
    expect(st['states']['humidity'], 'ok');
    expect(st['sensors']['temperature'], frozen);
    expect(st['rmu']['connected'], false);
    expect(m.active.containsKey('temp'), isFalse);
    m.simulate('rmu_online', {});
    tick();
    expect(m.status()['states']['temperature'], 'ok');
  });

  test('시나리오 14: 센서 오류는 해당 항목만', () {
    m.simulate('sensor_fault', {'sensor': 'humidity'});
    tick();
    final st = m.status();
    expect(st['sensors']['humidity'], isNull);
    expect(st['states']['humidity'], 'fault');
    expect(st['states']['temperature'], 'ok');
  });

  test('시나리오 15~17: 야간, 움직임 210, 도어 침입, 야간 고온 환기 우선', () {
    m.simulate('night_on', {});
    tick();
    expect(m.control['cover'], 1);
    expect(m.control['lights'], 0);
    m.simulate('motion', {});
    tick();
    expect(codes(), contains(210));
    m.simulate('door_open', {});
    tick();
    expect(m.active['door']!['message'], contains('침입'));
    m.simulate('door_close', {});
    m.simulate('high_temp', {});
    runUntil(() => m.active.containsKey('temp'), '야간 고온');
    expect(m.control['backup_fan'], 1);
    expect(m.control['lights'], 0);
  });

  test('시나리오 24: 자동 모드 잠금', () {
    expect(() => m.applyControl('heater', 1), throwsA(isA<DemoRmuError>()));
    m.applyControl('control_mode', 0);
    m.applyControl('heater', 1);
    expect(m.control['heater'], 1);
  });

  test('시나리오 25: AI 선가동 (데모 자동 실행), 이유 표시', () {
    m.simulate('slow_heat', {});
    runUntil(() => m.aiActive, 'AI 시작', 60);
    expect(m.values['temperature'], lessThan(30));
    expect(m.control['aircon_setpoint'], 22.0);
    expect(m.ai['reason'] as String, contains('상한'));
    final aiEvent = m.events.firstWhere((e) => e['key'] == 'ai');
    expect(aiEvent['ai'], isTrue);
    expect((aiEvent['actions'] as List).join(), contains('판단 이유'));
  });

  test('시나리오 26: 실사용 AI → 쿨링팬만 자동, 에어컨은 제안 → 승인', () {
    m.simulate('ai_live_demo', {});
    expect(m.mode, 'live');
    runUntil(() => m.aiFan, '쿨링팬 자동', 60);
    expect(m.control['cooling_fan'], 1);
    expect(m.control['aircon_setpoint'], 25.0);
    final pending = m.listSuggestions().where((s) => s['status'] == 'pending').toList();
    expect(pending, hasLength(1));
    expect(pending.first['risk'], 'high');
    m.decideSuggestion(pending.first['id'] as int, true);
    expect(m.control['aircon_setpoint'], 22.0);
    expect(
      () => m.decideSuggestion(pending.first['id'] as int, true),
      throwsA(isA<DemoRmuError>().having((e) => e.statusCode, 'code', 409)),
    );
  });

  test('시나리오 27: 센서 불일치·누수·값 고정 (AI 판단)', () {
    m.simulate('sensor_mismatch', {});
    runUntil(() => m.active.containsKey('mismatch'), '센서 불일치', 60);
    expect(m.active['mismatch']!['code'], 209);
    expect(m.active['mismatch']!['ai'], isTrue);
    m.simulate('sensor_match', {});
    runUntil(() => !m.active.containsKey('mismatch'), '불일치 해소', 10);
    m.simulate('water_leak', {});
    runUntil(() => m.active.containsKey('leak'), '누수 의심', 60);
    m.simulate('water_refill', {});
    m.simulate('sensor_stuck', {});
    runUntil(() => m.active.containsKey('stuck'), '값 고정', 200);
  });

  test('시나리오 28: RMU Trap → 등급 계산', () {
    m.simulate('rmu_trap', {'code': 61});
    expect(m.active['rmu:61']!['level'], 2);
    expect(m.events.any((e) => e['key'] == 'rmu_trap'), isTrue);
    m.simulate('rmu_trap_clear', {'code': 61});
    expect(m.active.containsKey('rmu:61'), isFalse);
    m.handleRmuAlarm(98);
    expect(m.active['rmu:98']!['level'], 1);
  });

  test('시나리오 29: 모드 전환', () {
    expect(m.status()['mode'], 'demo');
    m.setMode('live');
    expect(m.status()['mode'], 'live');
    expect(() => m.setMode('auto'), throwsA(isA<DemoRmuError>()));
  });

  test('야간 구간 계산, 시작=종료 거부', () {
    expect(inNightWindow(22 * 60, 21 * 60, 6 * 60), isTrue);
    expect(inNightWindow(3 * 60, 21 * 60, 6 * 60), isTrue);
    expect(inNightWindow(12 * 60, 21 * 60, 6 * 60), isFalse);
    expect(
      () => m.updateSettings({'night_start': 300, 'night_end': 300}),
      throwsA(isA<DemoRmuError>()),
    );
  });

  test('REST 흉내: 로그인, 제어 권한, 모드, 제안, 통신 두절', () {
    expect(
      () => m.handle('POST', '/api/control', {'device': 'pump', 'value': 1}, null),
      throwsA(isA<DemoRmuError>().having((e) => e.statusCode, 'code', 401)),
    );
    final token =
        m.handle('POST', '/api/login', {'username': 'admin', 'password': 'admin1234'}, null)['token']
            as String;
    m.handle('POST', '/api/control', {'device': 'control_mode', 'value': 0}, token);
    expect(m.handle('GET', '/api/status', null, null)['control']['control_mode'], 0);

    expect(m.handle('GET', '/api/mode', null, null)['mode'], 'demo');
    expect(
      () => m.handle('PUT', '/api/mode', {'mode': 'live'}, null),
      throwsA(isA<DemoRmuError>().having((e) => e.statusCode, 'code', 401)),
    );
    m.handle('PUT', '/api/mode', {'mode': 'live'}, token);
    expect(m.handle('GET', '/api/status', null, null)['mode'], 'live');
    expect(m.handle('GET', '/api/ai/suggestions', null, null)['suggestions'], isA<List>());
    expect(
      () => m.handle('POST', '/api/ai/suggestions/99/approve', {}, token),
      throwsA(isA<DemoRmuError>().having((e) => e.statusCode, 'code', 404)),
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
    expect(m.handle('GET', '/api/status', null, null)['alarm_level'], isA<int>());
  });
}
