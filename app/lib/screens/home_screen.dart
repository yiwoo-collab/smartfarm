import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/farm.dart';
import '../services/farm_monitor.dart';
import '../widgets/common.dart';
import 'control_screen.dart';
import 'detail_screen.dart';
import 'farm_settings_screen.dart';
import 'history_screen.dart';

/// 홈 화면 (앱의 첫 화면, 로그인 없이 볼 수 있음).
/// 연동된 농장이 없으면 연결 안내 빈 화면, 있으면 농장 상태를 바로 보여준다.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    return ListenableBuilder(
      listenable: services.monitors,
      builder: (context, _) {
        final farms = services.farms.farms;
        if (farms.isEmpty) return const _EmptyHome();
        // 농장 전환 방법 (1): 홈에서 좌우 스와이프 또는 위쪽 농장 이름 탭
        // 방법 (2): 설정 > 농장 연결
        return DefaultTabController(
          // 농장 목록이 바뀌면 탭을 새로 만든다
          key: ValueKey(farms.map((f) => f.id).join(',')),
          length: farms.length,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('스마트팜'),
              bottom: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [for (final farm in farms) _FarmTab(farm: farm)],
              ),
            ),
            body: TabBarView(
              children: [
                for (final farm in farms)
                  FarmStatusView(
                    monitor: services.monitors.monitorFor(farm.id)!,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 연동된 농장이 없을 때 (시나리오 19)
class _EmptyHome extends StatelessWidget {
  const _EmptyHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('스마트팜')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.agriculture, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text(
                '연동된 농장이 없습니다.\n설정 > 농장 연결에서 농장을 연결해 주세요.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.link),
                label: const Text('농장 연결하기'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        FarmListScreen(store: AppServices.of(context).farms),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // RMU 서버 없이 앱 안의 모의 RMU로 바로 체험
              OutlinedButton.icon(
                icon: const Icon(Icons.play_circle),
                label: const Text('데모 농장으로 바로 체험'),
                onPressed: () => AppServices.of(context).farms.addDemoFarms(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 위쪽 농장 탭: 이름 옆에 알람 등급 점을 찍어 다른 농장 상태도 보이게 한다
class _FarmTab extends StatelessWidget {
  final Farm farm;

  const _FarmTab({required this.farm});

  @override
  Widget build(BuildContext context) {
    final monitor = AppServices.of(context).monitors.monitorFor(farm.id)!;
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final status = monitor.status;
        final color = !monitor.connected
            ? Colors.grey
            : levelColor(status?.alarmLevel ?? 0);
        return Tab(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 6),
              Text(farm.name),
            ],
          ),
        );
      },
    );
  }
}

/// 농장 하나의 현재 상태
class FarmStatusView extends StatelessWidget {
  final FarmMonitor monitor;

  const FarmStatusView({super.key, required this.monitor});

  void _openHistory(BuildContext context, String sensor) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HistoryScreen(monitor: monitor, initialSensor: sensor),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final status = monitor.status;
        final stale = !monitor.connected; // 통신 두절: 마지막 수신값을 회색으로
        final errors = status?.sensorErrors ?? const [];
        return RefreshIndicator(
          onRefresh: monitor.refresh,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('작물: ${monitor.farm.crop}'),
              const SizedBox(height: 8),
              if (stale && !monitor.loading)
                Card(
                  color: Colors.grey.shade300,
                  child: ListTile(
                    leading: const Icon(Icons.link_off, color: Colors.black54),
                    title: const Text(
                      '통신 두절: RMU와 연결할 수 없습니다',
                      style: TextStyle(color: Colors.black87),
                    ),
                    subtitle: Text(
                      status == null
                          ? '받은 값이 없습니다. 주소를 확인하세요'
                          : '마지막 수신값을 회색으로 표시합니다. 자동으로 다시 연결합니다',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ),
                ),
              if (monitor.loading)
                const Center(child: CircularProgressIndicator()),
              if (status != null) ...[
                AlarmCard(status: status, stale: stale),
                Wrap(
                  spacing: 8,
                  children: [
                    Chip(
                      avatar: Icon(
                        status.autoMode ? Icons.auto_mode : Icons.pan_tool,
                        size: 18,
                      ),
                      label: Text(status.autoMode ? '자동 제어' : '수동 제어'),
                    ),
                    if (status.night.active)
                      const Chip(
                        avatar: Icon(Icons.nightlight, size: 18),
                        label: Text('야간 모드'),
                      ),
                    if (status.fanFailover)
                      const Chip(
                        avatar: Icon(Icons.swap_horiz, size: 18),
                        label: Text('예비 환풍기 가동 중'),
                      ),
                  ],
                ),
                // AI 선가동: 판단 이유를 항상 보여준다 (시나리오 22)
                if (status.aiReason.isNotEmpty)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        Icons.psychology,
                        color: status.aiActive && !stale
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey,
                      ),
                      title: Text(
                        status.aiActive ? 'AI 선가동 중: 미리 냉방하고 있습니다' : 'AI 판단',
                        style: TextStyle(
                          fontWeight: status.aiActive ? FontWeight.bold : null,
                          color: stale ? Colors.grey : null,
                        ),
                      ),
                      subtitle: Text(status.aiReason),
                    ),
                  ),
                ValueTile(
                  icon: Icons.thermostat,
                  label: '온도',
                  value: fmt(status.temperature, 1, '℃'),
                  stale: stale,
                  error: errors.contains('temperature'),
                  onTap: () => _openHistory(context, 'temperature'),
                ),
                ValueTile(
                  icon: Icons.water_drop,
                  label: '습도',
                  value: fmt(status.humidity, 1, '%'),
                  stale: stale,
                  error: errors.contains('humidity'),
                  onTap: () => _openHistory(context, 'humidity'),
                ),
                ValueTile(
                  icon: Icons.grass,
                  label: '토양수분',
                  value: fmt(status.soilMoisture, 0, '%'),
                  stale: stale,
                  error: errors.contains('soil_moisture'),
                  onTap: () => _openHistory(context, 'soil_moisture'),
                ),
                ValueTile(
                  icon: Icons.power,
                  label: '전원 공급',
                  value: status.powerOk ? '정상' : '이상',
                  valueColor: status.powerOk ? null : Colors.red,
                  stale: stale,
                  onTap: () => _openHistory(context, 'supply_voltage'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.analytics),
                        label: const Text('세부 정보'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DetailScreen(monitor: monitor),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.tune),
                        label: const Text('제어'),
                        onPressed: () => openControlScreen(context, monitor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '마지막 수신: ${formatTime(monitor.lastReceived ?? status.time)}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
