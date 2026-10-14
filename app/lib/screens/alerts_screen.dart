import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/farm.dart';
import '../models/rmu_event.dart';
import '../models/rmu_status.dart';
import '../widgets/common.dart';

/// 알림 필터 (CLAUDE.md 3장 v3.0): 전체 / 긴급 / 경보 / 주의. 정렬은 최신 순이 기본.
enum AlertFilter { all, emergency, alarm, caution }

const alertFilterNames = {
  AlertFilter.all: '전체',
  AlertFilter.emergency: '긴급',
  AlertFilter.alarm: '경보',
  AlertFilter.caution: '주의',
};

/// 필터에 맞는 알림만 고른다. 등급 필터는 해당 등급의 알림만 (복구·조작 안내 제외).
List<RmuEvent> filterEvents(
  List<RmuEvent> events, {
  String? farmId,
  AlertFilter filter = AlertFilter.all,
  bool newestFirst = true,
}) {
  final want = switch (filter) {
    AlertFilter.emergency => 3,
    AlertFilter.alarm => 2,
    AlertFilter.caution => 1,
    AlertFilter.all => null,
  };
  final list = events.where((e) {
    if (farmId != null && e.farmId != farmId) return false;
    if (want != null && (e.level != want || e.type == 'clear')) return false;
    return true;
  }).toList();
  list.sort((a, b) => newestFirst ? b.time.compareTo(a.time) : a.time.compareTo(b.time));
  return list;
}

/// 나중에 해제(복구)된 발생 알림을 찾는다 → 카드에 "복구" 표시.
/// 같은 농장·같은 항목의 clear 이벤트가 그 발생보다 뒤에 있으면 복구된 것.
Set<RmuEvent> recoveredAlarms(List<RmuEvent> events) {
  final sorted = [...events]..sort((a, b) => b.time.compareTo(a.time)); // 최신 → 과거
  final cleared = <String>{};
  final recovered = <RmuEvent>{};
  for (final e in sorted) {
    final key = '${e.farmId}|${e.key}';
    if (e.type == 'clear') {
      cleared.add(key);
    } else if (e.type == 'alarm' && cleared.remove(key)) {
      recovered.add(e);
    }
  }
  return recovered;
}

/// 알림 탭: 등록된 전체 농장의 알림 (시나리오 19~21).
/// 항목마다 농장 이름, "농장" 버튼으로 농장별 보기.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  AlertFilter _filter = AlertFilter.all;
  bool _newestFirst = true;

  void _openFarms(List<Farm> farms) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AlertFarmListScreen(farms: farms)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([services.alerts, services.farms]),
      builder: (context, _) {
        final all = services.alerts.events;
        return Scaffold(
          appBar: AppBar(
            title: const Text('알림'),
            actions: [
              TextButton.icon(
                icon: const Icon(Icons.agriculture),
                label: const Text('농장'),
                onPressed: () => _openFarms(services.farms.farms),
              ),
            ],
          ),
          body: AlertList(
            events: all,
            filter: _filter,
            newestFirst: _newestFirst,
            onFilter: (f) => setState(() => _filter = f),
            onSort: () => setState(() => _newestFirst = !_newestFirst),
          ),
        );
      },
    );
  }
}

/// 필터 줄 + 알림 목록 (전체 알림 탭과 농장별 보기에서 같이 쓴다)
class AlertList extends StatelessWidget {
  final List<RmuEvent> events;
  final String? farmId;
  final AlertFilter filter;
  final bool newestFirst;
  final ValueChanged<AlertFilter> onFilter;
  final VoidCallback onSort;

  const AlertList({
    super.key,
    required this.events,
    this.farmId,
    required this.filter,
    required this.newestFirst,
    required this.onFilter,
    required this.onSort,
  });

