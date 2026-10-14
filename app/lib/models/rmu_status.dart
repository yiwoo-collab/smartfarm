/// GET /api/status 응답 (v3.0). 앱은 OID를 모르고 이름으로만 받는다.
///
/// 항목 상태 (CLAUDE.md 3장 정보없음 규칙)
///   ok      정상
///   nodata  정보없음 (감지기 연결 안 됨/값 없음) → 0이나 마지막 값으로 채우지 않는다
///   fault   센서 오류 (해당 항목만)
///   offline RMU 통신 두절 (마지막 수신값을 회색으로)
class RmuStatus {
  final DateTime time;
  final String mode; // demo / live
  final int alarmLevel; // 0=정상 1=주의 2=경보 3=긴급
  final int alarmCode;
  final String alarmMessage;
  final List<AlarmCondition> conditions;

  final Map<String, double?> sensors; // temperature, humidity, water_level, co2 ...
  final bool? fire; // 화재 감지 (null = 정보없음/오류)
  final Map<String, String> states; // 이름 → ok/nodata/fault/offline

  final bool powerOk;
  final double? acVoltage;
  final double? acFrequency;
  final double? upsBattery;
  final Map<String, double?> partTemps; // pi_temp, main_fan_temp, ...
  final bool? doorOpen;
  final bool mainFanOk;
  final bool backupFanOk;
  final bool fanFailover;

  final Map<String, num> control;
  final NightInfo night;
  final AiInfo ai;
  final RmuLink rmu;

  const RmuStatus({
    required this.time,
    this.mode = 'demo',
    required this.alarmLevel,
    this.alarmCode = 0,
    required this.alarmMessage,
    this.conditions = const [],
    this.sensors = const {},
    this.fire,
    this.states = const {},
    required this.powerOk,
    this.acVoltage,
    this.acFrequency,
    this.upsBattery,
    this.partTemps = const {},
    this.doorOpen,
    this.mainFanOk = true,
    this.backupFanOk = true,
    this.fanFailover = false,
    this.control = const {},
    this.night = const NightInfo(),
    this.ai = const AiInfo(),
    this.rmu = const RmuLink(),
  });

  bool get autoMode => (control['control_mode'] ?? 1) == 1;
  bool get isDemo => mode == 'demo';

  double? get temperature => sensors['temperature'];
  double? get humidity => sensors['humidity'];
  double? get waterLevel => sensors['water_level'];

  /// 항목 상태 (모르면 ok)
  String stateOf(String name) => states[name] ?? 'ok';

  /// 예전 이름 (센서 오류 목록)
  List<String> get sensorErrors =>
      [for (final e in states.entries) if (e.value == 'fault') e.key];

  factory RmuStatus.fromJson(Map<String, dynamic> json) {
    final sensors = (json['sensors'] as Map<String, dynamic>?) ?? {};
    final power = (json['power'] as Map<String, dynamic>?) ?? {};
    final fans = (json['fans'] as Map<String, dynamic>?) ?? {};
    final parts = (json['part_temps'] as Map<String, dynamic>?) ?? {};
    final control = (json['control'] as Map<String, dynamic>?) ?? {};
    final night = json['night'] as Map<String, dynamic>?;
    final ai = json['ai'] as Map<String, dynamic>?;
    final rmu = json['rmu'] as Map<String, dynamic>?;
    return RmuStatus(
      time: DateTime.parse(json['time'] as String),
      mode: (json['mode'] as String?) ?? 'demo',
      alarmLevel: json['alarm_level'] as int,
      alarmCode: (json['alarm_code'] as int?) ?? 0,
      alarmMessage: (json['alarm_message'] as String?) ?? '',
      conditions: [
        for (final c in (json['conditions'] as List?) ?? [])
          AlarmCondition.fromJson(c as Map<String, dynamic>),
      ],
      sensors: {
        for (final e in sensors.entries)
          if (e.value is num || e.value == null) e.key: _num(e.value),
      },
      fire: sensors['fire'] as bool?,
      states: {
        for (final e in ((json['states'] as Map<String, dynamic>?) ?? {}).entries)
          e.key: e.value as String,
      },
      powerOk: (power['power_ok'] as bool?) ?? false,
      acVoltage: _num(power['ac_voltage']),
      acFrequency: _num(power['ac_frequency']),
      upsBattery: _num(power['ups_battery']),
      partTemps: {for (final e in parts.entries) e.key: _num(e.value)},
      doorOpen: json['door_open'] as bool?,
      mainFanOk: (fans['main_ok'] as bool?) ?? true,
      backupFanOk: (fans['backup_ok'] as bool?) ?? true,
      fanFailover: (fans['failover'] as bool?) ?? false,
      control: {for (final e in control.entries) e.key: e.value as num},
      night: night == null ? const NightInfo() : NightInfo.fromJson(night),
      ai: ai == null ? const AiInfo() : AiInfo.fromJson(ai),
      rmu: rmu == null ? const RmuLink() : RmuLink.fromJson(rmu),
    );
  }

