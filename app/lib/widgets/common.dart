import 'package:flutter/material.dart';

import '../models/rmu_status.dart';

/// 알람 등급 색: 정상 초록, 주의 노랑, 경보 주황, 긴급 빨강
Color levelColor(int level) => const [
  Colors.green,
  Colors.amber,
  Colors.orange,
  Colors.red,
][level.clamp(0, 3)];

String formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

String formatDateTime(DateTime t) => '${t.month}/${t.day} ${formatTime(t)}';

/// 분(0~1439) → "21:00"
String formatMinutes(int m) =>
    '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

/// 현재 알람 등급 카드. stale이면 회색 (통신 두절: 마지막 값)
class AlarmCard extends StatelessWidget {
  final RmuStatus status;
  final bool stale;

  const AlarmCard({super.key, required this.status, this.stale = false});

  @override
  Widget build(BuildContext context) {
    final level = status.alarmLevel.clamp(0, 3);
    final others = status.conditions.skip(1).toList();
    return Card(
      color: stale ? Colors.grey : levelColor(level),
      child: ListTile(
        leading: Icon(
          level == 0 ? Icons.check_circle : Icons.warning,
          color: Colors.white,
        ),
        title: Text(
          '알람 등급: ${alarmLevelNames[level]}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: status.alarmMessage.isEmpty
            ? null
            : Text(
                [
                  status.alarmMessage,
                  for (final c in others) c.message,
                ].join('\n'),
                style: const TextStyle(color: Colors.white),
              ),
      ),
    );
  }
}

/// 이름 - 값 한 줄. stale이면 회색, error면 "센서 오류"
class ValueTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final bool stale;
  final bool error;
  final VoidCallback? onTap; // 누르면 기록 그래프 등

  const ValueTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.stale = false,
    this.error = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = stale
        ? Colors.grey
        : error
        ? Colors.red
        : valueColor;
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: stale ? Colors.grey : null),
        title: Text(label, style: TextStyle(color: stale ? Colors.grey : null)),
        trailing: Text(
          error ? '센서 오류' : value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// 숫자 표시. null이면 '-'
String fmt(double? v, int digits, String unit) =>
    v == null ? '-' : '${v.toStringAsFixed(digits)} $unit';
