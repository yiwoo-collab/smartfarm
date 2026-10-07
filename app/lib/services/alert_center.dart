import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/farm.dart';
import '../models/rmu_event.dart';
import '../models/rmu_status.dart';
import 'app_settings.dart';

/// 등록된 전체 농장의 알림을 모으고, 화면에 띄울지 정한다 (CLAUDE.md 3장 알림).
///
/// 띄우는 규칙
///  - 알림 끄기(전체 또는 농장별)를 했어도 긴급 경보(3)는 띄운다 (제안)
///  - 같은 농장·같은 항목·같은 등급은 최소 간격 안에 다시 띄우지 않는다 (제안)
///  - 긴급 경보는 해소될 때까지 1분마다 다시 띄운다 (제안)
///  - 1~2단계에서는 앱이 켜져 있을 때만 알림이 온다
class AlertCenter extends ChangeNotifier {
  static const emergencyRepeat = Duration(minutes: 1);
  static const maxEvents = 500;

  final AppSettings settings;
  final List<RmuEvent> _events = []; // 최신이 앞
  final _popups = StreamController<RmuEvent>.broadcast();
  final Map<String, DateTime> _lastShown = {};

  AlertCenter(this.settings);

  List<RmuEvent> get events => List.unmodifiable(_events);

  /// 화면 위에 띄울 알림 (MainScreen이 구독해서 SnackBar로 보여준다)
  Stream<RmuEvent> get popups => _popups.stream;

  /// 새 이벤트 추가. history=true면 앱을 켜기 전 기록이라 목록에만 넣는다.
  void add(List<RmuEvent> events, {bool history = false}) {
    if (events.isEmpty) return;
    _events.insertAll(0, events.reversed);
    if (_events.length > maxEvents) {
      _events.removeRange(maxEvents, _events.length);
    }
    notifyListeners();
    if (history) return;
    for (final e in events) {
      if (_shouldPopup(e)) _show(e);
    }
  }

  bool _shouldPopup(RmuEvent e) {
    // 발생(alarm), 통신 두절, 등급이 있는 안내(펌프 정지 등)만 띄운다. 해소·조작은 목록에만.
    final important =
        e.type == 'alarm' ||
        e.type == 'comm' ||
        (e.type == 'info' && e.level > 0);
    if (!important || (e.type == 'alarm' && e.level == 0)) return false;
    if (e.level >= 3) return true; // 긴급 경보는 끌 수 없다
    if (!settings.notificationsOn || settings.isFarmMuted(e.farmId)) {
      return false;
    }

    final key = '${e.farmId}|${e.key}|${e.level}';
    final last = _lastShown[key];
    final interval = Duration(minutes: settings.minIntervalMinutes);
    return last == null || DateTime.now().difference(last) >= interval;
  }

  void _show(RmuEvent e) {
    _lastShown['${e.farmId}|${e.key}|${e.level}'] = DateTime.now();
    _popups.add(e);
  }

  /// 상태를 받을 때마다 호출: 긴급 경보가 계속되면 1분마다 다시 알린다.
  void onStatus(Farm farm, RmuStatus status) {
    for (final c in status.conditions.where((c) => c.level >= 3)) {
      final key = '${farm.id}|${c.key}|${c.level}';
      final last = _lastShown[key];
      // last == null: 앱을 켰을 때 이미 긴급 경보 중이었던 경우
      if (last == null || DateTime.now().difference(last) >= emergencyRepeat) {
        _show(
          RmuEvent(
            farmId: farm.id,
            farmName: farm.name,
            time: DateTime.now(),
            level: 3,
            type: 'alarm',
            key: c.key,
            message: '긴급 경보 계속: ${c.message}',
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _popups.close();
    super.dispose();
  }
}
