import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartfarm_app/app_services.dart';
import 'package:smartfarm_app/models/farm.dart';
import 'package:smartfarm_app/models/rmu_event.dart';
import 'package:smartfarm_app/models/rmu_status.dart';
import 'package:smartfarm_app/screens/control_screen.dart';
import 'package:smartfarm_app/screens/main_screen.dart';
import 'package:smartfarm_app/services/alert_center.dart';
import 'package:smartfarm_app/services/app_settings.dart';
import 'package:smartfarm_app/services/farm_monitor.dart';
import 'package:smartfarm_app/services/farm_store.dart';

/// 모의 RMU /api/status 응답과 같은 모양의 샘플
Map<String, dynamic> sampleStatusJson({
  int level = 0,
  bool auto = true,
  Object? humidity = 65.2,
  List<String> errors = const [],
}) => {
  'time': '2026-10-07T16:59:46',
  'alarm_level': level,
  'alarm_message': level > 0 ? '온실 온도 상한 초과' : '',
  'conditions': [
    if (level > 0) {'key': 'temp', 'level': level, 'message': '온실 온도 상한 초과'},
  ],
  'sensors': {
    'temperature': 30.3,
    'humidity': humidity,
    'soil_moisture': 45,
    'co2': 450,
    'nutrient_ec': 1.8,
  },
  'sensor_errors': errors,
  'power': {'power_ok': true},
  'part_temps': {'rmu_temp': 48.0},
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
  'night': {
    'night_mode': 1,
    'night_start': 1260,
    'night_end': 360,
    'active': false,
  },
  'ai': {
    'active': true,
    'reason': '최근 30초 상승 속도 0.50℃/분, 이대로면 약 1.5분 뒤 상한 30.0℃ 도달',
  },
};

const farmA = Farm(
  id: 'a',
  name: '방울토마토 1동',
  crop: '방울토마토',
  rmuAddress: 'localhost:1',
);
const farmB = Farm(
  id: 'b',
  name: '상추 2동',
  crop: '상추',
  rmuAddress: 'localhost:2',
);

/// 네트워크 없이 앱을 띄운다. 각 농장에 상태를 직접 넣어 둔다.
Future<AppServices> pumpApp(
  WidgetTester tester, {
  List<Farm> farms = const [],
  Map<String, dynamic>? statusJson,
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
    m.status = RmuStatus.fromJson(statusJson ?? sampleStatusJson());
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

RmuEvent event(String farmId, int level, {String key = 'temp'}) => RmuEvent(
  farmId: farmId,
  farmName: farmId,
  time: DateTime.now(),
  level: level,
  type: 'alarm',
  key: key,
  message: '테스트',
);

void main() {
  test('/api/status 응답을 읽는다 (센서 오류는 null)', () {
    final s = RmuStatus.fromJson(
      sampleStatusJson(level: 2, humidity: null, errors: ['humidity']),
    );
    expect(s.alarmLevel, 2);
    expect(s.temperature, 30.3);
    expect(s.humidity, isNull);
    expect(s.sensorErrors, ['humidity']);
    expect(s.autoMode, isTrue);
    expect(s.conditions.single.key, 'temp');
  });

  test('RMU 주소 정리: 포트가 없으면 8080, http:// 와 경로는 뺀다', () {
    expect(Farm.normalizeAddress('192.168.0.4'), '192.168.0.4:8080');
    expect(Farm.normalizeAddress(' 192.168.0.4:8081 '), '192.168.0.4:8081');
    expect(
      Farm.normalizeAddress('http://192.168.0.4:8080/api/status'),
      '192.168.0.4:8080',
    );
    expect(Farm.normalizeAddress(''), '');
  });

  testWidgets('시나리오 19: 농장이 없으면 연결 안내', (tester) async {
    await pumpApp(tester);
    expect(find.textContaining('연동된 농장이 없습니다'), findsOneWidget);
    expect(find.text('농장 연결하기'), findsOneWidget);
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

  testWidgets('시나리오 18: 스와이프와 농장 탭으로 전환', (tester) async {
    await pumpApp(tester, farms: [farmA, farmB]);
    expect(find.text('작물: 방울토마토'), findsOneWidget);

    await tester.fling(find.byType(TabBarView), const Offset(-500, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('작물: 상추'), findsOneWidget);

    await tester.tap(find.text('방울토마토 1동'));
    await tester.pumpAndSettle();
    expect(find.text('작물: 방울토마토'), findsOneWidget);
  });

  testWidgets('시나리오 22: AI 선가동과 판단 이유 표시', (tester) async {
    await pumpApp(tester, farms: [farmA]);
    expect(find.textContaining('AI 선가동 중'), findsOneWidget);
    expect(find.textContaining('상한 30.0℃ 도달'), findsOneWidget);
  });

  testWidgets('시나리오 12: 통신 두절이면 안내와 마지막 값', (tester) async {
    await pumpApp(tester, farms: [farmA], connected: false);
    expect(find.textContaining('통신 두절'), findsOneWidget);
    expect(find.text('30.3 ℃'), findsOneWidget); // 마지막 수신값은 남아 있다
  });

  testWidgets('시나리오 13: 오류 난 센서만 오류 표시', (tester) async {
    await pumpApp(
      tester,
      farms: [farmA],
      statusJson: sampleStatusJson(humidity: null, errors: ['humidity']),
    );
    expect(find.text('센서 오류'), findsOneWidget);
    expect(find.text('30.3 ℃'), findsOneWidget);
  });

  testWidgets('시나리오 20: 홈은 로그인 없이, 제어는 로그인 요구', (tester) async {
    await pumpApp(tester, farms: [farmA]);
    expect(find.text('알람 등급: 정상'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('제어'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.tap(find.text('제어'));
    await tester.pumpAndSettle();
    expect(find.textContaining('관리자 로그인'), findsOneWidget);
  });

  testWidgets('시나리오 21: 자동 모드에서 수동 조작 잠금', (tester) async {
    final services = await pumpApp(tester, farms: [farmA]);
    final monitor = services.monitors.monitorFor('a')!;
    await tester.pumpWidget(MaterialApp(home: ControlScreen(monitor: monitor)));
    await tester.pump();
    expect(find.textContaining('조작할 수 없습니다'), findsOneWidget);
    final heater = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '히터'),
    );
    expect(heater.onChanged, isNull); // 잠김
  });

  test('시나리오 17: 알림 끄기와 긴급 경보', () async {
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
