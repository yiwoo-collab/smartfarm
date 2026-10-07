import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../services/farm_monitor.dart';
import '../widgets/common.dart';

/// 기록 그래프에서 고를 수 있는 항목 (RMU storage.py의 HISTORY_SENSORS와 같은 이름)
class HistorySensor {
  final String key;
  final String label;
  final String unit;
  final int digits;
  final List<(String, String)> thresholds; // (임계값 이름, 표시 글자)

  const HistorySensor(
    this.key,
    this.label,
    this.unit,
    this.digits, [
    this.thresholds = const [],
  ]);
}

const historySensors = [
  HistorySensor('temperature', '온도', '℃', 1, [
    ('temp_high', '상한'),
    ('temp_low', '하한'),
  ]),
  HistorySensor('humidity', '습도', '%', 1, [
    ('humidity_high', '상한'),
    ('humidity_low', '하한'),
  ]),
  HistorySensor('soil_moisture', '토양수분', '%', 0, [('soil_low', '하한')]),
  HistorySensor('co2', 'CO2', 'ppm', 0, [('co2_high', '상한')]),
  HistorySensor('nutrient_ec', '양분(EC)', 'mS/cm', 2, [('ec_low', '하한')]),
  HistorySensor('supply_voltage', '공급 전압', 'V', 2, [('voltage_low', '하한')]),
  HistorySensor('supply_current', '공급 전류', 'A', 2, [('current_high', '상한')]),
  HistorySensor('greenhouse_power', '온실 전체 전력', 'W', 0),
  HistorySensor('rmu_temp', 'RMU 온도', '℃', 1, [('rmu_temp_high', '상한')]),
  HistorySensor('alarm_level', '알람 등급', '', 0),
];

const _ranges = {'1h': '1시간', '6h': '6시간', '24h': '24시간', '7d': '7일'};

/// 기록 그래프 (2단계, 시나리오: 히스토리 그래프)
class HistoryScreen extends StatefulWidget {
  final FarmMonitor monitor;
  final String initialSensor;

