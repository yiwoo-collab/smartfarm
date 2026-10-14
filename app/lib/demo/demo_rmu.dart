// 앱 안의 데모 게이트웨이(라즈베리파이) v3.0: 서버·네트워크 없이 앱만으로 시나리오를 체험한다.
//
// rmu/rmu_model.py 를 Dart로 옮긴 것이다 (규칙·메시지·JSON 모양이 같다).
// 농장 주소가 "demo:1"처럼 demo: 로 시작하면 RmuApi가 HTTP 대신 여기로 보낸다.
// 규칙을 고칠 때는 rmu_model.py 와 같이 고친다 (test/demo_rmu_test.dart 가 같은 결과인지 확인).
//
// 데모에는 실제 RMU·감지기가 없으므로 실사용(live) 모드도 시뮬레이션 값을 쓴다.
// 대신 AI 동작 방식(자동 실행 / 제안 → 승인)은 실사용 모드 그대로 바뀐다.

import 'dart:async';
import 'dart:math' as math;

// ---------------------------------------------------------------------------
// 기준값 ((제안)은 문서에 없어 임시로 정한 값)
// ---------------------------------------------------------------------------
const _tickSeconds = 1.0;

const _defaultThresholds = <String, double>{
  'temp_low': 15.0, 'temp_high': 30.0, // 15℃ 하한은 RMU에 못 넣으므로 라즈베리파이에서 판정
  'humidity_low': 50.0, 'humidity_high': 85.0,
  'water_level_low': 20.0, // (제안)
  'ac_voltage_low': 200.0, 'ac_voltage_high': 240.0, // (제안)
  'pi_temp_high': 80.0,
  'part_temp_high': 60.0, 'part_temp_low': 0.0, // 환풍기·쿨링팬 장비 (제안)
  'cooling_setpoint': 22.0, 'heating_setpoint': 28.0, // (제안)
  'sensor_mismatch': 3.0, // RMU 온도와 온습도감지기 온도 허용 차이 (제안)
  'soil_low': 35.0, 'co2_high': 1500.0, 'ec_low': 1.0, // 감지기가 연결되면 사용
};

const _hyst = {
  'temp': 2.0,
  'part': 5.0,
  'humidity': 2.0,
  'water': 5.0,
  'ac_voltage': 3.0,
  'soil': 5.0,
  'co2': 300.0,
  'ec': 0.2,
};
const _emergencyMargin = {'temp': 2.0, 'part': 10.0};
const _emergencyMinSeconds = 60; // 경보가 이 시간 이상 계속된 뒤에만 긴급으로 (제안)

const _pumpMaxSeconds = 60;
const _pumpRetrySeconds = 600;
const _motionAlarmSeconds = 30;
const _powerCutVoltage = 50.0;

// AI (제안)
const _aiWindowSeconds = 30;
const _aiMinSamples = 10;
const _aiLeadSeconds = 120;
const _aiMinSlope = 0.002; // ℃/초
const _aiMinHoldSeconds = 60;
const _aiReleaseMargin = 4.0;
const _aiMaxActionsPerHour = 10; // AI 자동 조치 횟수 한도
const _mismatchSeconds = 30;
const _stuckSeconds = 120;
const _leakWindowSeconds = 60;
const _leakRate = -0.15; // %/초

/// AI 허용 목록: AI가 바꿀 수 있는 장치와 위험도. low만 실사용 모드에서 자동 실행.
const _aiAllowList = {'cooling_fan': 'low', 'aircon_setpoint': 'high'};

const _maxEvents = 500;
const _recordSeconds = 10;

const _parts = ['pi_temp', 'main_fan_temp', 'backup_fan_temp', 'cooling_fan_temp'];
const _optional = ['co2', 'soil_moisture', 'nutrient_ec']; // 감지기 없음 → 정보없음
const _rmuItems = [
  'temperature',
  'temp2',
  'ac_voltage',
  'ac_frequency',
  'door_front',
  'ups_battery',
];
const _sensors = [
  'temperature',
  'temp2',
  'humidity',
  'hum_temp',
  'water_level',
  'fire',
  'ac_voltage',
  ..._parts,
  ..._optional,
];

const _names = {
  'temperature': '온도',
  'temp2': '온도2',
  'humidity': '습도',
  'hum_temp': '온습도감지기 온도',
  'water_level': '수위',
  'fire': '화재',
  'ac_voltage': 'AC 전압',
  'ac_frequency': 'AC 주파수',
  'door_front': '전면 도어',
  'ups_battery': 'UPS 배터리',
  'co2': 'CO2',
  'soil_moisture': '토양수분',
  'nutrient_ec': '양분(EC)',
  'pi_temp': '라즈베리파이 온도',
  'main_fan_temp': '메인 환풍기 온도',
  'backup_fan_temp': '예비 환풍기 온도',
  'cooling_fan_temp': '쿨링팬 온도',
  'main_fan': '메인 환풍기',
  'backup_fan': '예비 환풍기',
  'cooling_fan': '쿨링팬',
  'aircon': '에어컨',
  'heater': '히터',
  'pump': '펌프',
  'cover': '덮개',
  'lights': '전구',
};

const _supplyDevices = ['main_fan', 'backup_fan', 'cooling_fan', 'pump'];
const _deviceWatts = {
  'main_fan': 40,
  'backup_fan': 40,
  'cooling_fan': 30,
  'aircon': 1500,
  'heater': 2000,
  'pump': 60,
  'cover': 20,
  'lights': 300,
};
const _baseWatts = 30;

// 긴급 경보 시 정지 (문제를 해결하는 장비는 유지, CLAUDE.md 4장)
const _highEmergencyStop = ['heater', 'lights', 'pump'];
const _lowEmergencyStop = [
  'aircon',
  'cooling_fan',
  'main_fan',
  'backup_fan',
  'lights',
  'pump',
];
const _fireStop = ['heater', 'lights', 'pump'];

const _defaultBase = <String, num>{
  'main_fan': 1,
  'backup_fan': 0,
  'cooling_fan': 0,
  'aircon': 1,
  'aircon_setpoint': 25.0,
  'heater': 0,
  'pump': 0,
  'cover': 0,
  'lights': 1,
  'control_mode': 1,
};
const _defaultSettings = {
  'night_mode': 1,
  'night_start': 21 * 60,
  'night_end': 6 * 60,
};
const _defaultAc = 220.0;

const _demoAdmin = {'username': 'admin', 'password': 'admin1234'};

/// RMU 알람 코드 → (등급, 설명). oids.json 의 alarm_codes 와 같음.
const _rmuCodeText = <int, (int, String)>{
  1: (2, 'AC 전압 이상'),
  9: (0, '온도1 (온도 임계값 규칙으로 재판정)'),
  10: (0, '온도2 (온도 임계값 규칙으로 재판정)'),
  21: (2, '전면 도어 열림'),
  61: (2, 'UPS 배터리 낮음'),
  62: (1, 'UPS 바이패스·강압'),
  80: (1, 'VTES 장애 (의미 미확인)'),
  81: (1, 'CCTV 1 이상'),
  82: (1, 'CCTV 2 이상'),
  83: (1, 'CCTV 3 이상'),
  84: (1, 'CCTV 4 이상'),
  85: (1, 'CCTV 5 이상'),
  98: (1, 'UPS 통신 장애'),
  201: (2, '습도'),
  202: (2, '수위'),
  203: (3, '화재'),
  204: (2, 'CO2'),
  205: (2, '양분'),
  206: (2, '토양수분'),
  207: (1, '라즈베리파이·장비 온도'),
  208: (2, '환풍기 고장'),
  209: (1, '센서 불일치·고장 의심'),
  210: (2, '야간 움직임 감지 (제안: 문서에 없는 코드)'),
};

/// 작물별 임계값 기본값 (rmu/crops.json과 같음)
const _crops = {
  '방울토마토': {
    'temp_low': 15,
    'temp_high': 30,
    'humidity_low': 60,
    'humidity_high': 85,
    'soil_low': 40,
    'cooling_setpoint': 22,
    'heating_setpoint': 25,
  },
  '상추': {
    'temp_low': 12,
    'temp_high': 28,
    'humidity_low': 60,
    'humidity_high': 80,
    'soil_low': 45,
    'cooling_setpoint': 20,
    'heating_setpoint': 21,
  },
  '딸기': {
    'temp_low': 10,
    'temp_high': 28,
    'humidity_low': 60,
    'humidity_high': 80,
    'soil_low': 40,
    'cooling_setpoint': 19,
    'heating_setpoint': 20,
  },
  '파프리카': {
    'temp_low': 18,
    'temp_high': 30,
    'humidity_low': 65,
    'humidity_high': 85,
    'soil_low': 40,
    'cooling_setpoint': 22,
    'heating_setpoint': 27,
  },
  '오이': {
    'temp_low': 18,
    'temp_high': 32,
    'humidity_low': 70,
    'humidity_high': 90,
    'soil_low': 45,
    'cooling_setpoint': 24,
    'heating_setpoint': 27,
  },
};

/// rmu/storage.py 의 HISTORY_SENSORS 와 같음
const _historySensors = [
  'temperature',
  'temp2',
  'humidity',
  'hum_temp',
  'water_level',
  'ac_voltage',
  'greenhouse_power',
  'pi_temp',
  'main_fan_temp',
  'backup_fan_temp',
  'cooling_fan_temp',
  'co2',
  'soil_moisture',
  'nutrient_ec',
  'alarm_level',
];
const _ranges = {
  '1h': 3600,
  '6h': 6 * 3600,
  '24h': 24 * 3600,
  '7d': 7 * 24 * 3600,
};

