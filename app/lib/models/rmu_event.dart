/// 알림 하나. RMU의 GET /api/events 이벤트이거나,
/// 앱이 직접 만든 통신 두절/복구 알림이다.
class RmuEvent {
  final int id; // RMU 이벤트 번호 (앱이 만든 알림은 0)
  final String farmId;
  final String farmName;
  final DateTime time;
  final int level; // 0~3
  final String type; // alarm, clear, info, control, action, comm
  final String key;
  final String message;
  final List<String> actions; // 조치 내역

  const RmuEvent({
    this.id = 0,
    required this.farmId,
    required this.farmName,
    required this.time,
    required this.level,
    required this.type,
    required this.key,
    required this.message,
    this.actions = const [],
  });

  factory RmuEvent.fromJson(
    Map<String, dynamic> json, {
    required String farmId,
    required String farmName,
  }) => RmuEvent(
    id: json['id'] as int,
    farmId: farmId,
    farmName: farmName,
    time: DateTime.parse(json['time'] as String),
    level: json['level'] as int,
    type: json['type'] as String,
    key: json['key'] as String,
    message: json['message'] as String,
    actions: [for (final a in json['actions'] as List) a as String],
  );

  String get typeName => switch (type) {
    'alarm' => '발생',
    'clear' => '해소',
    'control' => '사용자 조작',
    'action' => '자동 조치',
    'comm' => '통신',
    _ => '안내',
  };
}
