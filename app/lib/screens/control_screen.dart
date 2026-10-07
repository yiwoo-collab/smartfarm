import 'package:flutter/material.dart';

import '../models/rmu_status.dart';
import '../services/farm_monitor.dart';
import '../services/rmu_api.dart';
import 'login_dialog.dart';

/// 로그인을 확인한 뒤 제어 화면을 연다 (시나리오 20)
Future<void> openControlScreen(
  BuildContext context,
  FarmMonitor monitor,
) async {
  if (!await ensureLoggedIn(context, monitor)) return;
  if (!context.mounted) return;
  await Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => ControlScreen(monitor: monitor)));
}

/// 장치 제어 화면. 자동 모드에서는 수동 조작이 잠긴다 (시나리오 21).
class ControlScreen extends StatefulWidget {
  final FarmMonitor monitor;

  const ControlScreen({super.key, required this.monitor});

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  static const _devices = [
    'main_fan',
    'backup_fan',
    'cooling_fan',
    'aircon',
    'heater',
    'pump',
    'cover',
    'lights',
  ];

  bool _busy = false;

  Future<void> _send(String device, Object? value) async {
    final monitor = widget.monitor;
    setState(() => _busy = true);
    try {
      await monitor.api.control(device, value);
      await monitor.refresh();
    } on ApiException catch (e) {
      _showMessage(e.message);
      if (e.statusCode == 401 && mounted) {
        await ensureLoggedIn(context, monitor); // 토큰 만료 → 다시 로그인
      }
    } catch (_) {
      _showMessage('RMU에 연결할 수 없습니다');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String _onOffText(String device, bool on) => switch (device) {
    'cover' => on ? '닫힘' : '열림',
    _ => on ? '켜짐' : '꺼짐',
  };

  @override
  Widget build(BuildContext context) {
    final monitor = widget.monitor;
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final status = monitor.status;
        return Scaffold(
          appBar: AppBar(
            title: Text('제어 · ${monitor.farm.name}'),
            actions: [
              IconButton(
                tooltip: '로그아웃',
                icon: const Icon(Icons.logout),
                onPressed: () {
                  monitor.api.logout();
                  Navigator.pop(context);
                },
              ),
            ],
          ),
          body: status == null
              ? const Center(child: Text('RMU 상태를 받지 못했습니다'))
              : _buildBody(status, !monitor.connected),
        );
      },
    );
  }

  Widget _buildBody(RmuStatus status, bool stale) {
    final auto = status.autoMode;
    final locked = auto || _busy || stale;
    final c = status.control;
    final setpoint = (c['aircon_setpoint'] ?? 25).toDouble();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (stale)
          const Card(
            child: ListTile(
              leading: Icon(Icons.link_off),
              title: Text('통신 두절: 제어할 수 없습니다'),
            ),
          ),
        Card(
          child: SwitchListTile(
            title: const Text('자동 제어'),
            subtitle: Text(
              auto
                  ? '알람에 따라 RMU가 장치를 자동으로 조작합니다. 수동 조작은 잠겨 있습니다.'
                  : '수동 모드: 자동 조치를 하지 않습니다. 장치를 직접 조작하세요.',
            ),
            value: auto,
            onChanged: _busy || stale
                ? null
                : (v) => _send('control_mode', v ? 1 : 0),
          ),
        ),
        if (status.fanFailover)
          Card(
            child: ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('예비 환풍기로 대체 중'),
              subtitle: Text(
                status.mainFanOk
                    ? '메인 환풍기가 복구되었습니다. 확인 후 메인으로 전환하세요.'
                    : '메인 환풍기가 아직 고장 상태입니다.',
              ),
              trailing: FilledButton(
                onPressed: status.mainFanOk && !_busy && !stale
                    ? () => _send('restore_main_fan', null)
                    : null,
                child: const Text('메인으로 전환'),
              ),
            ),
          ),
        if (auto)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.lock, size: 18),
                SizedBox(width: 8),
                Expanded(child: Text('자동 모드에서는 아래 장치를 조작할 수 없습니다')),
              ],
            ),
          ),
        Card(
          child: Column(
            children: [
              for (final d in _devices)
                SwitchListTile(
                  title: Text(displayNames[d] ?? d),
                  subtitle: Text(_onOffText(d, c[d] == 1)),
                  value: c[d] == 1,
                  onChanged: locked ? null : (v) => _send(d, v ? 1 : 0),
                ),
              ListTile(
                title: const Text('에어컨 설정온도'),
                subtitle: Text('${setpoint.toStringAsFixed(1)} ℃'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove),
                      onPressed: locked || setpoint <= 16
                          ? null
                          : () => _send('aircon_setpoint', setpoint - 1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: locked || setpoint >= 30
                          ? null
                          : () => _send('aircon_setpoint', setpoint + 1),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
