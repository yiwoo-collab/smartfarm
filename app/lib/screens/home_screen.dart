import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/farm.dart';
import '../models/rmu_status.dart';
import '../services/farm_monitor.dart';
import '../widgets/common.dart';
import 'ai_screen.dart';
import 'control_screen.dart';
import 'detail_screen.dart';
import 'farm_settings_screen.dart';
import 'history_screen.dart';

const appTitle = '스마트팜 v3.0';

/// 홈 화면 (앱의 첫 화면, 로그인 없이 볼 수 있음).
/// 연동된 농장이 없으면 연결 안내, 있으면 위쪽 농장 탭 줄 + 선택한 농장 메인 화면 (CLAUDE.md 3장).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _selectedId;
  PageController? _pages;

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  void _select(List<Farm> farms, int index) {
    setState(() => _selectedId = farms[index].id);
    if (_pages != null && _pages!.hasClients) {
      _pages!.animateToPage(
        index,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([services.monitors, services.settings]),
      builder: (context, _) {
        final farms = services.farms.farms;
        if (farms.isEmpty) return const _EmptyHome();
        var index = farms.indexWhere((f) => f.id == _selectedId);
        if (index < 0) index = 0;
        final swipe = services.settings.homeSwipe;
        if (swipe) {
          _pages ??= PageController(initialPage: index);
        } else {
          _pages?.dispose();
          _pages = null;
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text(appTitle),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(88),
              child: _FarmStrip(
                farms: farms,
                selected: index,
                onTap: (i) => _select(farms, i),
              ),
            ),
          ),
          body: swipe
              // 선택: 좌우 스와이프로도 농장 전환 (설정에서 켬)
              ? PageView(
                  controller: _pages,
                  onPageChanged: (i) => setState(() => _selectedId = farms[i].id),
                  children: [
                    for (final f in farms)
                      FarmStatusView(monitor: services.monitors.monitorFor(f.id)!),
                  ],
                )
              : FarmStatusView(
                  key: ValueKey(farms[index].id),
                  monitor: services.monitors.monitorFor(farms[index].id)!,
                ),
        );
      },
    );
  }
}

/// 위쪽 농장 탭 줄: 옆으로 밀어 둘러보고, 누르면 그 농장 메인 화면 (시나리오 18)
class _FarmStrip extends StatelessWidget {
  final List<Farm> farms;
  final int selected;
  final ValueChanged<int> onTap;

  const _FarmStrip({required this.farms, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 88,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        itemCount: farms.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) =>
            _FarmCard(farm: farms[i], selected: i == selected, onTap: () => onTap(i)),
      ),
    );
  }
}

class _FarmCard extends StatelessWidget {
  final Farm farm;
  final bool selected;
  final VoidCallback onTap;