/// 시뮬레이션 버튼 목록 (rmu_model.py의 SCENARIOS와 같음, scenario = CLAUDE.md 8장 번호)
const demoScenarios = <Map<String, dynamic>>[
  {'name': 'normal', 'label': '전부 정상으로', 'scenario': 1},
  {'name': 'high_temp', 'label': '고온 → 냉방 → 복구', 'scenario': 2},
  {'name': 'high_temp', 'label': '고온 지속 → 긴급', 'scenario': 3, 'params': {'severe': true}},
  {'name': 'low_temp', 'label': '저온 → 난방 → 복구', 'scenario': 4},
  {'name': 'low_temp', 'label': '저온 지속 → 긴급', 'scenario': 5, 'params': {'severe': true}},
  {'name': 'part_high', 'label': '라즈베리파이 온도 높음', 'scenario': 6, 'params': {'part': 'pi_temp'}},
  {
    'name': 'part_high',
    'label': '쿨링팬 온도 높음 → 긴급',
    'scenario': 6,
    'params': {'part': 'cooling_fan_temp', 'severe': true},
  },
  {'name': 'part_low', 'label': '메인 환풍기 온도 낮음', 'scenario': 6, 'params': {'part': 'main_fan_temp'}},
  {'name': 'main_fan_fail', 'label': '메인 환풍기 고장', 'scenario': 7},
  {'name': 'fan_repair', 'label': '환풍기 수리', 'scenario': 7},
  {'name': 'fans_fail', 'label': '환풍기 둘 다 고장', 'scenario': 8},
  {'name': 'water_low', 'label': '수위 부족', 'scenario': 9},
  {'name': 'water_refill', 'label': '물탱크 채우기', 'scenario': 9},
  {'name': 'fire', 'label': '화재 감지', 'scenario': 10},
  {'name': 'fire_clear', 'label': '화재 해제', 'scenario': 10},
  {'name': 'power_abnormal', 'label': 'AC 전압 이상', 'scenario': 11},
  {'name': 'power_cut', 'label': 'AC 전원 차단', 'scenario': 11},
  {'name': 'power_restore', 'label': '전원 정상화', 'scenario': 11},
  {'name': 'comm_loss', 'label': '통신 두절 30초', 'scenario': 13, 'params': {'seconds': 30}},
  {'name': 'comm_restore', 'label': '통신 복구', 'scenario': 13},
  {'name': 'rmu_offline', 'label': 'RMU 통신 두절', 'scenario': 13},
  {'name': 'rmu_online', 'label': 'RMU 통신 복구', 'scenario': 13},
  {'name': 'sensor_fault', 'label': '습도 센서 오류', 'scenario': 14, 'params': {'sensor': 'humidity'}},
  {'name': 'sensor_restore', 'label': '센서 오류 해제', 'scenario': 14},
  {'name': 'night_on', 'label': '야간 모드 진입', 'scenario': 15},
  {'name': 'night_off', 'label': '야간 모드 해제', 'scenario': 15},
  {'name': 'night_auto', 'label': '야간 모드 시각대로', 'scenario': 15},
  {'name': 'motion', 'label': 'CCTV 움직임 감지', 'scenario': 16},
  {'name': 'door_open', 'label': '전면 도어 열림', 'scenario': 16},
  {'name': 'door_close', 'label': '전면 도어 닫힘', 'scenario': 16},
  {'name': 'slow_heat', 'label': '온도 서서히 상승 (AI 선가동)', 'scenario': 25},
  {'name': 'ai_live_demo', 'label': '실사용 AI: 제안·승인 흉내', 'scenario': 26},
  {'name': 'sensor_mismatch', 'label': '센서 불일치 (AI)', 'scenario': 27},
  {'name': 'sensor_match', 'label': '센서 불일치 해제', 'scenario': 27},
  {'name': 'sensor_stuck', 'label': '온도 값 고정 (AI)', 'scenario': 27},
  {'name': 'water_leak', 'label': '누수 의심 (AI)', 'scenario': 27},
  {'name': 'rmu_trap', 'label': 'RMU Trap: UPS 배터리 낮음', 'scenario': 28, 'params': {'code': 61}},
  {'name': 'rmu_trap_clear', 'label': 'RMU Trap: 해제', 'scenario': 28, 'params': {'code': 61}},
  {'name': 'mode_live', 'label': '실사용 모드로', 'scenario': 29},
  {'name': 'mode_demo', 'label': '데모 모드로', 'scenario': 29},
];

// ---------------------------------------------------------------------------
// 도우미
// ---------------------------------------------------------------------------
double _clamp(double v, double low, double high) => math.max(low, math.min(high, v));

String _josa(String word, String withBatchim, String withoutBatchim) {
  final last = word.codeUnitAt(word.length - 1);
  if (last >= 0xAC00 && last <= 0xD7A3 && (last - 0xAC00) % 28 != 0) {
    return word + withBatchim;
  }
  return word + withoutBatchim;
}

bool inNightWindow(int minutes, int start, int end) {
  if (start < end) return start <= minutes && minutes < end;
  return minutes >= start || minutes < end; // 자정을 넘는 구간
}

String _f(num v, int digits) => v.toStringAsFixed(digits);

/// 파이썬 f"{x:+.2f}" 처럼 부호를 붙인다
String _signed(double v, int digits) => (v >= 0 ? '+' : '') + v.toStringAsFixed(digits);

