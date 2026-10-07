import 'dart:async';

import 'package:flutter/material.dart';

import '../models/rmu_status.dart';
import '../services/farm_monitor.dart';
import '../widgets/common.dart';
import 'history_screen.dart';

/// 세부 화면 (CLAUDE.md 3장)
///  - 공급 전압·전류와 정상 여부
///  - 온실 전체 사용 전력: 순간 전력(W)과 누적 전력량(kWh) 구분 (시뮬레이션 값)
///  - RMU 온도, 환풍기·쿨링팬 장비 온도
///  - CO2, 양분(EC)
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

  @override
  Widget build(BuildContext context) {
    final monitor = widget.monitor;
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final status = monitor.status;
        final stale = !monitor.connected;
        final power = _power;
        final errors = status?.sensorErrors ?? const [];
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
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => HistoryScreen(monitor: monitor),
                  ),
                ),
              ),
              _section(context, '공급 전원 (INA219)'),
              if (power != null) ...[
                ValueTile(
                  icon: Icons.bolt,
                  label: '전압',
                  value:
                      '${(power['supply_voltage'] as num).toStringAsFixed(2)} V',
                  valueColor: _voltageOk(power) ? null : Colors.red,
                  stale: stale,
                ),
                ValueTile(
                  icon: Icons.electric_meter,
                  label: '전류',
                  value:
                      '${(power['supply_current'] as num).toStringAsFixed(2)} A',
                  valueColor: _currentOk(power) ? null : Colors.red,
                  stale: stale,
                ),
                ValueTile(
                  icon: Icons.power,
                  label: '공급 전원 상태',
                  value: power['power_ok'] == true ? '정상' : '이상',
                  valueColor: power['power_ok'] == true ? null : Colors.red,
                  stale: stale,
                ),
                Text(
                  '기준: 전압 ${power['voltage_low']} V 이상, 전류 ${power['current_high']} A 이하',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                _section(context, '온실 전체 사용 전력 (시뮬레이션)'),
                ValueTile(
                  icon: Icons.speed,
                  label: '순간 전력',
                  value: '${power['greenhouse_power']} W',
                  stale: stale,
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
                            style: TextStyle(
                              color: d['on'] == true ? null : Colors.grey,
                            ),
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
              if (status != null) ...[
                _section(context, '부품·장비 온도'),
                for (final e in status.partTemps.entries)
                  ValueTile(
                    icon: Icons.device_thermostat,
                    label: displayNames[e.key] ?? e.key,
                    value: fmt(e.value, 1, '℃'),
                    stale: stale,
                    error: errors.contains(e.key),
                    valueColor: _partLevel(status, e.key) > 0
                        ? levelColor(_partLevel(status, e.key))
                        : null,
                  ),
                _section(context, '환풍기'),
                ValueTile(
                  icon: Icons.wind_power,
                  label: '메인 환풍기',
                  value: status.mainFanOk ? '정상' : '고장',
                  valueColor: status.mainFanOk ? null : Colors.red,
                  stale: stale,
                ),
                ValueTile(
                  icon: Icons.wind_power,
                  label: '예비 환풍기',
                  value: status.backupFanOk ? '정상' : '고장',
                  valueColor: status.backupFanOk ? null : Colors.red,
                  stale: stale,
                ),
                _section(context, '기타 센서 (시뮬레이션)'),
                ValueTile(
                  icon: Icons.co2,
                  label: 'CO2',
                  value: fmt(status.co2, 0, 'ppm'),
                  stale: stale,
                  error: errors.contains('co2'),
                ),
                ValueTile(
                  icon: Icons.science,
                  label: '양분(EC)',
                  value: fmt(status.nutrientEc, 2, 'mS/cm'),
                  stale: stale,
                  error: errors.contains('nutrient_ec'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  bool _voltageOk(Map<String, dynamic> p) =>
      (p['supply_voltage'] as num) >= (p['voltage_low'] as num);

  bool _currentOk(Map<String, dynamic> p) =>
      (p['supply_current'] as num) <= (p['current_high'] as num);

  /// 해당 부품에 걸린 알람 등급 (없으면 0)
  int _partLevel(RmuStatus s, String part) => s.conditions
      .where((c) => c.key == 'part:$part')
      .fold(0, (m, c) => c.level > m ? c.level : m);

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}