  const _FarmCard({required this.farm, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final monitor = AppServices.of(context).monitors.monitorFor(farm.id)!;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final s = monitor.status;
        final offline = !monitor.connected && !monitor.loading;
        final level = s?.alarmLevel ?? 0;
        final color = offline ? Colors.grey : levelColor(level);
        return Material(
          color: selected ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(
              width: 150,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          farm.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (s?.isDemo ?? farm.isDemo) const DemoBadge(),
                    ],
                  ),
                  Text(farm.crop, style: Theme.of(context).textTheme.bodySmall),
                  Row(
                    children: [
                      Icon(Icons.circle, size: 9, color: color),
                      const SizedBox(width: 4),
                      Text(
                        offline ? '통신 두절' : alarmLevelNames[level.clamp(0, 3)],
                        style: TextStyle(fontSize: 12, color: color),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 연동된 농장이 없을 때 (시나리오 22)
class _EmptyHome extends StatelessWidget {
  const _EmptyHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(appTitle)),
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
                    builder: (_) => FarmListScreen(store: AppServices.of(context).farms),
                  ),
                ),
              ),
              const SizedBox(height: 8),
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

/// 농장 하나의 메인 화면
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
        final s = monitor.status;
        final stale = !monitor.connected;
        return RefreshIndicator(
          onRefresh: monitor.refresh,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Text('${monitor.farm.name} · ${monitor.farm.crop}'),
                  const SizedBox(width: 8),
                  if (s?.isDemo ?? monitor.farm.isDemo) const DemoBadge(),
                ],
              ),
              const SizedBox(height: 8),
              if (stale && !monitor.loading)
                Card(
                  color: Colors.grey.shade300,
                  child: ListTile(
                    leading: const Icon(Icons.link_off, color: Colors.black54),
                    title: const Text(
                      '통신 두절: 라즈베리파이와 연결할 수 없습니다',
                      style: TextStyle(color: Colors.black87),
                    ),
                    subtitle: Text(
                      s == null
                          ? '받은 값이 없습니다. 주소를 확인하세요'
                          : '마지막 수신 ${formatTime(monitor.lastReceived ?? s.time)}. 값을 회색으로 표시하고 자동으로 다시 연결합니다',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ),
                ),
              if (monitor.loading) const Center(child: CircularProgressIndicator()),
              if (s != null) ..._body(context, s, stale),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _body(BuildContext context, RmuStatus s, bool stale) {
    final rmuDown = s.rmu.used && s.rmu.connected == false;
    return [
      AlarmCard(status: s, stale: stale),
      Wrap(
        spacing: 8,
        children: [
          Chip(
            avatar: Icon(s.autoMode ? Icons.auto_mode : Icons.pan_tool, size: 18),
            label: Text(s.autoMode ? '자동 제어' : '수동 제어'),
          ),
          Chip(
            avatar: Icon(s.isDemo ? Icons.science : Icons.sensors, size: 18),
            label: Text(s.isDemo ? 'AI 데모 모드' : 'AI 실사용 모드'),
          ),
          if (s.night.active)
            const Chip(avatar: Icon(Icons.nightlight, size: 18), label: Text('야간 모드')),
          if (s.fanFailover)
            const Chip(avatar: Icon(Icons.swap_horiz, size: 18), label: Text('예비 환풍기 가동 중')),
        ],
      ),
      if (rmuDown)
        Card(
          child: ListTile(
            leading: const Icon(Icons.router, color: Colors.grey),
            title: const Text('RMU 통신 두절'),
            subtitle: Text(
              'RMU 항목(온도·전원)은 마지막 값을 회색으로 표시합니다'
              '${s.rmu.lastSeen != null ? ' · 마지막 수신 ${formatTime(s.rmu.lastSeen!)}' : ''}',
            ),
          ),
        ),
      _AiCard(monitor: monitor, status: s, stale: stale),
      ValueTile(
        icon: Icons.thermostat,
        label: '온도',
        value: fmt(s.temperature, 1, '℃'),
        stale: stale,
        state: s.stateOf('temperature'),
        onTap: () => _openHistory(context, 'temperature'),
      ),
      ValueTile(
        icon: Icons.water_drop,
        label: '습도',
        value: fmt(s.humidity, 1, '%'),
        stale: stale,
        state: s.stateOf('humidity'),
        onTap: () => _openHistory(context, 'humidity'),
      ),
      ValueTile(
        icon: Icons.waves,
        label: '수위',
        value: fmt(s.waterLevel, 0, '%'),
        stale: stale,
        state: s.stateOf('water_level'),
        onTap: () => _openHistory(context, 'water_level'),
      ),
      ValueTile(
        icon: Icons.local_fire_department,
        label: '화재',
        value: s.fire == true ? '감지' : '없음',
        valueColor: s.fire == true ? Colors.red : null,
        stale: stale,
        state: s.stateOf('fire'),
      ),
      ValueTile(
        icon: Icons.power,
        label: '전원 공급',
        value: s.powerOk ? '정상' : '이상',
        valueColor: s.powerOk ? null : Colors.red,
        stale: stale,
        state: s.stateOf('ac_voltage'),
        onTap: () => _openHistory(context, 'ac_voltage'),
      ),
      // 감지기가 연결되지 않은 항목은 0이 아니라 '정보없음' (시나리오 12)
      for (final (name, icon) in const [
        ('co2', Icons.co2),
        ('soil_moisture', Icons.grass),
        ('nutrient_ec', Icons.science),
      ])
        ValueTile(
          icon: icon,
          label: displayNames[name]!,
          value: fmt(s.sensors[name], name == 'nutrient_ec' ? 2 : 0,
              {'co2': 'ppm', 'soil_moisture': '%', 'nutrient_ec': 'mS/cm'}[name]!),
          stale: stale,
          state: s.stateOf(name),
          onTap: () => _openHistory(context, name),
        ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.analytics),
              label: const Text('세부 정보'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DetailScreen(monitor: monitor)),
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
        '마지막 수신: ${formatTime(monitor.lastReceived ?? s.time)}',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }
}

/// AI 판단 카드: 판단 이유를 항상 보여주고, 실사용 모드면 승인 대기 제안으로 안내
class _AiCard extends StatelessWidget {
  final FarmMonitor monitor;
  final RmuStatus status;
  final bool stale;

  const _AiCard({required this.monitor, required this.status, required this.stale});

  @override
  Widget build(BuildContext context) {
    final ai = status.ai;
    final aiConds = status.conditions.where((c) => c.ai).toList();
    if (ai.reason.isEmpty && aiConds.isEmpty) return const SizedBox.shrink();
    final title = ai.active
        ? (status.isDemo ? 'AI 선가동 중: 미리 냉방하고 있습니다' : 'AI 선가동 중 (위험 낮은 조치만 자동)')
        : 'AI 판단';
    return Card(
      child: ListTile(
        leading: Icon(
          Icons.psychology,
          color: ai.active && !stale ? Theme.of(context).colorScheme.primary : Colors.grey,
        ),
        title: Text(title, style: TextStyle(fontWeight: ai.active ? FontWeight.bold : null)),
        subtitle: Text([
          ai.reason,
          for (final c in aiConds) c.message,
          if (ai.pending > 0) '승인을 기다리는 AI 제안 ${ai.pending}건',
        ].where((t) => t.isNotEmpty).join('\n')),
        trailing: ai.pending > 0 ? const Icon(Icons.chevron_right) : null,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AiScreen(monitor: monitor)),
        ),
      ),
    );
  }
}