  @override
  Widget build(BuildContext context) {
    final shown = filterEvents(
      events,
      farmId: farmId,
      filter: filter,
      newestFirst: newestFirst,
    );
    final recovered = recoveredAlarms(events);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              ActionChip(
                avatar: Icon(newestFirst ? Icons.arrow_downward : Icons.arrow_upward, size: 18),
                label: Text(newestFirst ? '최신 순' : '오래된 순'),
                onPressed: onSort,
              ),
              const SizedBox(width: 8),
              for (final f in AlertFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(alertFilterNames[f]!),
                    selected: filter == f,
                    onSelected: (_) => onFilter(f),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: shown.isEmpty
              ? const Center(child: Text('알림이 없습니다'))
              : ListView.separated(
                  itemCount: shown.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _EventTile(
                    event: shown[i],
                    recovered: recovered.contains(shown[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

/// "농장" 버튼: 농장 목록 → 농장별 알림 (시나리오 20)
class AlertFarmListScreen extends StatelessWidget {
  final List<Farm> farms;

  const AlertFarmListScreen({super.key, required this.farms});

  @override
  Widget build(BuildContext context) {
    final alerts = AppServices.of(context).alerts;
    return Scaffold(
      appBar: AppBar(title: const Text('농장별 알림')),
      body: ListenableBuilder(
        listenable: alerts,
        builder: (context, _) => farms.isEmpty
            ? const Center(child: Text('연동된 농장이 없습니다'))
            : ListView(
                children: [
                  for (final f in farms)
                    Builder(builder: (context) {
                      final mine = alerts.events.where((e) => e.farmId == f.id);
                      final active = mine.where((e) => e.type == 'alarm').length;
                      return ListTile(
                        leading: const Icon(Icons.agriculture),
                        title: Row(
                          children: [
                            Flexible(child: Text(f.name)),
                            if (f.isDemo) ...[const SizedBox(width: 6), const DemoBadge()],
                          ],
                        ),
                        subtitle: Text('${f.crop} · 알림 ${mine.length}건 (발생 $active건)'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => FarmAlertsScreen(farm: f)),
                        ),
                      );
                    }),
                ],
              ),
      ),
    );
  }
}

class FarmAlertsScreen extends StatefulWidget {
  final Farm farm;

  const FarmAlertsScreen({super.key, required this.farm});

  @override
  State<FarmAlertsScreen> createState() => _FarmAlertsScreenState();
}

class _FarmAlertsScreenState extends State<FarmAlertsScreen> {
  AlertFilter _filter = AlertFilter.all;
  bool _newestFirst = true;

  @override
  Widget build(BuildContext context) {
    final alerts = AppServices.of(context).alerts;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.farm.name} 알림')),
      body: ListenableBuilder(
        listenable: alerts,
        builder: (context, _) => AlertList(
          events: alerts.events,
          farmId: widget.farm.id,
          filter: _filter,
          newestFirst: _newestFirst,
          onFilter: (f) => setState(() => _filter = f),
          onSort: () => setState(() => _newestFirst = !_newestFirst),
        ),
      ),
    );
  }
}

IconData eventIcon(RmuEvent e) => switch (e.type) {
  'alarm' => Icons.warning,
  'clear' => Icons.check_circle,
  'comm' => e.message.contains('끊') ? Icons.link_off : Icons.link,
  'control' => Icons.touch_app,
  'action' => Icons.build,
  _ => Icons.info,
};

Color eventColor(RmuEvent e) => switch (e.type) {
  'clear' => Colors.green,
  'comm' => Colors.grey,
  _ => e.level == 0 ? Colors.blueGrey : levelColor(e.level),
};

/// 작은 표시 (복구, AI 판단)
class _Tag extends StatelessWidget {
  final String text;
  final Color color;

  const _Tag(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: TextStyle(fontSize: 11, color: color)),
  );
}

class _EventTile extends StatelessWidget {
  final RmuEvent event;
  final bool recovered;

  const _EventTile({required this.event, this.recovered = false});

  @override
  Widget build(BuildContext context) {
    final e = event;
    return ListTile(
      leading: Icon(eventIcon(e), color: recovered ? Colors.grey : eventColor(e)),
      title: Row(
        children: [
          Expanded(child: Text(e.message)),
          if (recovered) const _Tag('복구', Colors.green),
          if (e.ai) const _Tag('AI 판단', Colors.indigo),
        ],
      ),
      subtitle: Text(
        '${e.farmName} · ${e.typeName}'
        '${e.type == 'alarm' ? ' · ${alarmLevelNames[e.level.clamp(0, 3)]}' : ''}'
        '${e.code != null ? ' · 코드 ${e.code}' : ''}'
        ' · ${formatDateTime(e.time)}'
        '${e.actions.isNotEmpty ? '\n조치 ${e.actions.length}건' : ''}',
      ),
      isThreeLine: e.actions.isNotEmpty,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AlertDetailScreen(event: e, recovered: recovered),
        ),
      ),
    );
  }
}

/// 알림 상세: 어떤 조치를 했는지 기록을 보여준다. AI 조치는 "AI 판단"으로 구분.
class AlertDetailScreen extends StatelessWidget {
  final RmuEvent event;
  final bool recovered;

  const AlertDetailScreen({super.key, required this.event, this.recovered = false});

  @override
  Widget build(BuildContext context) {
    final e = event;
    return Scaffold(
      appBar: AppBar(title: const Text('알림 상세')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: eventColor(e),
            child: ListTile(
              leading: Icon(eventIcon(e), color: Colors.white),
              title: Text(
                e.message,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                [
                  e.type == 'alarm' ? alarmLevelNames[e.level.clamp(0, 3)] : e.typeName,
                  if (recovered) '이후 복구됨',
                ].join(' · '),
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
          ListTile(title: const Text('농장'), trailing: Text(e.farmName)),
          ListTile(title: const Text('시각'), trailing: Text(formatDateTime(e.time))),
          if (e.code != null)
            ListTile(title: const Text('알람 코드'), trailing: Text('${e.code}')),
          if (e.ai)
            const ListTile(
              leading: Icon(Icons.psychology, color: Colors.indigo),
              title: Text('AI 판단'),
              subtitle: Text('라즈베리파이의 AI가 판단한 알림입니다. 이유는 위 내용을 확인하세요'),
            ),
          if (e.id > 0)
            ListTile(title: const Text('이벤트 번호'), trailing: Text('#${e.id}')),
          const Divider(),
          Text('조치 내역', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (e.actions.isEmpty)
            const Text('기록된 조치가 없습니다')
          else
            for (final a in e.actions)
              ListTile(
                dense: true,
                leading: Icon(
                  a.startsWith('AI') ? Icons.psychology : Icons.check,
                  size: 18,
                ),
                title: Text(a),
              ),
        ],
      ),
    );
  }
}
