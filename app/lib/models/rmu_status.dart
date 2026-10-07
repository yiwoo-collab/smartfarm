/// GET /api/status 응답.
/// 앱은 OID를 모르고 이름으로만 받는다 (CLAUDE.md 10장).
/// 센서 값이 null이면 그 센서는 오류 상태다 (시나리오 13).
class RmuStatus {
  final DateTime time;
  final int alarmLevel; // 0=정상 1=주의 2=경보 3=긴급
  final String alarmMessage;
  final List<AlarmCondition> conditions;

  final double? temperature; // ℃
  final double? humidity; // %
  final double? soilMoisture; // %
  final double? co2; // ppm
  final double? nutrientEc; // mS/cm
  final List<String> sensorErrors;

  final bool powerOk; // 공급 전원 정상 여부
  final Map<String, double?> partTemps; // rmu_temp, main_fan_temp, ...
  final bool mainFanOk;
  final bool backupFanOk;
  final bool fanFailover; // 메인 → 예비 대체 중

  final Map<String, num> control; // 장치 상태 (0/1, 에어컨 설정온도)
  final NightInfo night;
  final bool aiActive; // AI 선가동 중 (시나리오 22)
  final String aiReason; // AI 판단 이유 (항상 표시)

  const RmuStatus({
    required this.time,
    required this.alarmLevel,
    required this.alarmMessage,
    this.conditions = const [],
    this.temperature,
    this.humidity,
    this.soilMoisture,
    this.co2,
    this.nutrientEc,
    this.sensorErrors = const [],
    required this.powerOk,
    this.partTemps = const {},
    this.mainFanOk = true,
    this.backupFanOk = true,
    this.fanFailover = false,
    this.control = const {},
    this.night = const NightInfo(),
    this.aiActive = false,
    this.aiReason = '',
  });

  bool get autoMode => (control['control_mode'] ?? 1) == 1;

  factory RmuStatus.fromJson(Map<String, dynamic> json) {
    final sensors = json['sensors'] as Map<String, dynamic>;
    final power = json['power'] as Map<String, dynamic>;
    final fans = (json['fans'] as Map<String, dynamic>?) ?? {};
    final parts = (json['part_temps'] as Map<String, dynamic>?) ?? {};
    final control = (json['control'] as Map<String, dynamic>?) ?? {};
    final night = json['night'] as Map<String, dynamic>?;
    final ai = (json['ai'] as Map<String, dynamic>?) ?? {};
    return RmuStatus(
      time: DateTime.parse(json['time'] as String),
      alarmLevel: json['alarm_level'] as int,
      alarmMessage: json['alarm_message'] as String,
      conditions: [
        for (final c in (json['conditions'] as List?) ?? [])
          AlarmCondition.fromJson(c as Map<String, dynamic>),
      ],
      temperature: _num(sensors['temperature']),
      humidity: _num(sensors['humidity']),
      soilMoisture: _num(sensors['soil_moisture']),
      co2: _num(sensors['co2']),
      nutrientEc: _num(sensors['nutrient_ec']),
      sensorErrors: [
        for (final s in (json['sensor_errors'] as List?) ?? []) s as String,
      ],
      powerOk: power['power_ok'] as bool,
      partTemps: {for (final e in parts.entries) e.key: _num(e.value)},
      mainFanOk: (fans['main_ok'] as bool?) ?? true,
      backupFanOk: (fans['backup_ok'] as bool?) ?? true,
      fanFailover: (fans['failover'] as bool?) ?? false,
      control: {for (final e in control.entries) e.key: e.value as num},
      night: night == null ? const NightInfo() : NightInfo.fromJson(night),
      aiActive: (ai['active'] as bool?) ?? false,
      aiReason: (ai['reason'] as String?) ?? '',
    );
  }

  static double? _num(Object? v) => (v as num?)?.toDouble();
}

/// 지금 켜져 있는 알람 조건 하나
class AlarmCondition {
  final String key;
  final int level;
  final String message;

  const AlarmCondition({
    required this.key,
    required this.level,
    required this.message,
  });

  factory AlarmCondition.fromJson(Map<String, dynamic> json) => AlarmCondition(
    key: json['key'] as String,
    level: json['level'] as int,
    message: json['message'] as String,
  );
}

/// 야간 모드 설정과 현재 상태 (시각은 0~1439분)
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

const alarmLevelNames = ['정상', '주의', '경보', '긴급 경보'];

/// 센서·부품·장치 이름 (REST 이름 → 화면 표시)
const displayNames = {
  'temperature': '온도',
  'humidity': '습도',
  'soil_moisture': '토양수분',
  'co2': 'CO2',
  'nutrient_ec': '양분(EC)',
  'rmu_temp': 'RMU(라즈베리파이)',
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
