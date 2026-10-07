import 'package:flutter/material.dart';

import '../services/farm_monitor.dart';
import '../services/rmu_api.dart';
import '../widgets/common.dart';
import 'login_dialog.dart';

/// 설정 > RMU 관리 > 농장 하나
class FarmAdminScreen extends StatefulWidget {
  final FarmMonitor monitor;

  const FarmAdminScreen({super.key, required this.monitor});

  @override
  State<FarmAdminScreen> createState() => _FarmAdminScreenState();
}

class _FarmAdminScreenState extends State<FarmAdminScreen> {
  /// 로그인이 필요한 화면은 로그인 확인 후 연다
  Future<void> _openWithLogin(Widget screen) async {
    if (!await ensureLoggedIn(context, widget.monitor)) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    setState(() {}); // 로그인 상태 갱신
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.monitor;
    return Scaffold(
      appBar: AppBar(title: Text('RMU 관리 · ${m.farm.name}')),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(m.api.loggedIn ? Icons.lock_open : Icons.lock),
            title: Text(m.api.loggedIn ? '관리자 로그인됨' : '로그인 안 됨'),
            subtitle: const Text('야간 모드·임계값 변경과 제어는 로그인이 필요합니다'),
            trailing: m.api.loggedIn
                ? TextButton(
                    onPressed: () => setState(m.api.logout),
                    child: const Text('로그아웃'),
                  )
                : TextButton(
                    onPressed: () async {
                      await ensureLoggedIn(context, m);
                      setState(() {});
                    },
                    child: const Text('로그인'),
                  ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.nightlight),
            title: const Text('야간 모드'),
            subtitle: const Text('시작·종료 시각, 덮개 닫힘·전구 소등'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openWithLogin(NightSettingsScreen(monitor: m)),
          ),
          ListTile(
            leading: const Icon(Icons.rule),
            title: const Text('임계값'),
            subtitle: const Text('센서·부품별 상한/하한'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openWithLogin(ThresholdsScreen(monitor: m)),
          ),
          ListTile(
            leading: const Icon(Icons.science),
            title: const Text('시뮬레이션 (개발·시연용)'),
            subtitle: const Text('고온, 환풍기 고장, 통신 두절 등 상황 주입'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SimulationScreen(monitor: m)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 공통: API 오류 메시지를 SnackBar로
void showApiError(BuildContext context, Object e) {
  final text = e is ApiException ? e.message : 'RMU에 연결할 수 없습니다';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

// ---------------------------------------------------------------------------
// 야간 모드 (시나리오 14)
// ---------------------------------------------------------------------------
class NightSettingsScreen extends StatefulWidget {
  final FarmMonitor monitor;

  const NightSettingsScreen({super.key, required this.monitor});

  @override
  State<NightSettingsScreen> createState() => _NightSettingsScreenState();
}

class _NightSettingsScreenState extends State<NightSettingsScreen> {
  bool? _enabled;
  int _start = 21 * 60;
  int _end = 6 * 60;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.monitor.api.fetchSettings();
      setState(() {
        _enabled = s['night_mode'] == 1;
        _start = s['night_start'] as int;
        _end = s['night_end'] as int;
      });
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _pick(bool start) async {
    final current = start ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked == null) return;
    setState(() {
      final m = picked.hour * 60 + picked.minute;
      start ? _start = m : _end = m;
    });
  }

  Future<void> _save() async {
    if (_start == _end) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('시작과 종료 시각이 같을 수 없습니다')));
      return;
    }
    try {
      await widget.monitor.api.updateSettings({
        'night_mode': _enabled! ? 1 : 0,
        'night_start': _start,
        'night_end': _end,
      });
      await widget.monitor.refresh();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    return Scaffold(
      appBar: AppBar(title: const Text('야간 모드')),
      body: enabled == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  title: const Text('야간 모드 사용'),
                  subtitle: const Text('야간에는 덮개를 닫아 햇빛을 차단하고 전구를 모두 소등합니다'),
                  value: enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                ListTile(
                  title: const Text('시작 시각'),
                  trailing: Text(formatMinutes(_start)),
                  onTap: () => _pick(true),
                ),
                ListTile(
                  title: const Text('종료 시각'),
                  trailing: Text(formatMinutes(_end)),
                  onTap: () => _pick(false),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _start == _end
                        ? '시작과 종료 시각이 같을 수 없습니다'
                        : _start > _end
                        ? '자정을 넘는 구간입니다 (${formatMinutes(_start)} ~ 다음 날 ${formatMinutes(_end)})'
                        : '${formatMinutes(_start)} ~ ${formatMinutes(_end)}',
                    style: TextStyle(color: _start == _end ? Colors.red : null),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: _save,
                    child: const Text('저장'),
                  ),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// 임계값
// ---------------------------------------------------------------------------
class ThresholdsScreen extends StatefulWidget {
  final FarmMonitor monitor;

  const ThresholdsScreen({super.key, required this.monitor});

  @override
  State<ThresholdsScreen> createState() => _ThresholdsScreenState();
}

class _ThresholdsScreenState extends State<ThresholdsScreen> {
  static const _labels = {
    'temp_low': ('온도 하한', '℃'),
    'temp_high': ('온도 상한', '℃'),
    'humidity_low': ('습도 하한', '%'),
    'humidity_high': ('습도 상한', '%'),
    'soil_low': ('토양수분 하한', '%'),
    'voltage_low': ('공급 전압 하한', 'V'),
    'current_high': ('공급 전류 상한', 'A'),
    'co2_high': ('CO2 상한', 'ppm'),
    'ec_low': ('양분(EC) 하한', 'mS/cm'),
    'rmu_temp_high': ('RMU 온도 상한', '℃'),
    'part_temp_high': ('환풍기·쿨링팬 온도 상한', '℃'),
    'part_temp_low': ('부품 온도 하한', '℃'),
    'cooling_setpoint': ('고온 시 에어컨 설정온도', '℃'),
    'heating_setpoint': ('저온 시 에어컨 설정온도', '℃'),
  };

  final Map<String, TextEditingController> _fields = {};
  Map<String, dynamic> _crops = {}; // 작물별 기본값 (RMU의 crops.json)
  bool _loaded = false;

  /// 작물 기본값을 입력칸에 채운다 (저장을 눌러야 RMU에 반영)
  void _applyCrop(String crop) {
    final values = _crops[crop] as Map<String, dynamic>;
    setState(() {
      for (final e in values.entries) {
        _fields[e.key]?.text = '${e.value}';
      }
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$crop 기본값을 채웠습니다. 확인 후 저장을 누르세요')));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await widget.monitor.api.fetchThresholds();
      try {
        _crops = await widget.monitor.api.fetchCrops();
      } catch (_) {
        _crops = {}; // 예전 RMU면 작물 기본값 없이 진행
      }
      if (!mounted) return;
      setState(() {
        for (final e in t.entries) {
          _fields[e.key] = TextEditingController(text: '${e.value}');
        }
        _loaded = true;
      });
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _save() async {
    final changes = <String, num>{};
    for (final e in _fields.entries) {
      final v = num.tryParse(e.value.text.trim());
      if (v == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_labels[e.key]?.$1 ?? e.key}: 숫자를 입력하세요')),
        );
        return;
      }
      changes[e.key] = v;
    }
    try {
      await widget.monitor.api.updateThresholds(changes);
      await widget.monitor.refresh();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('임계값 · ${widget.monitor.farm.crop}')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_crops.isNotEmpty) ...[
                  Text(
                    '작물 기본값 불러오기 (제안 값)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final crop in _crops.keys)
                        ActionChip(
                          avatar: crop == widget.monitor.farm.crop
                              ? const Icon(Icons.star, size: 18)
                              : null,
                          label: Text(crop),
                          onPressed: () => _applyCrop(crop),
                        ),
                    ],
                  ),
                  const Divider(height: 32),
                ],
                for (final e in _fields.entries)
                  TextField(
                    controller: e.value,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _labels[e.key]?.$1 ?? e.key,
                      suffixText: _labels[e.key]?.$2,
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _save, child: const Text('저장')),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// 시뮬레이션 (CLAUDE.md 8장: 각 시나리오를 버튼으로 재현)
// ---------------------------------------------------------------------------
class SimulationScreen extends StatefulWidget {
  final FarmMonitor monitor;

  const SimulationScreen({super.key, required this.monitor});

  @override
  State<SimulationScreen> createState() => _SimulationScreenState();
}

class _SimulationScreenState extends State<SimulationScreen> {
  List<Map<String, dynamic>>? _scenarios;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.monitor.api.fetchScenarios();
      setState(() => _scenarios = list);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _run(Map<String, dynamic> s) async {
    final body = <String, dynamic>{
      'scenario': s['name'],
      ...((s['params'] as Map<String, dynamic>?) ?? {}),
    };
    try {
      final message = await widget.monitor.api.simulate(body);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${widget.monitor.farm.name}: $message')),
      );
      await widget.monitor.refresh();
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scenarios = _scenarios;
    final m = widget.monitor;
    return Scaffold(
      appBar: AppBar(title: Text('시뮬레이션 · ${m.farm.name}')),
      body: scenarios == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 지금 상태를 같이 보여줘서 결과를 바로 확인할 수 있게
                ListenableBuilder(
                  listenable: m,
                  builder: (context, _) {
                    final s = m.status;
                    if (!m.connected) {
                      return const Card(
                        child: ListTile(
                          leading: Icon(Icons.link_off),
                          title: Text('통신 두절 중'),
                        ),
                      );
                    }
                    if (s == null) return const SizedBox();
                    return AlarmCard(status: s);
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in scenarios)
                      ActionChip(
                        avatar: CircleAvatar(
                          child: Text(
                            '${s['scenario']}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        label: Text(s['label'] as String),
                        onPressed: () => _run(s),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '동그라미 숫자는 CLAUDE.md 8장 시나리오 번호입니다.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}
