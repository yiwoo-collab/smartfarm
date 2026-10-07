import 'package:flutter/widgets.dart';

import 'services/alert_center.dart';
import 'services/app_settings.dart';
import 'services/farm_monitor.dart';
import 'services/farm_store.dart';
import 'services/system_notifier.dart';

/// 앱 전체에서 쓰는 서비스 묶음. 어느 화면에서든 AppServices.of(context)로 꺼내 쓴다.
class AppServices extends InheritedWidget {
  final FarmStore farms;
  final MonitorHub monitors;
  final AlertCenter alerts;
  final AppSettings settings;
  final SystemNotifier? notifier; // 시스템 알림 (테스트에서는 없음)

  const AppServices({
    super.key,
    required this.farms,
    required this.monitors,
    required this.alerts,
    required this.settings,
    this.notifier,
    required super.child,
  });

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppServices>()!;

  @override
  bool updateShouldNotify(AppServices old) => false; // 서비스 객체는 바뀌지 않는다
}
