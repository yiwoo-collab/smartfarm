import 'package:flutter/material.dart';

import '../services/farm_monitor.dart';
import '../services/rmu_api.dart';
import '../widgets/common.dart';
import 'login_dialog.dart';

/// AI 화면 (CLAUDE.md 7장 AI 판단, 시나리오 25·26·29).
///  - 판단 이유를 항상 보여준다
///  - AI 모드 데모/실사용 전환 (관리자)
///  - 실사용 모드의 제안 목록: 승인하면 실행, 거절하면 기록만 (관리자)
class AiScreen extends StatefulWidget {
  final FarmMonitor monitor;

  const AiScreen({super.key, required this.monitor});

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  List<Map<String, dynamic>> _suggestions = [];
  String? _error;
  bool _busy = false;

  RmuApi get _api => widget.monitor.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _api.fetchSuggestions();
      if (!mounted) return;
      setState(() {
        _suggestions = list;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '제안 목록을 불러오지 못했습니다: $e');
    }
  }

  /// 관리자 작업: 로그인 → 실행 → 상태·목록 새로고침
  Future<void> _admin(Future<void> Function() action, String done) async {
    if (!await ensureLoggedIn(context, widget.monitor)) return;
    setState(() => _busy = true);
    try {
      await action();
      await widget.monitor.refresh();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.monitor,
      builder: (context, _) {
        final s = widget.monitor.status;
        final demo = s?.isDemo ?? true;
        final pending = _suggestions.where((x) => x['status'] == 'pending').toList();
        final done = _suggestions.where((x) => x['status'] != 'pending').toList();
        return Scaffold(
          appBar: AppBar(title: Text('AI 판단 · ${widget.monitor.farm.name}')),
          body: RefreshIndicator(
            onRefresh: () async {
              await widget.monitor.refresh();
              await _load();
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Column(
                    children: [
                      SwitchListTile(
                        secondary: Icon(demo ? Icons.science : Icons.sensors),
                        title: Row(
                          children: [
                            Text(demo ? 'AI 데모 모드' : 'AI 실사용 모드'),
                            if (demo) ...[const SizedBox(width: 6), const DemoBadge()],
                          ],
                        ),
                        subtitle: Text(
                          demo
                              ? '시뮬레이션 값, AI 조치는 자동 실행'
                              : '실제 RMU·센서 값, 위험 낮은 조치(쿨링팬)만 자동, 나머지는 승인 후 실행',
                        ),
                        value: !demo,
                        onChanged: _busy || s == null
                            ? null
                            : (live) => _admin(
                                () => _api.setMode(live ? 'live' : 'demo'),
                                live ? '실사용 모드로 바꿨습니다' : '데모 모드로 바꿨습니다',
                              ),
                      ),
                    ],
                  ),
                ),
                if (s != null)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        Icons.psychology,
                        color: s.ai.active ? Theme.of(context).colorScheme.primary : Colors.grey,
                      ),
                      title: Text(s.ai.active ? 'AI 선가동 중' : '현재 판단'),
                      subtitle: Text(s.ai.reason.isEmpty ? '데이터 수집 중' : s.ai.reason),
                    ),
                  ),
                if (s != null)
                  for (final c in s.conditions.where((c) => c.ai))
                    Card(
                      child: ListTile(
                        leading: Icon(Icons.report, color: levelColor(c.level)),
                        title: Text(c.message),
                        subtitle: const Text('AI 판단 (센서 간 비교·변화율)'),
                      ),
                    ),
                const SizedBox(height: 8),
                Text('승인 대기 제안', style: Theme.of(context).textTheme.titleMedium),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(_error!, style: const TextStyle(color: Colors.red)),
                  ),
                if (pending.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      demo
                          ? '데모 모드에서는 AI가 바로 실행하므로 제안이 없습니다'
                          : '승인을 기다리는 제안이 없습니다',
                    ),
                  ),
                for (final x in pending)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(x['title'] as String,
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text('판단 이유: ${x['reason']}'),
                          Text('위험도: ${x['risk'] == 'low' ? '낮음' : '높음 (승인 필요)'}',
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _admin(
                                        () => _api.decideSuggestion(x['id'] as int, false),
                                        '제안을 거절했습니다',
                                      ),
                                child: const Text('거절'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: _busy
                                    ? null
                                    : () => _admin(
                                        () => _api.decideSuggestion(x['id'] as int, true),
                                        '제안을 승인해 실행했습니다',
                                      ),
                                child: const Text('승인'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (done.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('지난 제안', style: Theme.of(context).textTheme.titleMedium),
                  for (final x in done.take(20))
                    ListTile(
                      dense: true,
                      title: Text(x['title'] as String),
                      subtitle: Text('${x['time']}'),
                      trailing: Text(switch (x['status']) {
                        'approved' => '승인',
                        'rejected' => '거절',
                        _ => '만료',
                      }),
                    ),
                ],
                const SizedBox(height: 8),
                Text(
                  'AI는 허용 목록의 조치만, 시간당 횟수 한도 안에서 실행합니다. '
                  '수동 조작이 항상 우선하고, 임계값은 바꾸지 않고 제안만 합니다.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
