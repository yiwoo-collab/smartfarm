import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/rmu_event.dart';
import '../models/rmu_status.dart';

/// 휴대폰(안드로이드 알림창) / 브라우저 시스템 알림.
/// 앱 화면 아래의 알림(SnackBar)과 같은 알림을 시스템 알림으로도 띄운다.
/// 앱이 뒤로 가 있어도 프로세스가 살아 있으면 알림이 온다.
/// 앱이 완전히 꺼져 있을 때는 RMU의 푸시(rmu/push.py, ntfy)를 쓴다.
class SystemNotifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 1;

  /// 지원하는 플랫폼인가 (안드로이드, 웹)
  bool get supported =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.android;

  Future<void> init() async {
    if (!supported) return;
    try {
      _ready =
          await _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
              web: WebInitializationSettings(),
            ),
          ) ??
          false;
    } catch (e) {
      _ready = false; // 브라우저가 지원하지 않는 경우 등: 앱 안 알림만 쓴다
    }
  }

  /// 알림 권한 요청 (설정에서 켤 때, 사용자가 누른 직후에 부른다). 허용되면 true.
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    try {
      if (kIsWeb) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                  WebFlutterLocalNotificationsPlugin
                >()
                ?.requestNotificationsPermission() ??
            false;
      }
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> show(RmuEvent e) async {
    if (!_ready) return;
    final levelName = e.type == 'comm'
        ? '통신'
        : alarmLevelNames[e.level.clamp(0, 3)];
    try {
      await _plugin.show(
        id: _nextId++,
        title: '[${e.farmName}] $levelName',
        body: e.message,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            e.level >= 3 ? 'emergency' : 'alarms',
            e.level >= 3 ? '긴급 경보' : '경보 알림',
            channelDescription: '스마트팜 RMU 알람',
            importance: e.level >= 3 ? Importance.max : Importance.high,
            priority: Priority.high,
          ),
          web: const WebNotificationDetails(),
        ),
      );
    } catch (_) {
      // 권한이 없거나 브라우저가 막은 경우: 앱 안 알림은 그대로 뜬다
    }
  }
}