  const HistoryScreen({
    super.key,
    required this.monitor,
    this.initialSensor = 'temperature',
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late HistorySensor _sensor = historySensors.firstWhere(
    (s) => s.key == widget.initialSensor,
    orElse: () => historySensors.first,
  );
  String _range = '1h';
  List<({DateTime time, double value})>? _points;
  Map<String, dynamic> _thresholds = {};
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = widget.monitor.api;
    try {
      final results = await Future.wait([
        api.fetchHistory(_sensor.key, _range),
        api.fetchThresholds(),
      ]);
      if (!mounted) return;
      setState(() {
        _points = results[0] as List<({DateTime time, double value})>;
        _thresholds = results[1] as Map<String, dynamic>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'RMU에서 기록을 받지 못했습니다');
    }
  }

  void _select({HistorySensor? sensor, String? range}) {
    setState(() {
      _sensor = sensor ?? _sensor;
      _range = range ?? _range;
      _points = null;
    });
    _load();
  }

  String _fmt(double v) =>
      '${v.toStringAsFixed(_sensor.digits)}${_sensor.unit.isEmpty ? '' : ' ${_sensor.unit}'}';

  @override
  Widget build(BuildContext context) {
    final points = _points;
    return Scaffold(
      appBar: AppBar(title: Text('기록 · ${widget.monitor.farm.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 필터는 그래프 위 한 줄에 (항목, 기간)
          Row(
            children: [
              Expanded(
                child: DropdownButton<HistorySensor>(
                  isExpanded: true,
                  value: _sensor,
                  items: [
                    for (final s in historySensors)
                      DropdownMenuItem(value: s, child: Text(s.label)),
                  ],
                  onChanged: (s) => _select(sensor: s),
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  for (final e in _ranges.entries)
                    ButtonSegment(value: e.key, label: Text(e.value)),
                ],
                selected: {_range},
                onSelectionChanged: (s) => _select(range: s.first),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '${_sensor.label}${_sensor.unit.isEmpty ? '' : ' (${_sensor.unit})'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red))
          else if (points == null)
            const SizedBox(
              height: 240,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (points.isEmpty)
            const SizedBox(
              height: 240,
              child: Center(child: Text('기록이 아직 없습니다 (10초마다 기록)')),
            )
          else ...[
            SizedBox(height: 260, child: _chart(context, points)),
            const SizedBox(height: 16),
            _stats(points),
          ],
        ],
      ),
    );
  }

  /// 현재·최저·최고 (그래프 없이도 숫자를 읽을 수 있게)
  Widget _stats(List<({DateTime time, double value})> points) {
    final values = points.map((p) => p.value);
    Widget tile(String label, double v) => Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(
                _fmt(v),
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
    return Row(
      children: [
        tile('최근 평균', points.last.value),
        tile('최저', values.reduce(math.min)),
        tile('최고', values.reduce(math.max)),
      ],
    );
  }

  Widget _chart(
    BuildContext context,
    List<({DateTime time, double value})> points,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final start = points.first.time;
    double x(DateTime t) => t.difference(start).inSeconds / 60; // 분

    // 임계값 선 (값이 있는 것만)
    final lines = <HorizontalLine>[];
    for (final (key, label) in _sensor.thresholds) {
      final v = (_thresholds[key] as num?)?.toDouble();
      if (v == null) continue;
      lines.add(
        HorizontalLine(
          y: v,
          color: Colors.red.withValues(alpha: 0.7),
          strokeWidth: 1,
          dashArray: [6, 4],
          label: HorizontalLineLabel(
            show: true,
            alignment: Alignment.topRight,
            style: TextStyle(color: muted, fontSize: 11),
            labelResolver: (_) => '$label ${_fmt(v)}',
          ),
        ),
      );
    }

    // 세로축 범위: 데이터와 임계값이 모두 보이게
    final ys = [...points.map((p) => p.value), ...lines.map((l) => l.y)];
    var minY = ys.reduce(math.min);
    var maxY = ys.reduce(math.max);
    final pad = math.max((maxY - minY) * 0.1, 0.5);
    minY -= pad;
    maxY += pad;
    final spanMinutes = math.max(x(points.last.time), 1.0);

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        minX: 0,
        maxX: spanMinutes,
        lineBarsData: [
          LineChartBarData(
            spots: [for (final p in points) FlSpot(x(p.time), p.value)],
            color: scheme.primary,
            barWidth: 2,
            isCurved: false,
            dotData: const FlDotData(show: false),
          ),
        ],
        extraLinesData: ExtraLinesData(horizontalLines: lines),
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: muted.withValues(alpha: 0.15), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 48,
              // 범위 끝(여유 공간)의 눈금 글자는 생략
              getTitlesWidget: (v, meta) => v == meta.min || v == meta.max
                  ? const SizedBox.shrink()
                  : SideTitleWidget(
                      meta: meta,
                      child: Text(
                        v.toStringAsFixed(_sensor.digits),
                        style: TextStyle(color: muted, fontSize: 11),
                      ),
                    ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: math.max(spanMinutes / 4, 1),
              getTitlesWidget: (v, meta) {
                // 오른쪽 끝 글자는 잘리고 바로 앞 눈금과 겹치기 쉬워 생략
                if (v == meta.max && v != 0) return const SizedBox.shrink();
                final t = start.add(Duration(seconds: (v * 60).round()));
                final text = _range == '7d'
                    ? '${t.month}/${t.day}'
                    : formatMinutes(t.hour * 60 + t.minute);
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    text,
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                );
              },
            ),
          ),
        ),
        // 손가락/마우스를 올리면 시각과 값을 보여준다
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => scheme.inverseSurface,
            getTooltipItems: (spots) => [
              for (final s in spots)
                LineTooltipItem(
                  '${formatDateTime(start.add(Duration(seconds: (s.x * 60).round())))}\n${_fmt(s.y)}',
                  TextStyle(color: scheme.onInverseSurface, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
