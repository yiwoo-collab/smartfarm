import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/rmu_event.dart';
import '../models/rmu_status.dart';
import '../widgets/common.dart';

/// 알림 탭: 등록된 전체 농장의 알림을 한 곳에 보여준다 (시나리오 17).
/// 항목마다 농장 이름을 표시하고, 농장별로 거를 수 있다.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  String? _farmFilter; // null이면 전체
  bool _onlyAlarms = false; // 발생·통신·주요 안내만

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([services.alerts, services.farms]),
      builder: (context, _) {
        final farms = services.farms.farms;
        if (_farmFilter != null && !farms.any((f) => f.id == _farmFilter)) {
          _farmFilter = null; // 삭제된 농장
        }
        final events = services.alerts.events.where((e) {
          if (_farmFilter != null && e.farmId != _farmFilter) return false;
          if (_onlyAlarms &&
              !(e.type == 'alarm' || e.type == 'comm' || e.level > 0)) {
            return false;
          }
          return true;
        }).toList();

        return Scaffold(
          appBar: AppBar(title: const Text('알림')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    _chip(
                      '전체 농장',
                      _farmFilter == null,
                      () => _farmFilter = null,
                    ),
                    for (final f in farms)
                      _chip(
                        f.name,
                        _farmFilter == f.id,
                        () => _farmFilter = f.id,
                      ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('경보만'),
                      selected: _onlyAlarms,
                      onSelected: (v) => setState(() => _onlyAlarms = v),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: events.isEmpty
                    ? const Center(child: Text('알림이 없습니다'))
                    : ListView.separated(
                        itemCount: events.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) =>
                            _EventTile(event: events[i]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(onTap),
    ),
  );
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

class _EventTile extends StatelessWidget {
  final RmuEvent event;

  const _EventTile({required this.event});

  @override
  Widget build(BuildContext context) {
    final e = event;
    return ListTile(
      leading: Icon(eventIcon(e), color: eventColor(e)),
      title: Text(e.message),
      subtitle: Text(
        '${e.farmName} · ${e.typeName}'
        '${e.type == 'alarm' ? ' · ${alarmLevelNames[e.level]}' : ''}'
        ' · ${formatDateTime(e.time)}'
        '${e.actions.isNotEmpty ? '\n조치 ${e.actions.length}건' : ''}',
      ),
      isThreeLine: e.actions.isNotEmpty,
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => AlertDetailScreen(event: e))),
    );
  }
}

/// 알림 상세: 어떤 조치를 했는지 기록을 보여준다
class AlertDetailScreen extends StatelessWidget {
  final RmuEvent event;

  const AlertDetailScreen({super.key, required this.event});

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
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                e.type == 'alarm' ? alarmLevelNames[e.level] : e.typeName,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
          ListTile(title: const Text('농장'), trailing: Text(e.farmName)),
          ListTile(
            title: const Text('시각'),
            trailing: Text(formatDateTime(e.time)),
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
                leading: const Icon(Icons.check, size: 18),
                title: Text(a),
              ),
        ],
      ),
    );
  }
}