String _iso(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

double _round(double v, int digits) {
  final p = math.pow(10, digits);
  return (v * p).round() / p;
}

double _ts(DateTime t) => t.millisecondsSinceEpoch / 1000;

List<String> _describeChanges(Map<String, num> before, Map<String, num> after) {
  final lines = <String>[];
  for (final key in before.keys) {
    final b = before[key]!, a = after[key]!;
    if (b == a) continue;
    if (key == 'aircon_setpoint') {
      final verb = a < b ? '낮췄습니다' : '높였습니다';
      lines.add('에어컨 설정온도를 ${_f(b, 1)}℃에서 ${_f(a, 1)}℃로 $verb');
    } else if (key == 'cover') {
      lines.add(a != 0 ? '덮개를 닫아 햇빛을 차단했습니다' : '덮개를 열었습니다');
    } else if (key == 'lights') {
      lines.add(a != 0 ? '전구를 모두 켰습니다' : '전구를 모두 소등했습니다');
    } else if (key == 'control_mode') {
      lines.add(a != 0 ? '제어 모드를 자동으로 바꿨습니다' : '제어 모드를 수동으로 바꿨습니다');
    } else {
      lines.add(_josa(_names[key]!, '을', '를') + (a != 0 ? ' 켰습니다' : ' 껐습니다'));
    }
  }
  return lines;
}

/// [(시각, 값)] 최소제곱 기울기 (값/초). 점이 부족하면 null
double? _slope(List<(double, double)> points) {
  if (points.length < _aiMinSamples) return null;
  final n = points.length;
  final mt = points.fold(0.0, (s, p) => s + p.$1) / n;
  final mv = points.fold(0.0, (s, p) => s + p.$2) / n;
  final den = points.fold(0.0, (s, p) => s + (p.$1 - mt) * (p.$1 - mt));
  if (den == 0) return null;
  return points.fold(0.0, (s, p) => s + (p.$1 - mt) * (p.$2 - mv)) / den;
}

/// 데모 게이트웨이가 돌려주는 오류 (HTTP 상태 코드와 같은 의미)
class DemoRmuError implements Exception {
  final int statusCode;
  final String message;
  DemoRmuError(this.statusCode, this.message);

  @override
  String toString() => message;
}

/// 시뮬레이션으로 주입한 상황 (POST /api/simulate)
class DemoSim {
  double heat = 0;
  Map<String, double> partLoad = {for (final p in _parts) p: 0.0};
  Map<String, bool> fanFailed = {'main': false, 'backup': false};
  bool aiBypass = false;
  double acBase = _defaultAc;
  bool powerCut = false;
  double waterTarget = 80.0;
  bool leak = false;
  bool fire = false;
  bool doorOpen = false;
  double mismatch = 0; // 온습도감지기 온도를 일부러 어긋나게
  bool stuck = false; // 온도 값 고정
  double? commLossUntil;
  Set<String> sensorFaults = {};
  bool? nightOverride;
  double motionUntil = 0;
  bool rmuOffline = false; // RMU 통신 두절 흉내
  Map<String, double> rmuFrozen = {}; // 두절 순간의 RMU 항목 값
  DateTime? rmuOfflineSince;
}

class _Note {
  final int level;
  final String key;
  final String message;
  final List<String> guide;
  final bool ai;
  _Note(this.level, this.key, this.message, this.guide, [this.ai = false]);
}

// ---------------------------------------------------------------------------
// 데모 게이트웨이
// ---------------------------------------------------------------------------
class DemoRmu {
  static final Map<String, DemoRmu> _instances = {};

  /// 주소("demo:1")마다 하나씩. 처음 부를 때 만들어 1초마다 돌린다.
  static DemoRmu forAddress(String address) =>
      _instances.putIfAbsent(address, () => DemoRmu()..start());

  static bool isDemoUrl(String baseUrl) => baseUrl.startsWith('http://demo:');

  final _rand = math.Random();
  Timer? _timer;

  String mode = 'demo';
  final Set<String> unavailable = {..._optional};

  final Map<String, double> values = {
    'temperature': 25.0,
    'temp2': 24.0,
    'humidity': 72.0,
    'hum_temp': 25.0,
    'water_level': 80.0,
    'fire': 0.0,
    'ac_voltage': _defaultAc,
    'ac_frequency': 60.0,
    'door_front': 0.0,
    'ups_battery': 100.0,
    'pi_temp': 48.0,
    'main_fan_temp': 35.0,
    'backup_fan_temp': 28.0,
    'cooling_fan_temp': 28.0,
    'co2': 450.0,
    'soil_moisture': 45.0,
    'nutrient_ec': 1.8,
  };
  Map<int, double> rmuAlarms = {}; // RMU가 알린 알람 코드 → 받은 시각

  Map<String, num> base = Map.of(_defaultBase);
  Map<String, num>? savedBase;
  Map<String, num> manualStart = {};
  Map<String, num> control = Map.of(_defaultBase);
  Map<String, double> thresholds = Map.of(_defaultThresholds);
  Map<String, int> settings = Map.of(_defaultSettings);
  DemoSim sim = DemoSim();

  String tempState = 'normal';
  Map<String, String> partStates = {for (final p in _parts) p: 'normal'};
  final Map<String, double> _stateSince = {}; // 온도·부품 경보가 시작된 시각 (긴급 판정용)
  Map<String, Map<String, dynamic>> active = {};
  bool nightActive = false;
  bool failoverLatched = false;
  double? pumpStartedAt;
  double pumpRetryAt = 0;
  double energyWh = 0;
  final List<Map<String, dynamic>> events = [];
  int nextEventId = 1;
  final List<_Note> _notes = [];

  // AI
  List<(double, double)> _tempSamples = [];
  List<(double, double)> _waterSamples = [];
  double? _mismatchSince;
  double? _stuckSince;
  double? _stuckValue;
  bool aiActive = false; // 미리 냉방 전체 (데모: 자동, 실사용: 승인 후)
  bool aiFan = false; // 위험 낮은 조치만 (실사용: 쿨링팬)
  double aiStarted = 0;
  List<double> _aiActionTimes = [];
  final List<Map<String, dynamic>> suggestions = [];
  int nextSuggestionId = 1;
  Map<String, dynamic> ai = {
    'active': false,
    'reason': '데이터 수집 중',
    'slope_per_min': null,
    'eta_seconds': null,
  };

  // 기록 (2단계 SQLite 대신 메모리)
  final List<(DateTime, Map<String, double?>)> _readings = [];
  DateTime? _lastRecord;

  final Set<String> _tokens = {};

  void start() {
    tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void stop() => _timer?.cancel();

  double _rnd(double a, double b) => a + _rand.nextDouble() * (b - a);

  // =========================================================================
  // 1초마다
  // =========================================================================
  void tick([DateTime? now]) {
    now ??= DateTime.now();
    _updatePhysics();
    _updateAi(_ts(now));
    _evaluate(now);
    _maybeRecord(now);
  }

  /// ok / nodata / fault / offline (CLAUDE.md 3장 정보없음 규칙)
  String itemState(String name) {
    if (unavailable.contains(name)) return 'nodata';
    if (sim.sensorFaults.contains(name)) return 'fault';
    if (_rmuItems.contains(name) && sim.rmuOffline) return 'offline';
    return 'ok';
  }

  /// 알람·AI 판단에 쓸 수 있는 값인가 (정보없음·오류·두절은 제외)
  bool usable(String name) => itemState(name) == 'ok';

  Set<String> sensorFaults() => sim.sensorFaults;

  bool fanFailed(String which) => sim.fanFailed[which]!;

  bool running(String device) {
    if (control[device] == 0) return false;
    if (_supplyDevices.contains(device) && powerDown()) return false;
    if (device == 'main_fan' && fanFailed('main')) return false;
    if (device == 'backup_fan' && fanFailed('backup')) return false;
    return true;
  }

  bool powerDown() =>
      sim.powerCut || (usable('ac_voltage') && values['ac_voltage']! < _powerCutVoltage);

  // ----- 시뮬레이션 세계 ----------------------------------------------------
  void _updatePhysics() {
    final v = values, c = control, s = sim;
    if (!s.stuck) {
      var dt = s.heat + _rnd(-0.05, 0.05);
      if (running('aircon')) dt += 0.03 * (c['aircon_setpoint']! - v['temperature']!);
      if (running('cooling_fan')) dt -= 0.2;
      if (running('heater')) dt += 0.4;
      if (running('backup_fan')) dt -= 0.05;
      v['temperature'] = _clamp(v['temperature']! + dt, -20, 60);
    }
    v['temp2'] = _clamp(
      v['temp2']! + 0.1 * (v['temperature']! - 1.0 - v['temp2']!) + _rnd(-0.05, 0.05),
      -20,
      60,
    );
    // 온습도감지기 온도: 같은 온실이라 RMU 온도와 거의 같다 (불일치 시나리오면 어긋남)
    v['hum_temp'] = v['temperature']! + s.mismatch + _rnd(-0.2, 0.2);

    for (final p in _parts) {
      final base = p == 'pi_temp'
          ? 48.0
          : (running(p.replaceAll('_temp', '')) ? 35.0 : 28.0);
      final t = v[p]!;
      var d = s.partLoad[p]! - 0.05 * (t - base) + _rnd(-0.1, 0.1);
      if (running('cooling_fan') && t > base) d -= 1.5;
      if (running('heater') && t < base) d += 2.0;
      v[p] = _clamp(t + d, -60, 150);
    }

    v['humidity'] = _clamp(v['humidity']! + 0.1 * (72 - v['humidity']!) + _rnd(-0.5, 0.5), 0, 100);

    // 수위(물탱크): 목표 수위 쪽으로 천천히, 펌프를 쓰면 줄고, 누수면 빨리 준다
    var dw = s.leak
        ? -0.4 + _rnd(-0.05, 0.05)
        : 0.02 * (s.waterTarget - v['water_level']!) + _rnd(-0.05, 0.05);
    if (running('pump')) dw -= 0.2;
    v['water_level'] = _clamp(v['water_level']! + dw, 0, 100);
    v['fire'] = s.fire ? 1.0 : 0.0;
    v['door_front'] = s.doorOpen ? 1.0 : 0.0;

    if (s.powerCut) {
      v['ac_voltage'] = 0.0;
      v['ac_frequency'] = 0.0;
    } else {
      v['ac_voltage'] = v['ac_voltage']! + 0.3 * (s.acBase - v['ac_voltage']!) + _rnd(-0.3, 0.3);
      v['ac_frequency'] = 60.0 + _rnd(-0.05, 0.05);
    }

    // 정보없음 항목도 내부에서는 흉내 값을 돌린다 (감지기가 연결되면 쓰기 위해)
    v['co2'] = _clamp(v['co2']! + 0.02 * (450 - v['co2']!) + _rnd(-5, 5), 300, 5000);
    v['soil_moisture'] = _clamp(
      v['soil_moisture']! +
          0.002 * (45 - v['soil_moisture']!) +
          (running('pump') ? 0.5 : 0) +
          _rnd(-0.1, 0.1),
      0,
      100,
    );
    v['nutrient_ec'] = _clamp(
      v['nutrient_ec']! + 0.1 * (1.8 - v['nutrient_ec']!) + _rnd(-0.02, 0.02),
      0,
      5,
    );

    energyWh += greenhousePower() * _tickSeconds / 3600;
  }

  int greenhousePower() =>
      _baseWatts +
      _deviceWatts.entries.where((e) => running(e.key)).fold(0, (s, e) => s + e.value);

  // =========================================================================
  // AI 판단 (CLAUDE.md 7장 AI 판단)
  // =========================================================================
  bool _aiBudgetOk(double ts) {
    _aiActionTimes = [for (final t in _aiActionTimes) if (ts - t < 3600) t];
    return _aiActionTimes.length < _aiMaxActionsPerHour;
  }

  void _addSuggestion(double ts, String kind, String title, String reason, Map<String, dynamic> action) {
    if (suggestions.any((s) => s['kind'] == kind && s['status'] == 'pending')) return;
    suggestions.add({
      'id': nextSuggestionId,
      'kind': kind,
      'title': title,
      'reason': reason,
      'action': action,
      'risk': _aiAllowList[action['device']] ?? 'high',
      'status': 'pending',
      'time': _iso(DateTime.fromMillisecondsSinceEpoch((ts * 1000).round())),
    });
    nextSuggestionId++;
    if (suggestions.length > 50) suggestions.removeRange(0, suggestions.length - 50);
    _notes.add(_Note(1, 'ai_suggest', 'AI 제안: $title', ['판단 이유: $reason', '승인하면 실행합니다'], true));
  }

  void _expireSuggestions(String kind) {
    for (final s in suggestions) {
      if (s['kind'] == kind && s['status'] == 'pending') s['status'] = 'expired';
    }
  }

  int _pendingCount() => suggestions.where((s) => s['status'] == 'pending').length;

  void _updateAi(double ts) {
    final th = thresholds;
    final temp = values['temperature']!;
    final high = th['temp_high']!;
    final auto = base['control_mode'] == 1;

    // --- 1) 온도 상승 속도로 선가동 ---
    final tempOk = usable('temperature');
    if (tempOk) _tempSamples.add((ts, temp));
    _tempSamples = [for (final p in _tempSamples) if (ts - p.$1 <= _aiWindowSeconds) p];
    // 창(30초)이 다 찰 때까지는 판단하지 않는다: 시작 직후 몇 개 값의 흔들림을 상승으로 오판하지 않게
    final full = _tempSamples.isNotEmpty && ts - _tempSamples.first.$1 >= _aiWindowSeconds * 0.9;
    final sl = tempOk && full ? _slope(_tempSamples) : null;
    final eta = (sl != null && sl > 0 && temp < high) ? (high - temp) / sl : null;
    final String reason;
    if (!tempOk) {
      reason = '온도 값을 쓸 수 없어 판단하지 않습니다 (${itemState('temperature')})';
    } else if (sl == null) {
      reason = '데이터 수집 중';
    } else if (eta != null) {
      reason =
          '최근 $_aiWindowSeconds초 상승 속도 ${_f(sl * 60, 2)}℃/분, '
          '이대로면 약 ${_f(eta / 60, 1)}분 뒤 상한 ${_f(high, 1)}℃ 도달';
    } else {
      reason = '온도 변화 ${_signed(sl * 60, 2)}℃/분, 상한 도달 예상 없음';
    }

    final heating = [tempState, ...partStates.values].any((st) => st == 'low' || st == 'low_emergency');
    final usableNow = auto && tempOk && !heating && !sim.aiBypass && tempState == 'normal';
    final rising = usableNow && eta != null && eta <= _aiLeadSeconds && sl! >= _aiMinSlope;
    final engaged = aiActive || aiFan;
    if (!engaged && rising) {
      if (mode == 'demo') {
        if (_aiBudgetOk(ts)) {
          aiActive = true;
          aiStarted = ts;
          _aiActionTimes.add(ts);
          _notes.add(_Note(0, 'ai', 'AI 선가동: 상한 도달 전에 냉방을 시작합니다', ['판단 이유: $reason'], true));
        }
      } else {
        // 실사용: 위험 낮은 쿨링팬만 자동, 에어컨 설정온도 변경은 제안
        if (_aiBudgetOk(ts)) {
          aiFan = true;
          aiStarted = ts;
          _aiActionTimes.add(ts);
          _notes.add(_Note(0, 'ai', 'AI 선가동: 쿨링팬을 미리 켭니다 (위험 낮은 조치는 자동)', ['판단 이유: $reason'], true));
        }
        _addSuggestion(
          ts,
          'precool',
          '에어컨 설정온도를 ${_f(th['cooling_setpoint']!, 0)}℃로 낮춰 미리 냉방',
          reason,
          {'device': 'aircon_setpoint', 'value': th['cooling_setpoint']},
        );
      }
    } else if (engaged && !usableNow) {
      aiActive = aiFan = false;
      _expireSuggestions('precool');
    } else if (engaged &&
        ts - aiStarted >= _aiMinHoldSeconds &&
        temp <= high - _aiReleaseMargin &&
        sl != null &&
        sl <= 0) {
      aiActive = aiFan = false;
      sim.heat = 0.0;
      _expireSuggestions('precool');
      _notes.add(_Note(0, 'ai', 'AI 선가동 종료: 온도가 안정되었습니다', ['판단 이유: $reason'], true));
    }

    ai = {
      'active': aiActive || aiFan,
      'reason': reason,
      'mode': mode,
      'slope_per_min': sl == null ? null : _round(sl * 60, 2),
      'eta_seconds': eta?.round(),
      'pending': _pendingCount(),
    };

    // --- 2) 센서 불일치: RMU 온도 vs 온습도감지기 온도 ---
    if (usable('temperature') &&
        usable('hum_temp') &&
        (temp - values['hum_temp']!).abs() > th['sensor_mismatch']!) {
      _mismatchSince ??= ts;
    } else {
      _mismatchSince = null;
    }

    // --- 3) 값 고정: 온도가 오래 똑같으면 센서 고장 의심 ---
    if (tempOk && _stuckValue != null && (temp - _stuckValue!).abs() < 1e-6) {
      _stuckSince ??= ts;
    } else {
      _stuckSince = null;
    }
    _stuckValue = tempOk ? temp : null;

    // --- 4) 수위 하락 속도: 펌프가 꺼져 있는데 빨리 줄면 누수 의심 ---
    if (usable('water_level')) _waterSamples.add((ts, values['water_level']!));
    _waterSamples = [for (final p in _waterSamples) if (ts - p.$1 <= _leakWindowSeconds) p];
  }

  // =========================================================================
  // 판정 → 출력 → 이벤트
  // =========================================================================
  void _evaluate(DateTime now, [String? defaultMessage]) {
    final ts = _ts(now);
    _updateTempStates(ts);
    _updateNight(now);
    final cond = _evaluateConditions(ts);
    _updatePump(ts, cond);
    _updateFailover();
    final before = Map.of(control);
    control = _computeOutputs(cond);
    _recordEvents(now, cond, _describeChanges(before, control), defaultMessage);
  }

  static String _nextState(
    String state,
    double value,
    double low,
    double high,
    double hyst,
    double margin,
    bool auto,
  ) {
    if (state == 'normal') {
      if (value > high) return 'high';
      if (value < low) return 'low';
    } else if (state == 'high' || state == 'high_emergency') {
      if (value <= high - hyst) return 'normal';
      if (state == 'high' && auto && value > high + margin) return 'high_emergency';
    } else if (state == 'low' || state == 'low_emergency') {
      if (value >= low + hyst) return 'normal';
      if (state == 'low' && auto && value < low - margin) return 'low_emergency';
    }
    return state;
  }

  /// 경보 → 긴급은 경보가 _emergencyMinSeconds 이상 계속됐을 때만 (냉방·난방이 효과를 낼 시간).
  /// RMU 값이 갑자기 뛰어도 1초 만에 긴급으로 가지 않게 한다.
  String _holdEmergency(String key, String old, String next, double ts) {
    if (next == 'normal') {
      _stateSince.remove(key);
      return next;
    }
    if (old == 'normal') _stateSince[key] = ts;
    if (next.endsWith('_emergency') &&
        !old.endsWith('_emergency') &&
        ts - (_stateSince[key] ?? ts) < _emergencyMinSeconds) {
      return old;
    }
    return next;
  }

  void _updateTempStates(double ts) {
    final th = thresholds, auto = base['control_mode'] == 1, s = sim;
    if (usable('temperature')) {
      var next = _nextState(
        tempState,
        values['temperature']!,
        th['temp_low']!,
        th['temp_high']!,
        _hyst['temp']!,
        _emergencyMargin['temp']!,
        auto,
      );
      next = _holdEmergency('temp', tempState, next, ts);
      if (next == 'normal' && tempState != 'normal') {
        s.heat = 0.0;
        s.aiBypass = false;
        _tempSamples = []; // 경보 전후 값으로 AI가 상승을 오판하지 않게 새로 모은다
      }
      tempState = next;
    }
    for (final p in _parts) {
      if (!usable(p)) continue;
      final high = p == 'pi_temp' ? th['pi_temp_high']! : th['part_temp_high']!;
      var next = _nextState(
        partStates[p]!,
        values[p]!,
        th['part_temp_low']!,
        high,
        _hyst['part']!,
        _emergencyMargin['part']!,
        auto,
      );
      next = _holdEmergency(p, partStates[p]!, next, ts);
      if (next == 'normal' && partStates[p] != 'normal') s.partLoad[p] = 0.0;
      partStates[p] = next;
    }
  }

  void _updateNight(DateTime now) {
    final bool night;
    if (sim.nightOverride != null) {
      night = sim.nightOverride!;
    } else if (settings['night_mode'] == 1) {
      night = inNightWindow(now.hour * 60 + now.minute, settings['night_start']!, settings['night_end']!);
    } else {
      night = false;
    }
    if (night != nightActive) {
      _notes.add(_Note(0, 'night', night ? '야간 모드 진입' : '야간 모드 해제', []));
    }
    nightActive = night;
  }

  Map<String, Map<String, dynamic>> _evaluateConditions(double ts) {
    final v = values, th = thresholds, s = sim;
    final auto = base['control_mode'] == 1;
    final prev = active;
    final cond = <String, Map<String, dynamic>>{};

    void add(String key, int level, int code, String message, [List<String>? guide, bool ai = false]) {
      cond[key] = {
        'key': key,
        'level': level,
        'code': code,
        'message': message,
        'guide': <String>[...?guide],
        'ai': ai,
      };
    }

    // 히스테리시스: 이미 켜진 경보는 stay 조건으로 유지
    bool hyst(String key, bool enter, bool stay) => prev.containsKey(key) ? stay : enter;

    // 온실 온도 (RMU temp1, 코드 9를 우리 임계값으로 재판정)
    final t = v['temperature']!;
    final st = tempState;
    if (st == 'high') {
      add('temp', 2, 9, '온실 온도 상한 초과 (현재 ${_f(t, 1)}℃, 상한 ${_f(th['temp_high']!, 1)}℃)');
    } else if (st == 'high_emergency') {
      add('temp', 3, 9, '긴급: 냉방 후에도 온도 상승 (${_f(t, 1)}℃)');
    } else if (st == 'low') {
      add('temp', 2, 9, '온실 온도 하한 미만 (현재 ${_f(t, 1)}℃, 하한 ${_f(th['temp_low']!, 1)}℃)');
    } else if (st == 'low_emergency') {
      add('temp', 3, 9, '긴급: 난방 후에도 온도 하락 (${_f(t, 1)}℃)');
    }
    if (st != 'normal' && nightActive) {
      (cond['temp']!['guide'] as List<String>).add('야간이지만 온도 경보를 우선합니다. 환기를 먼저 가동하고 전구는 소등을 유지합니다');
    }

    // 부품 온도 (207)
    for (final p in _parts) {
      final ps = partStates[p], pv = v[p]!;
      if (ps == 'high') {
        add('part:$p', 1, 207, '${_names[p]} 기준 초과 (${_f(pv, 1)}℃)');
      } else if (ps == 'high_emergency') {
        add('part:$p', 3, 207, '긴급: 냉각 후에도 ${_names[p]} 상승 (${_f(pv, 1)}℃)');
      } else if (ps == 'low') {
        add('part:$p', 1, 207, '${_names[p]} 기준 미만 (${_f(pv, 1)}℃)');
      } else if (ps == 'low_emergency') {
        add('part:$p', 3, 207, '긴급: 난방 후에도 ${_names[p]} 하락 (${_f(pv, 1)}℃)');
      }
    }

    // 습도 (201)
    final h = v['humidity']!;
    if (usable('humidity')) {
      if (hyst('humidity_high', h > th['humidity_high']!, h > th['humidity_high']! - _hyst['humidity']!)) {
        add('humidity_high', 2, 201, '습도 상한 초과 (${_f(h, 1)}%)', ['환기를 확인하세요']);
      }
      if (hyst('humidity_low', h < th['humidity_low']!, h < th['humidity_low']! + _hyst['humidity']!)) {
        add('humidity_low', 2, 201, '습도 하한 미만 (${_f(h, 1)}%)');
      }
    }

    // 수위 (202): 부족하면 펌프 제한
    final w = v['water_level']!;
    if (usable('water_level') &&
        hyst('water_low', w < th['water_level_low']!, w < th['water_level_low']! + _hyst['water']!)) {
      add('water_low', 2, 202, '수위 부족 (현재 ${_f(w, 0)}%, 하한 ${_f(th['water_level_low']!, 0)}%)', [
        '물이 부족해 펌프 사용을 제한합니다. 물탱크를 채우세요',
      ]);
    }

    // 누수 의심 (AI, 202 주의): 펌프가 꺼져 있는데 수위가 빨리 줄어든다
    final ws = _slope(_waterSamples);
    if (usable('water_level') &&
        ws != null &&
        !running('pump') &&
        hyst('leak', ws < _leakRate, ws < _leakRate / 2)) {
      add(
        'leak',
        1,
        202,
        '누수 의심: 수위가 분당 ${_f(ws.abs() * 60, 1)}%씩 줄고 있습니다',
        ['판단 이유: 최근 $_leakWindowSeconds초 수위 하락 속도 ${_f(ws * 60, 1)}%/분 (펌프 꺼짐)', '배관과 물탱크를 확인하세요'],
        true,
      );
    }

    // 화재 (203, 긴급)
    if (usable('fire') && v['fire']! >= 1) {
      add('fire', 3, 203, '긴급: 화재 감지', ['열원과 전기 장비(히터·전구·펌프)를 정지했습니다', '오감지일 수 있으니 현장을 확인하세요']);
    }

    // 감지기가 연결된 경우에만 (기본은 정보없음이라 판정 제외)
    if (usable('co2') && hyst('co2', v['co2']! > th['co2_high']!, v['co2']! > th['co2_high']! - _hyst['co2']!)) {
      add('co2', 2, 204, 'CO2 농도 높음 (${_f(v['co2']!, 0)}ppm)');
    }
    if (usable('nutrient_ec') &&
        hyst('nutrient', v['nutrient_ec']! < th['ec_low']!, v['nutrient_ec']! < th['ec_low']! + _hyst['ec']!)) {
      add('nutrient', 2, 205, '양분 부족 (EC ${_f(v['nutrient_ec']!, 2)}mS/cm)', ['양액을 보충하세요']);
    }
    if (usable('soil_moisture') &&
        hyst('soil_dry', v['soil_moisture']! < th['soil_low']!, v['soil_moisture']! < th['soil_low']! + _hyst['soil']!)) {
      add('soil_dry', 2, 206, '토양 건조 (${_f(v['soil_moisture']!, 0)}%)');
    }

    // AC 전원 (RMU acv1, 코드 1)
    final ac = v['ac_voltage']!;
    final low = th['ac_voltage_low']!, highV = th['ac_voltage_high']!, hv = _hyst['ac_voltage']!;
    if (powerDown()) {
      add('power', 2, 1, 'AC 전원 차단', ['환풍기·쿨링팬·펌프가 멈춘 상태입니다. 전원을 확인하세요']);
    } else if (usable('ac_voltage') &&
        hyst('power', !(low <= ac && ac <= highV), !(low + hv <= ac && ac <= highV - hv))) {
      add('power', 2, 1, 'AC 전압 이상 (${_f(ac, 1)}V)', ['전압이 정상이 될 때까지 펌프 사용을 제한합니다']);
    }

    // 전면 도어 (RMU doorFront, 코드 21)
    final motion = nightActive && ts < s.motionUntil;
    if (usable('door_front') && v['door_front']! >= 1) {
      add('door', 2, 21, motion ? '야간 전면 도어 열림 + CCTV 움직임 (침입 의심)' : '전면 도어 열림', ['현장을 확인하세요']);
    } else if (motion) {
      add('intrusion', 2, 210, '야간 CCTV 움직임 감지', ['CCTV를 확인하세요']);
    }

    // 환풍기 이중화 (208)
    final mainBad = fanFailed('main'), backupBad = fanFailed('backup');
    if (mainBad && backupBad) {
      add('fan', 3, 208, '긴급: 메인·예비 환풍기 모두 고장 (대체 수단 없음)', ['환풍기를 즉시 점검하세요']);
    } else if (mainBad) {
      if (auto) {
        add('fan', 2, 208, '메인 환풍기 고장, 예비 환풍기로 대체');
      } else {
        add('fan', 2, 208, '메인 환풍기 고장', ['수동 모드입니다. 예비 환풍기를 직접 켜세요']);
      }
    } else if (backupBad) {
      add('fan_backup', 1, 208, '예비 환풍기 고장 (메인은 정상)');
    }

    // 센서 불일치·값 고정 (AI, 209 주의)
    if (_mismatchSince != null && ts - _mismatchSince! >= _mismatchSeconds) {
      final diff = v['temperature']! - v['hum_temp']!;
      add(
        'mismatch',
        1,
        209,
        '센서 불일치 의심: RMU 온도와 온습도감지기 온도 차이 ${_f(diff.abs(), 1)}℃',
        [
          '판단 이유: $_mismatchSeconds초 넘게 차이가 ${_f(th['sensor_mismatch']!, 1)}℃보다 큽니다 '
              '(RMU ${_f(v['temperature']!, 1)}℃, 온습도감지기 ${_f(v['hum_temp']!, 1)}℃)',
          '두 감지기 위치와 배선을 확인하세요',
        ],
        true,
      );
    }
    if (_stuckSince != null && ts - _stuckSince! >= _stuckSeconds) {
      add(
        'stuck',
        1,
        209,
        '센서 고장 의심: 온도가 ${_stuckSeconds ~/ 60}분 넘게 ${_f(v['temperature']!, 1)}℃로 고정',
        ['판단 이유: $_stuckSeconds초 동안 값이 전혀 변하지 않았습니다', '온도감지기를 확인하세요'],
        true,
      );
    }

    // RMU가 알려 준 그 밖의 알람 코드 (Trap 또는 alarm 스칼라)
    for (final code in rmuAlarms.keys.toList()..sort()) {
      if (const [1, 9, 10, 21].contains(code)) continue; // 값으로 직접 판정하는 항목
      final info = _rmuCodeText[code];
      if (info != null) {
        add('rmu:$code', info.$1, code, '${info.$2} (RMU 알람 $code)', ['RMU 장비를 확인하세요']);
      }
    }
    return cond;
  }

  /// 토양수분 감지기가 연결된 경우에만 자동 급수 (기본은 정보없음이라 동작 안 함)
  void _updatePump(double ts, Map<String, Map<String, dynamic>> cond) {
    final auto = base['control_mode'] == 1;
    final dry = cond.containsKey('soil_dry') && !cond.containsKey('water_low');
    if (pumpStartedAt == null) {
      if (auto && dry && ts >= pumpRetryAt) pumpStartedAt = ts;
    } else if (!auto || !dry) {
      pumpStartedAt = null;
    } else if (ts - pumpStartedAt! >= _pumpMaxSeconds) {
      pumpStartedAt = null;
      pumpRetryAt = ts + _pumpRetrySeconds;
      _notes.add(_Note(2, 'pump', '펌프 최대 $_pumpMaxSeconds초 동작 후 정지', []));
    }
  }

  void _updateFailover() {
    if (base['control_mode'] == 1 && fanFailed('main') && base['main_fan'] != 0) {
      failoverLatched = true;
    }
  }

  Map<String, num> _computeOutputs(Map<String, Map<String, dynamic>> cond) {
    final c = Map.of(base);
    if (nightActive) {
      c['cover'] = 1;
      c['lights'] = 0;
    }
    if (c['control_mode'] != 1) return c;

    final parts = partStates.values.toList();
    final cooling = aiActive ||
        tempState == 'high' ||
        tempState == 'high_emergency' ||
        parts.any((p) => p == 'high' || p == 'high_emergency');
    final heating = tempState == 'low' ||
        tempState == 'low_emergency' ||
        parts.any((p) => p == 'low' || p == 'low_emergency');
    if (cooling) {
      c['aircon'] = 1;
      c['aircon_setpoint'] = math.min(c['aircon_setpoint']!.toDouble(), thresholds['cooling_setpoint']!);
      c['cooling_fan'] = 1;
    } else if (heating) {
      c['heater'] = 1;
      if (c['aircon'] != 0) {
        c['aircon_setpoint'] = math.max(c['aircon_setpoint']!.toDouble(), thresholds['heating_setpoint']!);
      }
    }
    if (aiFan) c['cooling_fan'] = 1; // 실사용 모드 AI: 위험 낮은 조치(허용 목록)
    if (cond.containsKey('co2') || (nightActive && tempState != 'normal')) c['backup_fan'] = 1;
    if (failoverLatched) {
      c['main_fan'] = 0;
      c['backup_fan'] = 1;
    }
    if (pumpStartedAt != null) c['pump'] = 1;

    final states = [tempState, ...parts];
    if (states.contains('high_emergency')) {
      for (final d in _highEmergencyStop) {
        c[d] = 0;
      }
    } else if (states.contains('low_emergency')) {
      for (final d in _lowEmergencyStop) {
        c[d] = 0;
      }
    }
    if (cond.containsKey('fire')) {
      for (final d in _fireStop) {
        c[d] = 0;
      }
    }
    if (cond.containsKey('water_low') || cond.containsKey('power')) c['pump'] = 0;
    return c;
  }

  String _clearMessage(String key) {
    final v = values;
    if (key == 'temp') return '온실 온도 정상 복귀 (${_f(v['temperature']!, 1)}℃)';
    if (key.startsWith('part:')) {
      final p = key.substring(5);
      return '${_names[p]} 정상 복귀 (${_f(v[p]!, 1)}℃)';
    }
    if (key.startsWith('rmu:')) return 'RMU 알람 ${key.substring(4)} 해제';
    return {
          'humidity_high': '습도 정상 복귀',
          'humidity_low': '습도 정상 복귀',
          'water_low': '수위 정상 복귀 (${_f(v['water_level']!, 0)}%)',
          'leak': '수위 하락 멈춤 (누수 의심 해소)',
          'fire': '화재 감지 해제',
          'power': 'AC 전원 정상 복귀',
          'door': '전면 도어 닫힘',
          'intrusion': '야간 움직임 경보 해소',
          'fan': '환풍기 경보 해소',
          'fan_backup': '예비 환풍기 정상',
          'mismatch': '센서 불일치 해소',
          'stuck': '온도 값이 다시 변합니다 (고장 의심 해소)',
          'co2': 'CO2 정상 복귀',
          'nutrient': '양분 정상 복귀',
          'soil_dry': '토양수분 정상 복귀',
        }[key] ??
        '$key 해소';
  }

  void _addEvent(
    DateTime now,
    int level,
    String type,
    String key,
    int? code,
    String message,
    List<String> actions,
    bool ai,
  ) {
    events.add({
      'id': nextEventId++,
      'time': _iso(now),
      'level': level,
      'type': type,
      'key': key,
      'code': code,
      'trap': (type == 'alarm' || type == 'clear') ? 'farmAlarm' : null,
      'message': message,
      'actions': actions,
      'ai': ai,
    });
    if (events.length > _maxEvents) events.removeRange(0, events.length - _maxEvents);
  }

  void _recordEvents(
    DateTime now,
    Map<String, Map<String, dynamic>> cond,
    List<String> changes,
    String? defaultMessage,
  ) {
    final auto = base['control_mode'] == 1;
    // (등급, 종류, 키, 코드, 메시지, 안내, AI)
    final newEvents = <(int, String, String, int?, String, List<String>, bool)>[];
    for (final e in cond.entries) {
      final old = active[e.key];
      if (old == null || old['level'] != e.value['level']) {
        newEvents.add((
          e.value['level'] as int,
          'alarm',
          e.key,
          e.value['code'] as int,
          e.value['message'] as String,
          List<String>.of(e.value['guide'] as List<String>),
          e.value['ai'] as bool,
        ));
      }
    }
    for (final e in active.entries) {
      if (!cond.containsKey(e.key)) {
        final code = e.value['code'] as int;
        // 해제 코드 = 코드 + 100
        newEvents.add((0, 'clear', e.key, code != 0 ? code + 100 : null, _clearMessage(e.key), [], e.value['ai'] as bool));
      }
    }
    for (final n in _notes) {
      newEvents.add((n.level, 'info', n.key, null, n.message, List.of(n.guide), n.ai));
    }
    _notes.clear();
    if (newEvents.isEmpty && changes.isNotEmpty) {
      newEvents.add((
        0,
        defaultMessage != null ? 'control' : 'action',
        'control',
        null,
        defaultMessage ?? '자동 조치',
        [],
        false,
      ));
    }
    // 긴급 경보가 맨 앞: 알림을 먼저 보내고, 장치 정리 내역은 그 알림 상세에 남긴다 (같은 등급은 원래 순서)
    final ordered = [for (var i = 0; i < newEvents.length; i++) (i, newEvents[i])]
      ..sort((a, b) => b.$2.$1 != a.$2.$1 ? b.$2.$1.compareTo(a.$2.$1) : a.$1.compareTo(b.$1));
    for (var i = 0; i < ordered.length; i++) {
      final (level, type, key, code, message, guide, isAi) = ordered[i].$2;
      final actions = <String>[];
      if (i == 0) {
        actions.addAll(changes);
        if (type == 'alarm' && level >= 2 && !auto && changes.isEmpty) {
          actions.add('수동 모드라 자동 조치를 하지 않았습니다');
        }
      }
      _addEvent(now, level, type, key, code, message, [...actions, ...guide], isAi);
    }
    active = cond;
  }

  // =========================================================================
  // 기록 (/api/history)
  // =========================================================================
  Map<String, double?> historyValues() => {
    for (final e in values.entries) e.key: usable(e.key) ? _round(e.value, 2) : null,
    'greenhouse_power': greenhousePower().toDouble(),
    'alarm_level': alarmLevel().toDouble(),
  };

  void _maybeRecord(DateTime now) {
    if (_lastRecord != null && now.difference(_lastRecord!).inSeconds < _recordSeconds) return;
    _lastRecord = now;
    _readings.add((now, historyValues()));
    final cutoff = now.subtract(const Duration(days: 7));
    _readings.removeWhere((r) => r.$1.isBefore(cutoff));
  }

  List<Map<String, dynamic>> history(String sensor, String range) {
    if (!_historySensors.contains(sensor)) {
      throw DemoRmuError(400, 'sensor는 $_historySensors 중 하나입니다');
    }
    final span = _ranges[range];
    if (span == null) {
      throw DemoRmuError(400, 'range는 ${_ranges.keys.toList()} 중 하나입니다');
    }
    final now = DateTime.now();
    final start = now.subtract(Duration(seconds: span));
    final bucket = math.max(_recordSeconds, span ~/ 120);
    final points = <Map<String, dynamic>>[];
    int? current;
    var vals = <double>[];
    void flush() {
      final t = start.add(Duration(milliseconds: ((current! * bucket + bucket / 2) * 1000).round()));
      points.add({'time': _iso(t), 'value': _round(vals.reduce((a, b) => a + b) / vals.length, 2)});
    }

    for (final (t, row) in _readings) {
      if (t.isBefore(start)) continue;
      final index = t.difference(start).inSeconds ~/ bucket;
      if (index != current && vals.isNotEmpty) {
        flush();
        vals = [];
      }
      current = index;
      final v = row[sensor];
      if (v != null) vals.add(v);
    }
    if (vals.isNotEmpty) flush();
    return points;
  }

  // =========================================================================
  // API용
  // =========================================================================
  int alarmLevel() => active.values.fold(0, (m, c) => math.max(m, c['level'] as int));

  bool commLost() {
    final until = sim.commLossUntil;
    if (until == null) return false;
    if (_ts(DateTime.now()) >= until) {
      sim.commLossUntil = null;
      return false;
    }
    return true;
  }

  double? _val(String name, int digits) {
    final state = itemState(name);
    final frozen = sim.rmuFrozen[name];
    if (state == 'offline' && frozen != null) return _round(frozen, digits); // 마지막 수신값
    return (state == 'ok' || state == 'offline') ? _round(values[name]!, digits) : null;
  }

  /// 라즈베리파이 ↔ RMU 연결 상태 (데모는 RMU 실물이 없어 두절 흉내만)
  Map<String, dynamic> _rmuLink() {
    if (!sim.rmuOffline) return {'used': false, 'connected': null, 'last_seen': null};
    final seen = sim.rmuOfflineSince;
    return {'used': true, 'connected': false, 'last_seen': seen == null ? null : _iso(seen)};
  }

  Map<String, dynamic> _powerSummary() {
    final th = thresholds;
    final ac = _val('ac_voltage', 1); // RMU 두절이면 마지막 수신값, 정보없음·오류면 null
    return {
      'ac_voltage': ac,
      'ac_frequency': _val('ac_frequency', 1),
      'power_ok': !powerDown() && ac != null && th['ac_voltage_low']! <= ac && ac <= th['ac_voltage_high']!,
      'ups_battery': _val('ups_battery', 0),
      'greenhouse_power': greenhousePower(),
    };
  }

  Map<String, dynamic> status() {
    final sorted = active.values.toList()..sort((a, b) => (b['level'] as int).compareTo(a['level'] as int));
    final top = sorted.isEmpty ? null : sorted.first;
    final states = {
      for (final n in [
        'temperature',
        'temp2',
        'humidity',
        'hum_temp',
        'water_level',
        'fire',
        'ac_voltage',
        'ac_frequency',
        'door_front',
        'ups_battery',
        ..._parts,
        ..._optional,
      ])
        n: itemState(n),
    };
    final fire = _val('fire', 0);
    final door = _val('door_front', 0);
    return {
      'time': _iso(DateTime.now()),
      'mode': mode,
      'alarm_level': alarmLevel(),
      'alarm_code': top == null ? 0 : top['code'],
      'alarm_message': top == null ? '' : top['message'],
      'conditions': [
        for (final c in sorted)
          {'key': c['key'], 'level': c['level'], 'code': c['code'], 'message': c['message'], 'ai': c['ai']},
      ],
      'sensors': {
        'temperature': _val('temperature', 1),
        'temp2': _val('temp2', 1),
        'humidity': _val('humidity', 1),
        'hum_temp': _val('hum_temp', 1),
        'water_level': _val('water_level', 0),
        'fire': fire == null ? null : fire >= 1,
        'co2': _val('co2', 0),
        'soil_moisture': _val('soil_moisture', 0),
        'nutrient_ec': _val('nutrient_ec', 2),
      },
      'states': states,
      'sensor_errors': [for (final e in states.entries) if (e.value == 'fault') e.key]..sort(),
      'power': _powerSummary(),
      'part_temps': {for (final p in _parts) p: _val(p, 1)},
      'door_open': door == null ? null : door >= 1,
      'fans': {'main_ok': !fanFailed('main'), 'backup_ok': !fanFailed('backup'), 'failover': failoverLatched},
      'control': Map.of(control),
      'night': {...settings, 'active': nightActive},
      'ai': Map.of(ai),
      'rmu': _rmuLink(),
    };
  }

  Map<String, dynamic> power() => {
    'time': _iso(DateTime.now()),
    ..._powerSummary(),
    'ac_voltage_low': thresholds['ac_voltage_low'],
    'ac_voltage_high': thresholds['ac_voltage_high'],
    'greenhouse_energy_kwh': _round(energyWh / 1000, 3),
    'devices': [
      for (final e in _deviceWatts.entries)
        {'name': e.key, 'label': _names[e.key], 'watts': e.value, 'on': running(e.key)},
    ],
  };

  // ----- RMU 알람 (Trap / alarm 스칼라) --------------------------------------
  /// RMU 알람 코드 받기. 해제 코드(코드+100)면 지운다. 시나리오 28.
  void handleRmuAlarm(int code, {String via = 'trap'}) {
    if (code <= 0) return;
    if (code > 100 && code < 200) {
      rmuAlarms.remove(code - 100);
    } else {
      if (!rmuAlarms.containsKey(code)) {
        final text = _rmuCodeText[code]?.$2 ?? '알 수 없는 코드 $code';
        _notes.add(_Note(0, 'rmu_trap', 'RMU ${via == 'trap' ? 'Trap' : '알람'} 수신: 코드 $code ($text)', [
          '라즈베리파이가 등급을 계산해 알립니다',
        ]));
      }
      rmuAlarms[code] = _ts(DateTime.now());
    }
    _evaluate(DateTime.now());
  }

  // ----- 설정 ---------------------------------------------------------------
  Map<String, dynamic> updateThresholds(Map<String, dynamic> changes) {
    final next = Map.of(thresholds);
    for (final e in changes.entries) {
      if (!next.containsKey(e.key)) throw DemoRmuError(400, '알 수 없는 임계값: ${e.key}');
      if (e.value is! num) throw DemoRmuError(400, '${e.key}는 숫자여야 합니다');
      next[e.key] = (e.value as num).toDouble();
    }
    for (final (low, high) in const [
      ('temp_low', 'temp_high'),
      ('humidity_low', 'humidity_high'),
      ('part_temp_low', 'part_temp_high'),
      ('cooling_setpoint', 'heating_setpoint'),
      ('ac_voltage_low', 'ac_voltage_high'),
    ]) {
      if (next[low]! >= next[high]!) throw DemoRmuError(400, '$low는 $high보다 작아야 합니다');
    }
    for (final key in const ['cooling_setpoint', 'heating_setpoint']) {
      if (next[key]! < 16 || next[key]! > 30) {
        throw DemoRmuError(400, '$key는 16~30℃입니다 (에어컨 설정 범위)');
      }
    }
    thresholds = next;
    _evaluate(DateTime.now(), '임계값 변경');
    return Map.of(thresholds);
  }

  Map<String, dynamic> updateSettings(Map<String, dynamic> changes) {
    final next = Map.of(settings);
    for (final e in changes.entries) {
      if (!next.containsKey(e.key)) throw DemoRmuError(400, '알 수 없는 설정: ${e.key}');
      final value = e.value;
      if (value is! int) throw DemoRmuError(400, '${e.key}는 정수여야 합니다');
      if (e.key == 'night_mode' && value != 0 && value != 1) {
        throw DemoRmuError(400, 'night_mode는 0 또는 1입니다');
      }
      if ((e.key == 'night_start' || e.key == 'night_end') && (value < 0 || value >= 24 * 60)) {
        throw DemoRmuError(400, '${e.key}는 0~1439(분) 사이여야 합니다');
      }
      next[e.key] = value;
    }
    if (next['night_start'] == next['night_end']) {
      throw DemoRmuError(400, '야간 시작과 종료 시각이 같을 수 없습니다');
    }
    settings = next;
    _evaluate(DateTime.now(), '야간 모드 설정 변경');
    return Map.of(settings);
  }

  /// AI 모드 전환 (시나리오 29)
  Map<String, dynamic> setMode(Object? newMode) {
    if (newMode != 'demo' && newMode != 'live') {
      throw DemoRmuError(400, 'mode는 demo 또는 live입니다');
    }
    if (newMode != mode) {
      mode = newMode as String;
      aiActive = aiFan = false;
      for (final s in suggestions) {
        if (s['status'] == 'pending') s['status'] = 'expired';
      }
      _notes.add(_Note(
        0,
        'mode',
        mode == 'demo' ? 'AI 모드: 데모로 전환 (시뮬레이션 값, AI 자동 실행)' : 'AI 모드: 실사용으로 전환 (실제 값, AI는 위험 낮은 조치만 자동)',
        [],
      ));
      _evaluate(DateTime.now());
    }
    return {'mode': mode};
  }

  // ----- AI 제안 (실사용 모드) ------------------------------------------------
  List<Map<String, dynamic>> listSuggestions() => [for (final s in suggestions.reversed) Map.of(s)];

  Map<String, dynamic> decideSuggestion(int sid, bool approve) {
    final s = suggestions.where((x) => x['id'] == sid).firstOrNull;
    if (s == null) throw DemoRmuError(404, '제안을 찾을 수 없습니다');
    if (s['status'] != 'pending') throw DemoRmuError(409, '이미 처리된 제안입니다 (${s['status']})');
    if (!_aiAllowList.containsKey((s['action'] as Map)['device'])) {
      throw DemoRmuError(409, '허용 목록에 없는 조치입니다');
    }
    if (approve) {
      if (base['control_mode'] != 1) {
        throw DemoRmuError(409, '수동 모드에서는 AI 조치를 실행하지 않습니다 (수동 조작 우선)');
      }
      s['status'] = 'approved';
      if (s['kind'] == 'precool') {
        aiActive = true;
        aiStarted = _ts(DateTime.now());
      }
      _notes.add(_Note(0, 'ai', 'AI 제안 승인: ${s['title']}', ['판단 이유: ${s['reason']}'], true));
    } else {
      s['status'] = 'rejected';
      _notes.add(_Note(0, 'ai', 'AI 제안 거절: ${s['title']}', [], true));
    }
    _evaluate(DateTime.now(), 'AI 제안 처리');
    return Map.of(s);
  }

  // ----- 사용자 조작 -----------------------------------------------------------
  Map<String, dynamic> applyControl(String? device, Object? value) {
    final auto = base['control_mode'] == 1;
    if (device == 'control_mode') {
      if (value != 0 && value != 1) {
        throw DemoRmuError(400, 'control_mode는 0(수동) 또는 1(자동)입니다');
      }
      if (value == 0 && auto) {
        savedBase = Map.of(base);
        base = Map.of(control);
        if (nightActive) {
          base['cover'] = savedBase!['cover']!;
          base['lights'] = savedBase!['lights']!;
        }
        manualStart = Map.of(base);
        pumpStartedAt = null;
        aiActive = aiFan = false; // 수동 조작 우선
      } else if (value == 1 && !auto && savedBase != null) {
        for (final k in base.keys.toList()) {
          if (base[k] == manualStart[k]) base[k] = savedBase![k]!;
        }
        savedBase = null;
      }
      base['control_mode'] = value as int;
    } else if (device == 'restore_main_fan') {
      if (fanFailed('main')) throw DemoRmuError(409, '메인 환풍기가 아직 고장 상태입니다');
      if (!failoverLatched) throw DemoRmuError(409, '예비 환풍기로 대체 중이 아닙니다');
      failoverLatched = false;
    } else if (device != null && base.containsKey(device)) {
      if (auto) {
        throw DemoRmuError(409, '자동 모드에서는 수동 조작이 잠겨 있습니다. 제어 모드를 수동으로 바꾸세요');
      }
      if (device == 'aircon_setpoint') {
        if (value is! num || value < 16 || value > 30) {
          throw DemoRmuError(400, '에어컨 설정온도는 16~30℃입니다');
        }
        base[device] = value.toDouble();
      } else {
        if (value != 0 && value != 1) throw DemoRmuError(400, '$device는 0 또는 1입니다');
        base[device] = value as int;
      }
    } else {
      throw DemoRmuError(400, '알 수 없는 장치: $device');
    }
    _evaluate(DateTime.now(), '사용자 조작');
    return Map.of(control);
  }

  // ----- 시뮬레이션 -------------------------------------------------------------
  String simulate(String? name, Map<String, dynamic> params) {
    final s = sim;
    final severe = params['severe'] == true;
    final now = DateTime.now();
    switch (name) {
      case 'normal':
        final faultsOrComm = s.sensorFaults.isNotEmpty || s.commLossUntil != null;
        sim = DemoSim();
        base = Map.of(_defaultBase);
        savedBase = null;
        failoverLatched = false;
        pumpRetryAt = 0;
        rmuAlarms = {};
        values.addAll({
          'temperature': 25.0,
          'water_level': 80.0,
          'pi_temp': 48.0,
          'main_fan_temp': 35.0,
          'backup_fan_temp': 28.0,
          'cooling_fan_temp': 28.0,
        });
        _tempSamples = [];
        _waterSamples = [];
        aiActive = aiFan = false;
        for (final sug in suggestions) {
          if (sug['status'] == 'pending') sug['status'] = 'expired';
        }
        if (faultsOrComm) _notes.add(_Note(0, 'sim', '센서 오류·통신 두절 해제', []));
        return '모든 시뮬레이션과 장치 설정을 초기화했습니다';
      case 'high_temp':
        s.heat = severe ? 0.8 : 0.3;
        s.aiBypass = true;
        return '고온 시작${severe ? ' (냉방으로도 못 막음 → 긴급 경보)' : ' (냉방 후 복구)'}, AI 선가동 끔';
      case 'slow_heat':
        s.heat = 0.2;
        s.aiBypass = false;
        return '온도가 서서히 오릅니다. AI 선가동을 확인하세요';
      case 'ai_live_demo':
        s.heat = 0.2;
        s.aiBypass = false;
        setMode('live');
        return '실사용 모드로 바꾸고 온도를 서서히 올립니다. 쿨링팬은 자동, 에어컨은 제안 → 승인';
      case 'low_temp':
        s.heat = severe ? -1.2 : -0.6;
        return '저온 시작${severe ? ' (난방으로도 못 막음 → 긴급 경보)' : ' (난방 후 복구)'}';
      case 'part_high' || 'part_low':
        final part = (params['part'] as String?) ?? 'pi_temp';
        if (!_parts.contains(part)) throw DemoRmuError(400, 'part는 $_parts 중 하나입니다');
        final load = severe ? 4.0 : 2.0;
        s.partLoad[part] = name == 'part_high' ? load : -load * 1.5;
        return '${_names[part]} ${name == 'part_high' ? '고온' : '저온'} 시작${severe ? ' (악화 → 긴급)' : ''}';
      case 'main_fan_fail':
        s.fanFailed['main'] = true;
        return '메인 환풍기 고장';
      case 'fans_fail':
        s.fanFailed = {'main': true, 'backup': true};
        return '메인·예비 환풍기 모두 고장';
      case 'fan_repair':
        s.fanFailed = {'main': false, 'backup': false};
        if (failoverLatched) {
          _notes.add(_Note(0, 'fan', '메인 환풍기 복구됨. 확인 후 메인으로 전환하세요', []));
        }
        return '환풍기 수리 완료 (메인 전환은 사용자가 확인 후 직접)';
      case 'water_low':
        s.waterTarget = 10.0;
        values['water_level'] = 15.0;
        return '수위 부족 (물탱크가 거의 비었습니다)';
      case 'water_leak':
        s.leak = true;
        return '누수 흉내: 펌프가 꺼져 있는데 수위가 빨리 줄어듭니다 (AI 누수 의심)';
      case 'water_refill':
        s.waterTarget = 80.0;
        s.leak = false;
        values['water_level'] = 80.0;
        return '물탱크를 채웠습니다';
      case 'fire':
        s.fire = true;
        return '화재 감지';
      case 'fire_clear':
        s.fire = false;
        return '화재 감지 해제';
      case 'power_abnormal':
        s.acBase = params['high'] == false ? 180.0 : 250.0;
        return 'AC 전압 이상 (${_f(s.acBase, 0)}V)';
      case 'power_cut':
        s.powerCut = true;
        return 'AC 전원 차단';
      case 'power_restore':
        s.acBase = _defaultAc;
        s.powerCut = false;
        return '전원 정상화';
      case 'comm_loss':
        final seconds = (params['seconds'] as num?)?.toInt() ?? 30;
        s.commLossUntil = _ts(now) + seconds;
        return '통신 두절 $seconds초 (그동안 라즈베리파이가 응답하지 않습니다)';
      case 'comm_restore':
        s.commLossUntil = null;
        return '통신 복구';
      case 'rmu_offline':
        if (!s.rmuOffline) {
          s.rmuOffline = true;
          s.rmuOfflineSince = now;
          s.rmuFrozen = {for (final n in _rmuItems) n: values[n]!};
        }
        return 'RMU 통신 두절 흉내: RMU 항목(온도·전원)은 마지막 값을 회색으로 표시';
      case 'rmu_online':
        s.rmuOffline = false;
        s.rmuFrozen = {};
        s.rmuOfflineSince = null;
        return 'RMU 통신 복구';
      case 'sensor_fault':
        final sensor = (params['sensor'] as String?) ?? 'humidity';
        if (!_sensors.contains(sensor)) throw DemoRmuError(400, 'sensor는 $_sensors 중 하나입니다');
        s.sensorFaults.add(sensor);
        _notes.add(_Note(0, 'sensor_fault', '센서 오류: ${_names[sensor]}', ['센서 연결을 확인하세요']));
        return '${_names[sensor]} 센서 오류';
      case 'sensor_restore':
        s.sensorFaults.clear();
        s.stuck = false;
        _notes.add(_Note(0, 'sensor_fault', '센서 정상 복구', []));
        return '센서 오류 해제';
      case 'sensor_mismatch':
        s.mismatch = 5.0;
        return '온습도감지기 온도가 RMU 온도와 5℃ 어긋납니다 (30초 뒤 AI 불일치 판단)';
      case 'sensor_match':
        s.mismatch = 0.0;
        return '센서 불일치 해제';
      case 'sensor_stuck':
        s.stuck = true;
        return '온도 값을 고정합니다 ($_stuckSeconds초 뒤 AI 고장 의심)';
      case 'night_on':
        s.nightOverride = true;
        return '야간 모드 강제 진입';
      case 'night_off':
        s.nightOverride = false;
        return '야간 모드 강제 해제';
      case 'night_auto':
        s.nightOverride = null;
        return '야간 모드를 설정 시각대로';
      case 'motion':
        if (nightActive) {
          s.motionUntil = _ts(now) + _motionAlarmSeconds;
          return '야간 움직임 감지';
        }
        _notes.add(_Note(0, 'motion', '주간 움직임 감지 (야간이 아니어서 경보 없음)', []));
        return '주간이라 경보 없음';
      case 'door_open':
        s.doorOpen = true;
        return '전면 도어 열림 (RMU doorFront)';
      case 'door_close':
        s.doorOpen = false;
        return '전면 도어 닫힘';
      case 'rmu_trap':
        final code = (params['code'] as num?)?.toInt() ?? 61;
        handleRmuAlarm(code);
        return 'RMU Trap 흉내: 알람 코드 $code 수신';
      case 'rmu_trap_clear':
        final code = (params['code'] as num?)?.toInt() ?? 61;
        handleRmuAlarm(code + 100);
        return 'RMU Trap 흉내: 해제 코드 ${code + 100} 수신';
      case 'mode_demo' || 'mode_live':
        setMode(name!.substring(5));
        return 'AI 모드를 ${name == 'mode_demo' ? '데모' : '실사용'}로 바꿨습니다';
    }
    throw DemoRmuError(400, '알 수 없는 시나리오: $name');
  }

  // =========================================================================
  // REST 흉내: RmuApi가 HTTP 대신 부른다 (rmu/server.py 와 같은 경로·응답)
  // =========================================================================
  static final _suggestionRoute = RegExp(r'^/api/ai/suggestions/(\d+)/(approve|reject)$');

  Map<String, dynamic> handle(String method, String path, Object? body, String? token) {
    final uri = Uri.parse(path);
    final route = uri.path;
    // 실제 HTTP는 JSON 객체가 오므로, 타입이 없는 맵({})이 와도 같은 모양으로 바꾼다
    final data = body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
    if (commLost() && route != '/api/simulate') {
      throw DemoRmuError(503, '통신 두절 (시뮬레이션)');
    }
    bool admin() => token != null && _tokens.contains(token);
    void requireAdmin() {
      if (!admin()) throw DemoRmuError(401, '로그인이 필요합니다');
    }

    final suggestion = _suggestionRoute.firstMatch(route);
    if (method == 'POST' && suggestion != null) {
      requireAdmin();
      return decideSuggestion(int.parse(suggestion.group(1)!), suggestion.group(2) == 'approve');
    }

    switch ((method, route)) {
      case ('GET', '/api/status'):
        return status();
      case ('GET', '/api/power'):
        return power();
      case ('GET', '/api/thresholds'):
        return Map.of(thresholds);
      case ('GET', '/api/settings'):
        return Map.of(settings);
      case ('GET', '/api/mode'):
        return {'mode': mode};
      case ('GET', '/api/ai/suggestions'):
        return {'mode': mode, 'suggestions': listSuggestions()};
      case ('GET', '/api/crops'):
        return {for (final e in _crops.entries) e.key: Map<String, dynamic>.of(e.value)};
      case ('GET', '/api/events'):
        final since = int.tryParse(uri.queryParameters['since'] ?? '0') ?? 0;
        return {
          'events': [for (final e in events) if ((e['id'] as int) > since) e],
          'last_id': nextEventId - 1,
        };
      case ('GET', '/api/history'):
        final sensor = uri.queryParameters['sensor'] ?? 'temperature';
        final range = uri.queryParameters['range'] ?? '1h';
        return {'sensor': sensor, 'range': range, 'points': history(sensor, range)};
      case ('GET', '/api/simulate'):
        return {'scenarios': demoScenarios, 'parts': _parts};
      case ('POST', '/api/login'):
        if (data['username'] == _demoAdmin['username'] && data['password'] == _demoAdmin['password']) {
          // 웹에서는 1 << 32 가 0이 되므로(32비트 계산) 그보다 작은 범위를 쓴다
          final token = 'demo-${_rand.nextInt(1000000000)}';
          _tokens.add(token);
          return {'token': token};
        }
        throw DemoRmuError(401, '아이디 또는 비밀번호가 틀렸습니다');
      case ('POST', '/api/simulate'):
        return {'ok': true, 'scenario': data['scenario'], 'message': simulate(data['scenario'] as String?, data)};
      case ('POST', '/api/control'):
        requireAdmin();
        return {'ok': true, 'control': applyControl(data['device'] as String?, data['value'])};
      case ('PUT', '/api/thresholds'):
        requireAdmin();
        return updateThresholds(data);
      case ('PUT', '/api/settings'):
        requireAdmin();
        return updateSettings(data);
      case ('PUT', '/api/mode'):
        requireAdmin();
        return setMode(data['mode']);
    }
    throw DemoRmuError(404, 'not found');
  }
}