  static double? _num(Object? v) => (v as num?)?.toDouble();
}

class AlarmCondition {
  final String key;
  final int level;
  final int code;
  final String message;
  final bool ai;

  const AlarmCondition({
    required this.key,
    required this.level,
    this.code = 0,
    required this.message,
    this.ai = false,
  });

  factory AlarmCondition.fromJson(Map<String, dynamic> json) => AlarmCondition(
    key: json['key'] as String,
    level: json['level'] as int,
    code: (json['code'] as int?) ?? 0,
    message: json['message'] as String,
    ai: (json['ai'] as bool?) ?? false,
  );
}

class NightInfo {
  final bool enabled;
  final int start;
  final int end;
  final bool active;

  const NightInfo({
    this.enabled = true,
    this.start = 21 * 60,
    this.end = 6 * 60,
    this.active = false,
  });

  factory NightInfo.fromJson(Map<String, dynamic> json) => NightInfo(
    enabled: json['night_mode'] == 1,
    start: json['night_start'] as int,
    end: json['night_end'] as int,
    active: json['active'] as bool,
  );
}

/// AI 판단 상태 (판단 이유는 항상 화면에 보여준다)
class AiInfo {
  final bool active;
  final String reason;
  final int pending; // 실사용 모드: 승인을 기다리는 제안 수

  const AiInfo({this.active = false, this.reason = '', this.pending = 0});

  factory AiInfo.fromJson(Map<String, dynamic> json) => AiInfo(
    active: (json['active'] as bool?) ?? false,
    reason: (json['reason'] as String?) ?? '',
    pending: (json['pending'] as int?) ?? 0,
  );
}

/// 라즈베리파이 ↔ RMU 실물 연결 상태
class RmuLink {
  final bool used;
  final bool? connected;
  final DateTime? lastSeen;

  const RmuLink({this.used = false, this.connected, this.lastSeen});

  factory RmuLink.fromJson(Map<String, dynamic> json) => RmuLink(
    used: (json['used'] as bool?) ?? false,
    connected: json['connected'] as bool?,
    lastSeen: json['last_seen'] == null
        ? null
        : DateTime.parse(json['last_seen'] as String),
  );
}

const alarmLevelNames = ['정상', '주의', '경보', '긴급 경보'];

/// 이름 → 화면 표시
const displayNames = {
  'temperature': '온도',
  'temp2': '온도2 (RMU)',
  'humidity': '습도',
  'hum_temp': '온습도감지기 온도',
  'water_level': '수위',
  'fire': '화재',
  'co2': 'CO2',
  'soil_moisture': '토양수분',
  'nutrient_ec': '양분(EC)',
  'ac_voltage': 'AC 전압',
  'pi_temp': '라즈베리파이',
  'main_fan_temp': '메인 환풍기',
  'backup_fan_temp': '예비 환풍기',
  'cooling_fan_temp': '쿨링팬',
  'main_fan': '메인 환풍기',
  'backup_fan': '예비 환풍기',
  'cooling_fan': '쿨링팬',
  'aircon': '에어컨',
  'aircon_setpoint': '에어컨 설정온도',
  'heater': '히터',
  'pump': '펌프',
  'cover': '덮개',
  'lights': '전구',
  'control_mode': '제어 모드',
};
