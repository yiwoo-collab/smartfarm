import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

import 'app_services.dart';
import 'screens/main_screen.dart';
import 'services/alert_center.dart';
import 'services/app_settings.dart';
import 'services/farm_monitor.dart';
import 'services/farm_store.dart';
import 'services/system_notifier.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings();
  final farms = FarmStore();
  await Future.wait([settings.load(), farms.load()]); // 폰에 저장한 설정·농장 목록
  final alerts = AlertCenter(settings);
  final monitors = MonitorHub(farms, alerts: alerts);

  // 시스템 알림: 앱 안 알림과 같은 것을 휴대폰/브라우저 알림으로도 띄운다
  final notifier = SystemNotifier();
  await notifier.init().timeout(const Duration(seconds: 3), onTimeout: () {});
  alerts.popups.listen((e) {
    if (settings.systemNotifications) notifier.show(e);
  });

  runApp(
    AppServices(
      farms: farms,
      monitors: monitors,
      alerts: alerts,
      settings: settings,
      notifier: notifier,
      child: const SmartFarmApp(),
    ),
  );
}

class SmartFarmApp extends StatelessWidget {
  const SmartFarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppServices.of(context).settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: '스마트팜 RMU',
        theme: ThemeData(colorSchemeSeed: Colors.green),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.green,
          brightness: Brightness.dark,
        ),
        themeMode: settings.themeMode, // 라이트 / 다크 2가지
        // PC 브라우저에서도 마우스로 끌어서 농장을 넘길 수 있게 한다 (폰은 원래 터치로 동작)
        scrollBehavior: const MaterialScrollBehavior().copyWith(
          dragDevices: PointerDeviceKind.values.toSet(),
        ),
        // 첫 화면은 홈 (로그인 화면이 아님)
        home: const MainScreen(),
      ),
    );
  }
}
