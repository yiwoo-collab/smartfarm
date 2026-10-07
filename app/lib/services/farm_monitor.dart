import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/farm.dart';
import '../models/rmu_event.dart';
import '../models/rmu_status.dart';
import 'alert_center.dart';
import 'farm_store.dart';
import 'rmu_api.dart';

/// 농장 하나의 상태와 이벤트를 5초마다 받아온다 (시나리오 1).
/// 화면과 따로 동작하므로, 어떤 탭을 보고 있든 모든 농장을 계속 감시한다.
class FarmMonitor extends ChangeNotifier {
  static const refreshInterval = Duration(seconds: 5);

  Farm farm;
  final RmuApi api;
  final AlertCenter? alerts;
  Timer? _timer;
  bool _disposed = false;

  RmuStatus? status; // 마지막으로 받은 값 (통신 두절이어도 유지)
  bool connected = false; // false면 통신 두절 (알람 등급이 아닌 별도 상태)
  bool loading = true; // 아직 한 번도 응답을 시도하지 않음
  DateTime? lastReceived;
  int _lastEventId = 0;
  bool _eventsSynced = false; // 첫 이벤트 조회는 과거 기록이라 팝업하지 않는다

  FarmMonitor(this.farm, {this.alerts, bool autoStart = true})
    : api = RmuApi(farm.baseUrl) {
    if (autoStart) {
      refresh();
      _timer = Timer.periodic(refreshInterval, (_) => refresh());
    }
  }

  Future<void> refresh() async {
    final wasConnected = connected;
    try {
      final newStatus = await api.fetchStatus();
      await _fetchEvents();
      status = newStatus;
      connected = true;
      lastReceived = DateTime.now();
      alerts?.onStatus(farm, newStatus);
    } catch (_) {
      connected = false;
    }
    if (_disposed) return;
    // 통신 두절/복구는 앱이 직접 알림을 만든다 (시나리오 12)
    if (!loading && wasConnected != connected) {
      alerts?.add([
        RmuEvent(
          farmId: farm.id,
          farmName: farm.name,
          time: DateTime.now(),
          level: 0,
          type: 'comm',
          key: 'comm',
          message: connected ? 'RMU와 다시 연결되었습니다' : 'RMU와 통신이 끊겼습니다',
        ),
      ]);
    }
    loading = false;
    notifyListeners();
  }

  Future<void> _fetchEvents() async {
    var result = await api.fetchEvents(_lastEventId);
    if (result.lastId < _lastEventId) {
      // RMU가 재시작해서 이벤트 번호가 처음부터 다시 시작됨
      _lastEventId = 0;
      result = await api.fetchEvents(0);
    }
    if (_disposed) return;
    final events = [
      for (final e in result.events)
        RmuEvent.fromJson(e, farmId: farm.id, farmName: farm.name),
    ];
    if (events.isNotEmpty) _lastEventId = events.last.id;
    alerts?.add(events, history: !_eventsSynced);
    _eventsSynced = true;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// 농장 목록(FarmStore)에 맞춰 FarmMonitor를 만들고 없앤다.
class MonitorHub extends ChangeNotifier {
  final FarmStore store;
  final AlertCenter? alerts;
  final bool autoStart; // 테스트에서는 false로 두어 네트워크 요청을 하지 않는다
  final Map<String, FarmMonitor> _monitors = {};

  MonitorHub(this.store, {this.alerts, this.autoStart = true}) {
    store.addListener(_sync);
    _sync();
  }

  FarmMonitor? monitorFor(String farmId) => _monitors[farmId];

  void _sync() {
    final farms = {for (final f in store.farms) f.id: f};

    // 삭제된 농장은 감시를 멈춘다
    for (final id in _monitors.keys.toList()) {
      if (!farms.containsKey(id)) _monitors.remove(id)!.dispose();
    }
    for (final farm in farms.values) {
      final m = _monitors[farm.id];
      if (m == null || m.farm.rmuAddress != farm.rmuAddress) {
        // 새 농장이거나 주소가 바뀌면 새로 연결
        m?.dispose();
        _monitors[farm.id] = FarmMonitor(
          farm,
          alerts: alerts,
          autoStart: autoStart,
        );
      } else {
        m.farm = farm; // 이름·작물만 바뀐 경우
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    store.removeListener(_sync);
    for (final m in _monitors.values) {
      m.dispose();
    }
    super.dispose();
  }
}
