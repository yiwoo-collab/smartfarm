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

/// 숫자 표시. null이면 '-'
String fmt(double? v, int digits, String unit) =>
    v == null ? '-' : '${v.toStringAsFixed(digits)} $unit';

/// 데모 모드 배지. 농장 이름의 일부가 아니라 따로 붙인다 (CLAUDE.md 3장)
class DemoBadge extends StatelessWidget {
  const DemoBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '데모',
        style: TextStyle(fontSize: 11, color: scheme.onTertiaryContainer),
      ),
    );
  }
}

/// 현재 알람 등급 카드. stale이면 회색 (통신 두절: 마지막 값)
class AlarmCard extends StatelessWidget {
  final RmuStatus status;
  final bool stale;

  const AlarmCard({super.key, required this.status, this.stale = false});

  @override
  Widget build(BuildContext context) {
    final level = status.alarmLevel.clamp(0, 3);
    final others = status.conditions.skip(1).toList();
    final code = status.alarmCode > 0 ? ' · 코드 ${status.alarmCode}' : '';
    return Card(
      color: stale ? Colors.grey : levelColor(level),
      child: ListTile(
        leading: Icon(
          level == 0 ? Icons.check_circle : Icons.warning,
          color: Colors.white,
        ),
        title: Text(
          '알람 등급: ${alarmLevelNames[level]}$code',
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

/// 이름 - 값 한 줄.
/// state: ok / nodata(정보없음) / fault(센서 오류) / offline(RMU 통신 두절, 회색)
/// stale: 라즈베리파이와 통신 두절 (농장 전체, 회색)
class ValueTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final bool stale;
  final String state;
  final VoidCallback? onTap;

  const ValueTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.stale = false,
    this.state = 'ok',
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final grey = stale || state == 'offline' || state == 'nodata';
    final (text, color) = switch (state) {
      'nodata' => ('정보없음', Colors.grey),
      'fault' => ('센서 오류', Colors.red),
      'offline' => ('$value (RMU 두절)', Colors.grey),
      _ => (value, stale ? Colors.grey : valueColor),
    };
    return Card(
      child: ListTile(
        onTap: state == 'nodata' ? null : onTap,
        leading: Icon(icon, color: grey ? Colors.grey : null),
        title: Text(label, style: TextStyle(color: grey ? Colors.grey : null)),
        trailing: Text(
          text,
          style: TextStyle(
            fontSize: state == 'nodata' ? 14 : 18,
            fontWeight: state == 'nodata' ? null : FontWeight.bold,
            color: color,
          ),
        ),
      ),
    );
  }
}
