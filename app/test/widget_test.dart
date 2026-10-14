import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartfarm_app/app_services.dart';
import 'package:smartfarm_app/models/farm.dart';
import 'package:smartfarm_app/models/rmu_event.dart';
import 'package:smartfarm_app/models/rmu_status.dart';
import 'package:smartfarm_app/screens/alerts_screen.dart';
import 'package:smartfarm_app/screens/control_screen.dart';
import 'package:smartfarm_app/screens/main_screen.dart';
import 'package:smartfarm_app/services/alert_center.dart';
import 'package:smartfarm_app/services/app_settings.dart';
import 'package:smartfarm_app/services/farm_monitor.dart';
import 'package:smartfarm_app/services/farm_store.dart';
import 'package:smartfarm_app/widgets/common.dart';

/// 라즈베리파이 /api/status 응답(v3.0)과 같은 모양의 샘플
Map<String, dynamic> sampleStatusJson({
  int level = 0,
  bool auto = true,
  String mode = 'live',
  Object? humidity = 65.2,
  Map<String, String> states = const {},
}) => {
  'time': '2026-10-14T16:59:46',
  'mode': mode,
  'alarm_level': level,
  'alarm_code': level > 0 ? 9 : 0,
  'alarm_message': level > 0 ? '온실 온도 상한 초과' : '',
  'conditions': [
    if (level > 0) {'key': 'temp', 'level': level, 'code': 9, 'message': '온실 온도 상한 초과', 'ai': false},
  ],
  'sensors': {
    'temperature': 30.3,
    'temp2': 29.0,
    'humidity': humidity,
    'hum_temp': 30.1,
    'water_level': 80,
    'fire': false,
    'co2': null,
    'soil_moisture': null,
    'nutrient_ec': null,
  },
  'states': {
    'temperature': 'ok',
    'humidity': 'ok',
    'water_level': 'ok',
    'fire': 'ok',
    'ac_voltage': 'ok',
    'co2': 'nodata',
    'soil_moisture': 'nodata',
    'nutrient_ec': 'nodata',
    ...states,
  },
  'power': {'ac_voltage': 221.0, 'ac_frequency': 60.0, 'power_ok': true, 'ups_battery': 100, 'greenhouse_power': 1870},
  'part_temps': {'pi_temp': 48.0},
  'door_open': false,
  'fans': {'main_ok': true, 'backup_ok': true, 'failover': false},
  'control': {
    'main_fan': 1,
    'backup_fan': 0,
    'cooling_fan': 0,
    'aircon': 1,
    'aircon_setpoint': 25.0,
    'heater': 0,
    'pump': 0,
    'cover': 0,
    'lights': 1,
    'control_mode': auto ? 1 : 0,
  },
  'night': {'night_mode': 1, 'night_start': 1260, 'night_end': 360, 'active': false},
  'ai': {
    'active': true,
    'reason': '최근 30초 상승 속도 0.50℃/분, 이대로면 약 1.5분 뒤 상한 30.0℃ 도달',
    'mode': mode,
    'pending': 1,
  },
  'rmu': {'used': true, 'connected': true, 'last_seen': '2026-10-14T16:59:45'},
};

const farmA = Farm(id: 'a', name: '방울토마토 1동', crop: '방울토마토', rmuAddress: 'localhost:1');
const farmB = Farm(id: 'b', name: '상추 2동', crop: '상추', rmuAddress: 'localhost:2');

