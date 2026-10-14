import 'dart:async';

import 'package:flutter/material.dart';

import '../models/rmu_status.dart';
import '../services/farm_monitor.dart';
import '../widgets/common.dart';
import 'history_screen.dart';

/// 세부 화면 (CLAUDE.md 3장 v3.0)
///  - 전원 상태: RMU acv1(AC 전압), ach1(주파수)과 정상 여부, UPS 배터리
///  - 온실 전체 사용 전력: 순간 전력(W)과 누적 전력량(kWh) 구분 (시뮬레이션 값)
///  - 라즈베리파이 온도, 환풍기·쿨링팬 장비 온도
///  - RMU 연결 상태, 온도2, 전면 도어
class DetailScreen extends StatefulWidget {
  final FarmMonitor monitor;

  const DetailScreen({super.key, required this.monitor});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  Map<String, dynamic>? _power;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadPower();
    _timer = Timer.periodic(FarmMonitor.refreshInterval, (_) => _loadPower());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadPower() async {
    try {
      final power = await widget.monitor.api.fetchPower();
      if (mounted) setState(() => _power = power);
    } catch (_) {
      // 통신 두절이면 마지막 값을 회색으로 둔다 (monitor.connected로 판단)
    }
  }

  void _history(String sensor) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => HistoryScreen(monitor: widget.monitor, initialSensor: sensor),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final monitor = widget.monitor;
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final s = monitor.status;
        final stale = !monitor.connected;
        final power = _power;
        return Scaffold(
          appBar: AppBar(title: Text('세부 정보 · ${monitor.farm.name}')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (stale)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.link_off),
                    title: Text('통신 두절: 마지막 수신값입니다'),
                  ),
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.show_chart),
                label: const Text('기록 그래프'),
                onPressed: () => _history('temperature'),
              ),
              if (s != null) ...[
                _section(context, 'RMU 연결'),
                _rmuTile(s),
                _section(context, '전원 (RMU acv1 · ach1)'),
                ValueTile(
                  icon: Icons.bolt,
                  label: 'AC 전압',
                  value: fmt(s.acVoltage, 1, 'V'),
                  valueColor: s.powerOk ? null : Colors.red,
                  stale: stale,
                  state: s.stateOf('ac_voltage'),
                  onTap: () => _history('ac_voltage'),
                ),
                ValueTile(
                  icon: Icons.graphic_eq,
                  label: 'AC 주파수',
                  value: fmt(s.acFrequency, 1, 'Hz'),
                  stale: stale,
                  state: s.stateOf('ac_frequency'),
                ),
                ValueTile(
                  icon: Icons.power,
                  label: '전원 공급 상태',
                  value: s.powerOk ? '정상' : '이상',
                  valueColor: s.powerOk ? null : Colors.red,
                  stale: stale,
                  state: s.stateOf('ac_voltage'),
                ),
                ValueTile(
                  icon: Icons.battery_std,
                  label: 'UPS 배터리',
                  value: fmt(s.upsBattery, 0, '%'),
                  stale: stale,
                  state: s.stateOf('ups_battery'),
                ),
                if (power != null)
                  Text(
                    '기준: AC ${power['ac_voltage_low']}~${power['ac_voltage_high']} V (RMU setAcv1Uvt/Ovt)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              _section(context, '온실 전체 사용 전력 (시뮬레이션)'),
              if (power != null) ...[
                ValueTile(
                  icon: Icons.speed,
                  label: '순간 전력',
                  value: '${power['greenhouse_power']} W',
                  stale: stale,
                  onTap: () => _history('greenhouse_power'),
                ),
                ValueTile(
                  icon: Icons.summarize,
                  label: '누적 전력량',
                  value:
                      '${(power['greenhouse_energy_kwh'] as num).toStringAsFixed(3)} kWh',
                  stale: stale,
                ),
                Card(
                  child: Column(
                    children: [
                      for (final d in power['devices'] as List)
                        ListTile(
                          dense: true,
                          title: Text(d['label'] as String),
                          trailing: Text(
                            d['on'] == true ? '${d['watts']} W' : '꺼짐',
                            style: TextStyle(color: d['on'] == true ? null : Colors.grey),
                          ),
                        ),
                    ],
                  ),
                ),
              ] else
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (s != null) ...[
                _section(context, '라즈베리파이·장비 온도'),
                for (final e in s.partTemps.entries)
                  ValueTile(
                    icon: Icons.device_thermostat,
                    label: displayNames[e.key] ?? e.key,
                    value: fmt(e.value, 1, '℃'),
                    stale: stale,
                    state: s.stateOf(e.key),
                    valueColor: _partLevel(s, e.key) > 0
                        ? levelColor(_partLevel(s, e.key))
                        : null,
                    onTap: () => _history(e.key),
                  ),
                _section(context, '환풍기'),
                ValueTile(
                  icon: Icons.wind_power,
                  label: '메인 환풍기',
                  value: s.mainFanOk ? '정상' : '고장',
                  valueColor: s.mainFanOk ? null : Colors.red,
                  stale: stale,
                ),
                ValueTile(
                  icon: Icons.wind_power,
                  label: '예비 환풍기',
                  value: s.backupFanOk ? '정상' : '고장',
                  valueColor: s.backupFanOk ? null : Colors.red,
                  stale: stale,
                ),
                _section(context, '기타'),
                ValueTile(
                  icon: Icons.thermostat,
                  label: displayNames['temp2']!,
                  value: fmt(s.sensors['temp2'], 1, '℃'),
                  stale: stale,
                  state: s.stateOf('temp2'),
                  onTap: () => _history('temp2'),
                ),
                ValueTile(
                  icon: Icons.thermostat_auto,
                  label: displayNames['hum_temp']!,
                  value: fmt(s.sensors['hum_temp'], 1, '℃'),
                  stale: stale,
                  state: s.stateOf('hum_temp'),
                  onTap: () => _history('hum_temp'),
                ),
                ValueTile(
                  icon: Icons.door_front_door,
                  label: '전면 도어 (RMU)',
                  value: s.doorOpen == null ? '-' : (s.doorOpen! ? '열림' : '닫힘'),
                  valueColor: s.doorOpen == true ? Colors.orange : null,
                  stale: stale,
                  state: s.doorOpen == null ? 'nodata' : s.stateOf('door_front'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _rmuTile(RmuStatus s) {
    if (!s.rmu.used) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.router, color: Colors.grey),
          title: Text('RMU 실물 미사용'),
          subtitle: Text('RMU 항목(온도·전원)은 시뮬레이션 값입니다'),
        ),
      );
    }
    final ok = s.rmu.connected == true;
    return Card(
      child: ListTile(
        leading: Icon(Icons.router, color: ok ? Colors.green : Colors.grey),
        title: Text(ok ? 'RMU 연결됨 (SNMP v2c)' : 'RMU 통신 두절'),
        subtitle: Text(
          s.rmu.lastSeen == null ? '받은 값이 없습니다' : '마지막 수신 ${formatTime(s.rmu.lastSeen!)}',
        ),
      ),
    );
  }

  /// 해당 부품에 걸린 알람 등급 (없으면 0)
  int _partLevel(RmuStatus s, String part) => s.conditions
      .where((c) => c.key == 'part:$part')
      .fold(0, (m, c) => c.level > m ? c.level : m);

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}
