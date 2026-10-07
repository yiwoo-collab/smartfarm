import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 앱 자체 설정 (폰에 저장): 화면 모드, 알림 받기/끄기.
/// 야간 모드·임계값은 RMU 설정이라 여기 없고 /api/settings, /api/thresholds 로 바꾼다.
class AppSettings extends ChangeNotifier {
  bool darkMode = false; // 화면 모드: 라이트 / 다크
  bool notificationsOn = true; // 알림 전체 받기
  Set<String> mutedFarms = {}; // 알림을 끈 농장 id (긴급 경보는 꺼도 받음)
  int minIntervalMinutes = 5; // 같은 알림을 다시 띄우지 않는 최소 간격 (제안)
  bool systemNotifications = false; // 휴대폰/브라우저 시스템 알림 (권한 허용 후 켜짐)

  ThemeMode get themeMode => darkMode ? ThemeMode.dark : ThemeMode.light;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    darkMode = p.getBool('dark_mode') ?? false;
    notificationsOn = p.getBool('notifications_on') ?? true;
    mutedFarms = (p.getStringList('muted_farms') ?? []).toSet();
    minIntervalMinutes = p.getInt('min_interval_minutes') ?? 5;
    systemNotifications = p.getBool('system_notifications') ?? false;
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool('dark_mode', darkMode);
    await p.setBool('notifications_on', notificationsOn);
    await p.setStringList('muted_farms', mutedFarms.toList());
    await p.setInt('min_interval_minutes', minIntervalMinutes);
    await p.setBool('system_notifications', systemNotifications);
  }

  Future<void> setSystemNotifications(bool v) {
    systemNotifications = v;
    return _save();
  }

  Future<void> setDarkMode(bool v) {
    darkMode = v;
    return _save();
  }

  Future<void> setNotificationsOn(bool v) {
    notificationsOn = v;
    return _save();
  }

  bool isFarmMuted(String farmId) => mutedFarms.contains(farmId);

  Future<void> setFarmMuted(String farmId, bool muted) {
    mutedFarms = {...mutedFarms};
    muted ? mutedFarms.add(farmId) : mutedFarms.remove(farmId);
    return _save();
  }

  Future<void> setMinInterval(int minutes) {
    minIntervalMinutes = minutes;
    return _save();
  }
}