/// 네트워크 없이 앱을 띄운다. 각 농장에 상태를 직접 넣어 둔다.
Future<AppServices> pumpApp(
  WidgetTester tester, {
  List<Farm> farms = const [],
  Map<String, dynamic>? statusJson,
  Map<String, Map<String, dynamic>> perFarm = const {},
  bool connected = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = AppSettings();
  final store = FarmStore();
  for (final f in farms) {
    await store.add(f);
  }
  final alerts = AlertCenter(settings);
  final hub = MonitorHub(store, alerts: alerts, autoStart: false);
  for (final f in farms) {
    final m = hub.monitorFor(f.id)!;
    m.status = RmuStatus.fromJson(perFarm[f.id] ?? statusJson ?? sampleStatusJson());
    m.connected = connected;
    m.loading = false;
  }
  final services = AppServices(
    farms: store,
    monitors: hub,
    alerts: alerts,
    settings: settings,
    child: const MaterialApp(home: MainScreen()),
  );
  await tester.pumpWidget(services);
  await tester.pump();
  return services;
}

/// 홈의 세로 목록 (위쪽 농장 탭 줄은 가로 목록)
final homeList = find.byWidgetPredicate(
  (w) => w is ListView && w.scrollDirection == Axis.vertical,
);

RmuEvent event(
  String farmId,
  int level, {
  String key = 'temp',
  String type = 'alarm',
  int minutesAgo = 0,
  bool ai = false,
}) => RmuEvent(
  farmId: farmId,
  farmName: farmId,
  time: DateTime(2026, 10, 14, 12).subtract(Duration(minutes: minutesAgo)),
  level: level,
  type: type,
  key: key,
  ai: ai,
  message: '테스트 $key $type',
);

void main() {
  test('/api/status v3 응답을 읽는다 (정보없음, 오류, RMU 연결)', () {
    final s = RmuStatus.fromJson(
      sampleStatusJson(level: 2, humidity: null, states: {'humidity': 'fault'}),
    );
    expect(s.alarmLevel, 2);
    expect(s.alarmCode, 9);
    expect(s.temperature, 30.3);
    expect(s.humidity, isNull);
    expect(s.sensorErrors, ['humidity']);
    expect(s.stateOf('co2'), 'nodata');
    expect(s.sensors['co2'], isNull);
    expect(s.fire, isFalse);
    expect(s.acVoltage, 221.0);
    expect(s.rmu.connected, isTrue);
    expect(s.ai.pending, 1);
    expect(s.isDemo, isFalse);
  });

  test('RMU 주소 정리: 포트가 없으면 8080, http:// 와 경로는 뺀다', () {
    expect(Farm.normalizeAddress('192.168.0.4'), '192.168.0.4:8080');
    expect(Farm.normalizeAddress(' 192.168.0.4:8081 '), '192.168.0.4:8081');
    expect(Farm.normalizeAddress('http://192.168.0.4:8080/api/status'), '192.168.0.4:8080');
    expect(Farm.normalizeAddress(''), '');
  });

  testWidgets('시나리오 22: 농장이 없으면 연결 안내', (tester) async {
    await pumpApp(tester);
    expect(find.textContaining('연동된 농장이 없습니다'), findsOneWidget);
    expect(find.text('농장 연결하기'), findsOneWidget);
    expect(find.text('스마트팜 v3.0'), findsOneWidget);
  });

  testWidgets('하단 탭: 첫 화면은 홈, 탭으로 이동', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    expect(find.text('다크 모드'), findsOneWidget);
    await tester.tap(find.text('알림').last);
    await tester.pumpAndSettle();
    expect(find.text('알림이 없습니다'), findsOneWidget);
  });

  testWidgets('시나리오 18: 농장 탭 줄을 눌러 농장 전환', (tester) async {
    await pumpApp(tester, farms: [farmA, farmB]);
    expect(find.text('방울토마토 1동 · 방울토마토'), findsOneWidget);
    await tester.tap(find.text('상추 2동'));
    await tester.pumpAndSettle();
    expect(find.text('상추 2동 · 상추'), findsOneWidget);
    await tester.tap(find.text('방울토마토 1동'));
    await tester.pumpAndSettle();
    expect(find.text('방울토마토 1동 · 방울토마토'), findsOneWidget);
  });

  testWidgets('시나리오 29: 데모 배지는 이름과 따로, 실사용이면 없음', (tester) async {
    await pumpApp(
      tester,
      farms: [farmA, farmB],
      perFarm: {'a': sampleStatusJson(mode: 'demo'), 'b': sampleStatusJson(mode: 'live')},
    );
    expect(find.text('방울토마토 1동'), findsOneWidget); // 이름에 (데모)가 붙지 않는다
    // 탭 줄 카드 1개 + 메인 화면 머리 1개
    expect(find.byType(DemoBadge), findsNWidgets(2));
    expect(find.text('AI 데모 모드'), findsOneWidget);
  });

  testWidgets('시나리오 12: 감지기 없는 항목은 정보없음', (tester) async {
    await pumpApp(tester, farms: [farmA]);
    await tester.dragUntilVisible(find.text('양분(EC)'), homeList, const Offset(0, -200));
    expect(find.text('정보없음'), findsNWidgets(3));
    expect(find.text('0 ppm'), findsNothing);
  });

  testWidgets('시나리오 25: AI 판단 이유와 승인 대기 표시', (tester) async {
    await pumpApp(tester, farms: [farmA]);
    expect(find.textContaining('AI 선가동 중'), findsOneWidget);
    expect(find.textContaining('상한 30.0℃ 도달'), findsOneWidget);
    expect(find.textContaining('승인을 기다리는 AI 제안 1건'), findsOneWidget);
  });

  testWidgets('시나리오 13: 통신 두절이면 안내와 마지막 값', (tester) async {
    await pumpApp(tester, farms: [farmA], connected: false);
    expect(find.textContaining('통신 두절: 라즈베리파이'), findsOneWidget);
    expect(find.text('30.3 ℃'), findsOneWidget); // 마지막 수신값은 남아 있다
  });

  testWidgets('시나리오 13: RMU만 두절이면 RMU 항목만 회색', (tester) async {
    final json = sampleStatusJson(states: {'temperature': 'offline', 'ac_voltage': 'offline'});
    json['rmu'] = {'used': true, 'connected': false, 'last_seen': '2026-10-14T16:59:00'};
    await pumpApp(tester, farms: [farmA], statusJson: json);
    expect(find.text('RMU 통신 두절'), findsOneWidget);
    expect(find.text('30.3 ℃ (RMU 두절)'), findsOneWidget);
  });

  testWidgets('시나리오 14: 오류 난 센서만 오류 표시', (tester) async {
    await pumpApp(
      tester,
      farms: [farmA],
      statusJson: sampleStatusJson(humidity: null, states: {'humidity': 'fault'}),
    );
    expect(find.text('센서 오류'), findsOneWidget);
    expect(find.text('30.3 ℃'), findsOneWidget);
  });

  testWidgets('시나리오 23: 홈은 로그인 없이, 제어는 로그인 요구', (tester) async {
    await pumpApp(tester, farms: [farmA]);
    expect(find.text('알람 등급: 정상'), findsOneWidget);
    await tester.dragUntilVisible(find.text('제어'), homeList, const Offset(0, -200));
    await tester.tap(find.text('제어'));
    await tester.pumpAndSettle();
    expect(find.textContaining('관리자 로그인'), findsOneWidget);
  });

  testWidgets('시나리오 24: 자동 모드에서 수동 조작 잠금', (tester) async {
    final services = await pumpApp(tester, farms: [farmA]);
    final monitor = services.monitors.monitorFor('a')!;
    await tester.pumpWidget(MaterialApp(home: ControlScreen(monitor: monitor)));
    await tester.pump();
    expect(find.textContaining('조작할 수 없습니다'), findsOneWidget);
    final heater = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '히터'));
    expect(heater.onChanged, isNull); // 잠김
  });

  testWidgets('시나리오 20·21: 알림 농장 버튼, 등급 필터, 복구·AI 표시', (tester) async {
    final services = await pumpApp(tester, farms: [farmA, farmB]);
    services.alerts.add([
      event('a', 2, minutesAgo: 10), // 나중에 복구됨
      event('a', 0, type: 'clear', minutesAgo: 5),
      event('b', 3, key: 'fire', minutesAgo: 3),
      event('b', 1, key: 'leak', minutesAgo: 1, ai: true),
    ], history: true);
    await tester.tap(find.text('알림').last);
    await tester.pumpAndSettle();
    expect(find.text('복구'), findsOneWidget);
    expect(find.text('AI 판단'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '긴급'));
    await tester.pumpAndSettle();
    expect(find.text('테스트 fire alarm'), findsOneWidget);
    expect(find.text('테스트 leak alarm'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, '전체'));
    await tester.tap(find.text('농장'));
    await tester.pumpAndSettle();
    expect(find.text('농장별 알림'), findsOneWidget);
    await tester.tap(find.text('상추 2동'));
    await tester.pumpAndSettle();
    expect(find.text('테스트 temp alarm'), findsNothing); // 다른 농장 알림은 빠진다
    expect(find.text('테스트 fire alarm'), findsOneWidget);
  });

  test('알림 필터·정렬·복구 계산', () {
    final events = [
      event('a', 2, minutesAgo: 10),
      event('a', 0, type: 'clear', minutesAgo: 5),
      event('a', 2, key: 'humidity_high', minutesAgo: 2), // 아직 복구 안 됨
      event('b', 1, key: 'leak', minutesAgo: 1),
    ];
    expect(filterEvents(events, filter: AlertFilter.alarm).map((e) => e.key), ['humidity_high', 'temp']);
    expect(filterEvents(events, filter: AlertFilter.caution).single.key, 'leak');
    expect(filterEvents(events, newestFirst: false).first.key, 'temp');
    expect(filterEvents(events, farmId: 'b').single.key, 'leak');
    expect(recoveredAlarms(events).map((e) => e.key), ['temp']);
  });

  test('시나리오 19: 알림 끄기와 긴급 경보', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings();
    final alerts = AlertCenter(settings);
    final shown = <RmuEvent>[];
    alerts.popups.listen(shown.add);

    await settings.setFarmMuted('a', true);
    alerts.add([event('a', 2), event('b', 2)]);
    alerts.add([event('a', 3, key: 'fan')]); // 긴급은 꺼도 온다
    await Future<void>.delayed(Duration.zero);
    expect(shown.map((e) => '${e.farmId}${e.level}'), ['b2', 'a3']);
    expect(alerts.events.length, 3); // 목록에는 모두 남는다

    // 같은 알림은 최소 간격 안에 다시 띄우지 않는다
    alerts.add([event('b', 2)]);
    await Future<void>.delayed(Duration.zero);
    expect(shown.length, 2);
  });
}
