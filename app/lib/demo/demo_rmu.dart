// 앱 안에서 돌아가는 체험용 모의 RMU (데모 모드).
//
// rmu/rmu_model.py 와 rmu/server.py 의 규칙을 Dart로 옮긴 것이다.
// RMU 서버 없이(같은 와이파이도 필요 없이) 앱만으로 시나리오 1~22를 확인할 수 있다.
// 농장 주소가 "demo:1", "demo:2" 이면 RmuApi가 HTTP 대신 이 클래스를 부른다.
// 응답 JSON 모양은 실제 RMU REST API(CLAUDE.md 6장)와 같다.
//
// 규칙을 바꿀 때는 rmu/rmu_model.py 가 기준이다. 이 파일도 같이 고친다.

import 'dart:async';
import 'dart:math' as math;

// ---------------------------------------------------------------------------
// 기준값 (rmu_model.py와 같음)
// ---------------------------------------------------------------------------
const _defaultThresholds = <String, double>{
  'temp_low': 15.0,
  'temp_high': 30.0,
  'humidity_low': 50.0,
  'humidity_high': 85.0,
  'soil_low': 35.0,
  'voltage_low': 4.75,
  'current_high': 3.0,
  'co2_high': 1500,
  'ec_low': 1.0,
  'rmu_temp_high': 80.0,
  'part_temp_high': 60.0,
  'part_temp_low': 0.0,
  'cooling_setpoint': 22.0,
  'heating_setpoint': 28.0,
};

const _hyst = {
  'temp': 2.0,
  'part': 5.0,
  'humidity': 2.0,
  'soil': 5.0,
  'co2': 300.0,
  'ec': 0.2,
  'voltage': 0.1,
  'current': 0.3,
};
const _emergencyMargin = {'temp': 2.0, 'part': 10.0};

const _pumpMaxSeconds = 60;
const _pumpRetrySeconds = 600;
const _motionAlarmSeconds = 30;

const _aiWindowSeconds = 30;
const _aiMinSamples = 10;
const _aiLeadSeconds = 120;
const _aiMinSlope = 0.002;
const _aiMinHoldSeconds = 60;
const _aiReleaseMargin = 4.0;

const _maxEvents = 500;
const _recordSeconds = 10;

const _parts = [
  'rmu_temp',
  'main_fan_temp',
  'backup_fan_temp',
  'cooling_fan_temp',
];
const _sensors = [
  'temperature',
  'humidity',
  'soil_moisture',
  'co2',
  'nutrient_ec',
  ..._parts,
];

const _names = {
  'temperature': '온도',
  'humidity': '습도',
  'soil_moisture': '토양수분',
  'co2': 'CO2',
  'nutrient_ec': '양분(EC)',
  'rmu_temp': 'RMU 온도',
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

const _highEmergencyStop = ['heater', 'lights', 'pump'];
const _lowEmergencyStop = [
  'aircon',
  'cooling_fan',
  'main_fan',
  'backup_fan',
  'lights',
  'pump',
];

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
const _defaultVoltage = 5.05;

const _demoAdmin = {'username': 'admin', 'password': 'admin1234'};

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

const _historySensors = [
  'temperature',
  'humidity',
  'soil_moisture',
  'co2',
  'nutrient_ec',
  'supply_voltage',
  'supply_current',
  'greenhouse_power',
  'rmu_temp',
  'main_fan_temp',
  'backup_fan_temp',
  'cooling_fan_temp',
  'alarm_level',
];
const _ranges = {
  '1h': 3600,
  '6h': 6 * 3600,
  '24h': 24 * 3600,
  '7d': 7 * 24 * 3600,
};

/// 시뮬레이션 버튼 목록 (rmu_model.py의 SCENARIOS와 같음)
const demoScenarios = <Map<String, dynamic>>[
  {'name': 'normal', 'label': '전부 정상으로', 'scenario': 1},
  {'name': 'high_temp', 'label': '고온 → 냉방 → 복구', 'scenario': 2},
  {
    'name': 'high_temp',
    'label': '고온 지속 → 긴급',
    'scenario': 3,
    'params': {'severe': true},
  },
  {'name': 'low_temp', 'label': '저온 → 난방 → 복구', 'scenario': 4},
  {
    'name': 'low_temp',
    'label': '저온 지속 → 긴급',
    'scenario': 5,
    'params': {'severe': true},
  },
  {
    'name': 'part_high',
    'label': 'RMU 온도 높음',
    'scenario': 6,
    'params': {'part': 'rmu_temp'},
  },
  {
    'name': 'part_high',
    'label': '쿨링팬 온도 높음 → 긴급',
    'scenario': 6,
    'params': {'part': 'cooling_fan_temp', 'severe': true},
  },
  {
    'name': 'part_low',
    'label': '메인 환풍기 온도 낮음',
    'scenario': 6,
    'params': {'part': 'main_fan_temp'},
  },
  {'name': 'main_fan_fail', 'label': '메인 환풍기 고장', 'scenario': 7},
  {'name': 'fans_fail', 'label': '환풍기 둘 다 고장', 'scenario': 8},
  {'name': 'fan_repair', 'label': '환풍기 수리', 'scenario': 7},
  {'name': 'soil_dry', 'label': '토양 건조', 'scenario': 9},
  {
    'name': 'soil_dry',
    'label': '토양 건조 (물 공급 문제)',
    'scenario': 9,
    'params': {'severe': true},
  },
  {'name': 'low_voltage', 'label': '공급 전압 저하', 'scenario': 10},
  {'name': 'over_current', 'label': '과전류', 'scenario': 10},
  {'name': 'power_cut', 'label': '전원 차단', 'scenario': 10},
  {'name': 'power_restore', 'label': '전원 정상화', 'scenario': 10},
  {'name': 'co2_high', 'label': 'CO2 농도 높음', 'scenario': 11},
  {'name': 'nutrient_low', 'label': '양분 부족', 'scenario': 11},
  {'name': 'nutrient_refill', 'label': '양액 보충', 'scenario': 11},
  {
    'name': 'comm_loss',
    'label': '통신 두절 30초',
    'scenario': 12,
    'params': {'seconds': 30},
  },
  {'name': 'comm_restore', 'label': '통신 복구', 'scenario': 12},
  {
    'name': 'sensor_fault',
    'label': '습도 센서 오류',
    'scenario': 13,
    'params': {'sensor': 'humidity'},
  },
  {'name': 'sensor_restore', 'label': '센서 오류 해제', 'scenario': 13},
  {'name': 'night_on', 'label': '야간 모드 진입', 'scenario': 14},
  {'name': 'night_off', 'label': '야간 모드 해제', 'scenario': 14},
  {'name': 'night_auto', 'label': '야간 모드 시각대로', 'scenario': 14},
  {'name': 'motion', 'label': 'CCTV 움직임 감지', 'scenario': 15},
  {'name': 'slow_heat', 'label': '온도 서서히 상승 (AI 선가동)', 'scenario': 22},
];

// ---------------------------------------------------------------------------
// 도우미
// ---------------------------------------------------------------------------
double _clamp(double v, double low, double high) =>
    math.max(low, math.min(high, v));

String _josa(String word, String withBatchim, String withoutBatchim) {
  final last = word.codeUnitAt(word.length - 1);
  if (last >= 0xAC00 && last <= 0xD7A3 && (last - 0xAC00) % 28 != 0) {
    return word + withBatchim;
  }
  return word + withoutBatchim;
}

bool _inNightWindow(int minutes, int start, int end) {
  if (start < end) return start <= minutes && minutes < end;
  return minutes >= start || minutes < end; // 자정을 넘는 구간
}

String _f(num v, int digits) => v.toStringAsFixed(digits);

String _iso(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

double _round(double v, int digits) {
  final p = math.pow(10, digits);
  return (v * p).round() / p;
}

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

/// 데모 RMU가 돌려주는 오류 (HTTP 상태 코드와 같은 의미)
class DemoRmuError implements Exception {
  final int statusCode;
  final String message;
  DemoRmuError(this.statusCode, this.message);
}

class DemoSim {
  double heat = 0;
  Map<String, double> partLoad = {for (final p in _parts) p: 0.0};
  Map<String, bool> fanFailed = {'main': false, 'backup': false};
  bool pumpBlocked = false;
  bool aiBypass = false;
  bool co2Source = false;
  double ecBase = 1.8;
  double voltageBase = _defaultVoltage;
  double currentFault = 0;
  bool powerCut = false;
  double? commLossUntil;
  Set<String> sensorFaults = {};
  bool? nightOverride;
  double motionUntil = 0;
}

class _Note {
  final int level;
  final String key;
  final String message;
  final List<String> guide;
  _Note(this.level, this.key, this.message, this.guide);
}

// ---------------------------------------------------------------------------
// 데모 RMU
// ---------------------------------------------------------------------------
class DemoRmu {
  static final Map<String, DemoRmu> _instances = {};

  /// 주소("demo:1")마다 하나씩. 처음 부를 때 만들어 1초마다 돌린다.
  static DemoRmu forAddress(String address) =>
      _instances.putIfAbsent(address, () => DemoRmu()..start());

  static bool isDemoUrl(String baseUrl) => baseUrl.startsWith('http://demo:');

  final _rand = math.Random();
  Timer? _timer;

  final Map<String, double> values = {
    'temperature': 25.0,
    'humidity': 72.0,
    'soil_moisture': 45.0,
    'co2': 450.0,
    'nutrient_ec': 1.8,
    'supply_voltage': 5.05,
    'supply_current': 0.6,
    'rmu_temp': 48.0,
    'main_fan_temp': 35.0,
    'backup_fan_temp': 28.0,
    'cooling_fan_temp': 28.0,
  };
  Map<String, num> base = Map.of(_defaultBase);
  Map<String, num>? savedBase;
  Map<String, num> manualStart = {};
  Map<String, num> control = Map.of(_defaultBase);
  Map<String, double> thresholds = Map.of(_defaultThresholds);
  Map<String, int> settings = Map.of(_defaultSettings);
  DemoSim sim = DemoSim();

  String tempState = 'normal';
  Map<String, String> partStates = {for (final p in _parts) p: 'normal'};
  Map<String, Map<String, dynamic>> active = {};
  bool nightActive = false;
  bool failoverLatched = false;
  double? pumpStartedAt;
  double pumpRetryAt = 0;
  double energyWh = 0;
  final List<Map<String, dynamic>> events = [];
  int nextEventId = 1;
  final List<_Note> _notes = [];

  final List<(double, double)> _tempSamples = [];
  bool aiActive = false;
  double aiStarted = 0;
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

  // ===== 1초마다 =====
  void tick([DateTime? now]) {
    now ??= DateTime.now();
    _updatePhysics();
    _updateAi(now.millisecondsSinceEpoch / 1000);
    _evaluate(now);
    _maybeRecord(now);
  }

  bool running(String device) {
    if (control[device] == 0) return false;
    if (_supplyDevices.contains(device) && sim.powerCut) return false;
    if (device == 'main_fan' && sim.fanFailed['main']!) return false;
    if (device == 'backup_fan' && sim.fanFailed['backup']!) return false;
    return true;
  }

  void _updatePhysics() {
    final v = values, c = control, s = sim;
    var dt = s.heat + _rnd(-0.05, 0.05);
    if (running('aircon')) {
      dt += 0.03 * (c['aircon_setpoint']! - v['temperature']!);
    }
    if (running('cooling_fan')) dt -= 0.2;
    if (running('heater')) dt += 0.4;
    if (running('backup_fan')) dt -= 0.05;
    v['temperature'] = _clamp(v['temperature']! + dt, -20, 60);

    for (final p in _parts) {
      final base = p == 'rmu_temp'
          ? 48.0
          : (running(p.replaceAll('_temp', '')) ? 35.0 : 28.0);
      final t = v[p]!;
      var d = s.partLoad[p]! - 0.05 * (t - base) + _rnd(-0.1, 0.1);
      if (running('cooling_fan') && t > base) d -= 1.5;
      if (running('heater') && t < base) d += 2.0;
      v[p] = _clamp(t + d, -60, 150);
    }

    v['humidity'] = _clamp(
      v['humidity']! + 0.1 * (72 - v['humidity']!) + _rnd(-0.5, 0.5),
      0,
      100,
    );
    final pumpEffect = running('pump') && !s.pumpBlocked ? 0.5 : 0.0;
    v['soil_moisture'] = _clamp(
      v['soil_moisture']! +
          pumpEffect +
          0.002 * (45 - v['soil_moisture']!) +
          _rnd(-0.1, 0.1),
      0,
      100,
    );

    var dco2 = 0.02 * (450 - v['co2']!) + _rnd(-5, 5);
    if (s.co2Source) dco2 += 80;
    if (running('backup_fan')) dco2 -= 120;
    v['co2'] = _clamp(v['co2']! + dco2, 300, 5000);

    v['nutrient_ec'] = _clamp(
      v['nutrient_ec']! +
          0.1 * (s.ecBase - v['nutrient_ec']!) +
          _rnd(-0.02, 0.02),
      0,
      5,
    );

    if (s.powerCut) {
      v['supply_voltage'] = 0;
      v['supply_current'] = 0;
    } else {
      v['supply_voltage'] =
          v['supply_voltage']! +
          0.3 * (s.voltageBase - v['supply_voltage']!) +
          _rnd(-0.01, 0.01);
      double on(String d) => running(d) ? 1 : 0;
      final target =
          0.4 +
          0.2 * on('main_fan') +
          0.2 * on('backup_fan') +
          0.3 * on('cooling_fan') +
          0.5 * on('pump') +
          s.currentFault;
      v['supply_current'] = math.max(
        0,
        v['supply_current']! +
            0.3 * (target - v['supply_current']!) +
            _rnd(-0.02, 0.02),
      );
    }
    energyWh += greenhousePower() / 3600;
  }

  int greenhousePower() =>
      _baseWatts +
      _deviceWatts.entries
          .where((e) => running(e.key))
          .fold(0, (sum, e) => sum + e.value);

  // ===== AI 선가동 =====
  void _updateAi(double ts) {
    final temp = values['temperature']!;
    final high = thresholds['temp_high']!;
    _tempSamples.add((ts, temp));
    while (_tempSamples.isNotEmpty &&
        ts - _tempSamples.first.$1 > _aiWindowSeconds) {
      _tempSamples.removeAt(0);
    }
    final slope = _slope();
    final eta = (slope != null && slope > 0 && temp < high)
        ? (high - temp) / slope
        : null;
    final String reason;
    if (slope == null) {
      reason = '데이터 수집 중';
    } else if (eta != null) {
      reason =
          '최근 $_aiWindowSeconds초 상승 속도 ${_f(slope * 60, 2)}℃/분, '
          '이대로면 약 ${_f(eta / 60, 1)}분 뒤 상한 ${_f(high, 1)}℃ 도달';
    } else {
      final s = slope * 60;
      reason = '온도 변화 ${s >= 0 ? '+' : ''}${_f(s, 2)}℃/분, 상한 도달 예상 없음';
    }

    final auto = base['control_mode'] == 1;
    final heating = [
      tempState,
      ...partStates.values,
    ].any((st) => st == 'low' || st == 'low_emergency');
    final usable =
        auto &&
        !heating &&
        !sim.aiBypass &&
        !sensorFaults().contains('temperature') &&
        tempState == 'normal';
    if (!aiActive) {
      if (usable &&
          eta != null &&
          eta <= _aiLeadSeconds &&
          slope! >= _aiMinSlope) {
        aiActive = true;
        aiStarted = ts;
        _notes.add(
          _Note(0, 'ai', 'AI 선가동: 상한 도달 전에 냉방을 시작합니다', ['판단 이유: $reason']),
        );
      }
    } else if (!usable) {
      aiActive = false;
    } else if (ts - aiStarted >= _aiMinHoldSeconds &&
        temp <= high - _aiReleaseMargin &&
        slope != null &&
        slope <= 0) {
      aiActive = false;
      sim.heat = 0;
      _notes.add(_Note(0, 'ai', 'AI 선가동 종료: 온도가 안정되었습니다', ['판단 이유: $reason']));
    }
    ai = {
      'active': aiActive,
      'reason': reason,
      'slope_per_min': slope == null ? null : _round(slope * 60, 2),
      'eta_seconds': eta?.round(),
    };
  }

  double? _slope() {
    final pts = _tempSamples;
    if (pts.length < _aiMinSamples) return null;
    final n = pts.length;
    final meanT = pts.fold(0.0, (s, p) => s + p.$1) / n;
    final meanV = pts.fold(0.0, (s, p) => s + p.$2) / n;
    final den = pts.fold(0.0, (s, p) => s + (p.$1 - meanT) * (p.$1 - meanT));
    if (den == 0) return null;
    return pts.fold(0.0, (s, p) => s + (p.$1 - meanT) * (p.$2 - meanV)) / den;
  }

  Set<String> sensorFaults() => sim.sensorFaults;

  // ===== 판정 → 출력 → 이벤트 =====
  void _evaluate(DateTime now, [String? defaultMessage]) {
    final ts = now.millisecondsSinceEpoch / 1000;
    _updateTempStates();
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
      if (state == 'high' && auto && value > high + margin) {
        return 'high_emergency';
      }
    } else if (state == 'low' || state == 'low_emergency') {
      if (value >= low + hyst) return 'normal';
      if (state == 'low' && auto && value < low - margin) {
        return 'low_emergency';
      }
    }
    return state;
  }

  void _updateTempStates() {
    final th = thresholds,
        auto = base['control_mode'] == 1,
        faults = sensorFaults();
    if (!faults.contains('temperature')) {
      final next = _nextState(
        tempState,
        values['temperature']!,
        th['temp_low']!,
        th['temp_high']!,
        _hyst['temp']!,
        _emergencyMargin['temp']!,
        auto,
      );
      if (next == 'normal' && tempState != 'normal') {
        sim.heat = 0;
        sim.aiBypass = false;
      }
      tempState = next;
    }
    for (final p in _parts) {
      if (faults.contains(p)) continue;
      final high = p == 'rmu_temp'
          ? th['rmu_temp_high']!
          : th['part_temp_high']!;
      final next = _nextState(
        partStates[p]!,
        values[p]!,
        th['part_temp_low']!,
        high,
        _hyst['part']!,
        _emergencyMargin['part']!,
        auto,
      );
      if (next == 'normal' && partStates[p] != 'normal') sim.partLoad[p] = 0;
      partStates[p] = next;
    }
  }

  void _updateNight(DateTime now) {
    final bool night;
    if (sim.nightOverride != null) {
      night = sim.nightOverride!;
    } else if (settings['night_mode'] == 1) {
      night = _inNightWindow(
        now.hour * 60 + now.minute,
        settings['night_start']!,
        settings['night_end']!,
      );
    } else {
      night = false;
    }
    if (night != nightActive) {
      _notes.add(_Note(0, 'night', night ? '야간 모드 진입' : '야간 모드 해제', []));
    }
    nightActive = night;
  }

  bool fanFailed(String which) => sim.fanFailed[which]!;

  Map<String, Map<String, dynamic>> _evaluateConditions(double ts) {
    final v = values, th = thresholds, s = sim;
    final auto = base['control_mode'] == 1;
    final prev = active;
    final cond = <String, Map<String, dynamic>>{};

    void add(
      String key,
      int level,
      String? trap,
      String message, [
      List<String>? guide,
    ]) {
      cond[key] = {
        'key': key,
        'level': level,
        'trap': trap,
        'message': message,
        'guide': [...?guide],
      };
    }

    bool hyst(String key, bool enter, bool stay) =>
        prev.containsKey(key) ? stay : enter;

    final t = v['temperature']!;
    switch (tempState) {
      case 'high':
        add(
          'temp',
          2,
          'highTempAlarm',
          '온실 온도 상한 초과 (${_f(t, 1)}℃ > ${_f(th['temp_high']!, 1)}℃)',
        );
      case 'high_emergency':
        add('temp', 3, 'emergencyAlarm', '긴급: 냉방 후에도 온도 상승 (${_f(t, 1)}℃)');
      case 'low':
        add(
          'temp',
          2,
          'lowTempAlarm',
          '온실 온도 하한 미만 (${_f(t, 1)}℃ < ${_f(th['temp_low']!, 1)}℃)',
        );
      case 'low_emergency':
        add('temp', 3, 'emergencyAlarm', '긴급: 난방 후에도 온도 하락 (${_f(t, 1)}℃)');
    }
    if (tempState != 'normal' && nightActive) {
      (cond['temp']!['guide'] as List<String>).add(
        '야간이지만 온도 경보를 우선합니다. 환기를 먼저 가동하고 전구는 소등을 유지합니다',
      );
    }

    for (final p in _parts) {
      final pv = v[p]!;
      switch (partStates[p]) {
        case 'high':
          add(
            'part:$p',
            1,
            'partTempAlarm',
            '${_names[p]} 기준 초과 (${_f(pv, 1)}℃)',
          );
        case 'high_emergency':
          add(
            'part:$p',
            3,
            'emergencyAlarm',
            '긴급: 냉각 후에도 ${_names[p]} 상승 (${_f(pv, 1)}℃)',
          );
        case 'low':
          add(
            'part:$p',
            1,
            'partTempAlarm',
            '${_names[p]} 기준 미만 (${_f(pv, 1)}℃)',
          );
        case 'low_emergency':
          add(
            'part:$p',
            3,
            'emergencyAlarm',
            '긴급: 난방 후에도 ${_names[p]} 하락 (${_f(pv, 1)}℃)',
          );
      }
    }

    final faults = sensorFaults();
    final h = v['humidity']!;
    if (!faults.contains('humidity')) {
      if (hyst(
        'humidity_high',
        h > th['humidity_high']!,
        h > th['humidity_high']! - _hyst['humidity']!,
      )) {
        add('humidity_high', 2, null, '습도 상한 초과 (${_f(h, 1)}%)', ['환기를 확인하세요']);
      }
      if (hyst(
        'humidity_low',
        h < th['humidity_low']!,
        h < th['humidity_low']! + _hyst['humidity']!,
      )) {
        add('humidity_low', 2, null, '습도 하한 미만 (${_f(h, 1)}%)');
      }
    }
    final soil = v['soil_moisture']!;
    if (!faults.contains('soil_moisture') &&
        hyst(
          'soil_dry',
          soil < th['soil_low']!,
          soil < th['soil_low']! + _hyst['soil']!,
        )) {
      add(
        'soil_dry',
        2,
        'dryAlarm',
        '토양 건조 (${_f(soil, 0)}% < ${_f(th['soil_low']!, 0)}%)',
      );
    }
    final co2 = v['co2']!;
    if (!faults.contains('co2') &&
        hyst(
          'co2',
          co2 > th['co2_high']!,
          co2 > th['co2_high']! - _hyst['co2']!,
        )) {
      add('co2', 2, 'co2HighAlarm', 'CO2 농도 높음 (${_f(co2, 0)}ppm)');
    }
    final ec = v['nutrient_ec']!;
    if (!faults.contains('nutrient_ec') &&
        hyst(
          'nutrient',
          ec < th['ec_low']!,
          ec < th['ec_low']! + _hyst['ec']!,
        )) {
      add('nutrient', 2, 'nutrientLowAlarm', '양분 부족 (EC ${_f(ec, 2)}mS/cm)', [
        '양액을 보충하세요',
      ]);
    }

    final volt = v['supply_voltage']!, cur = v['supply_current']!;
    if (s.powerCut || volt < 1.0) {
      add('power_cut', 3, 'powerCutAlarm', '외부 전원 차단', [
        '환풍기·쿨링팬·펌프가 멈춘 상태입니다. 외부 전원을 확인하세요',
      ]);
    } else if (hyst(
      'low_voltage',
      volt < th['voltage_low']!,
      volt < th['voltage_low']! + _hyst['voltage']!,
    )) {
      add('low_voltage', 2, 'lowVoltageAlarm', '공급 전압 저하 (${_f(volt, 2)}V)', [
        '전압이 회복될 때까지 펌프 사용을 제한합니다',
      ]);
    }
    if (hyst(
      'over_current',
      cur > th['current_high']!,
      cur > th['current_high']! - _hyst['current']!,
    )) {
      add('over_current', 2, 'overCurrentAlarm', '과전류 (${_f(cur, 2)}A)', [
        '펌프와 쿨링팬을 차단합니다. 배선과 장치를 점검하세요',
      ]);
    }

    final mainBad = fanFailed('main'), backupBad = fanFailed('backup');
    if (mainBad && backupBad) {
      add('fan', 3, 'emergencyAlarm', '긴급: 메인·예비 환풍기 모두 고장 (대체 수단 없음)', [
        '환풍기를 즉시 점검하세요',
      ]);
    } else if (mainBad) {
      if (auto) {
        add('fan', 2, 'ventFailover', '메인 환풍기 고장, 예비 환풍기로 대체');
      } else {
        add('fan', 2, 'ventFailover', '메인 환풍기 고장', [
          '수동 모드입니다. 예비 환풍기를 직접 켜세요',
        ]);
      }
    } else if (backupBad) {
      add('fan_backup', 1, 'ventFailover', '예비 환풍기 고장 (메인은 정상)');
    }

    if (nightActive && ts < s.motionUntil) {
      add('intrusion', 2, 'nightIntrusionAlarm', '야간 CCTV 움직임 감지', [
        'CCTV를 확인하세요',
      ]);
    }
    return cond;
  }

  void _updatePump(double ts, Map<String, Map<String, dynamic>> cond) {
    final auto = base['control_mode'] == 1;
    final dry = cond.containsKey('soil_dry');
    if (pumpStartedAt == null) {
      if (auto && dry && ts >= pumpRetryAt) pumpStartedAt = ts;
    } else if (!auto || !dry) {
      pumpStartedAt = null;
    } else if (ts - pumpStartedAt! >= _pumpMaxSeconds) {
      pumpStartedAt = null;
      pumpRetryAt = ts + _pumpRetrySeconds;
      _notes.add(
        _Note(2, 'pump', '펌프 최대 $_pumpMaxSeconds초 동작 후 정지 (토양수분이 아직 낮음)', [
          '물 공급 상태를 확인하세요',
        ]),
      );
    }
  }

  void _updateFailover() {
    if (base['control_mode'] == 1 &&
        fanFailed('main') &&
        base['main_fan'] == 1) {
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

    final parts = partStates.values;
    final cooling =
        aiActive ||
        tempState == 'high' ||
        tempState == 'high_emergency' ||
        parts.any((p) => p == 'high' || p == 'high_emergency');
    final heating =
        tempState == 'low' ||
        tempState == 'low_emergency' ||
        parts.any((p) => p == 'low' || p == 'low_emergency');
    if (cooling) {
      c['aircon'] = 1;
      c['aircon_setpoint'] = math.min(
        c['aircon_setpoint']!.toDouble(),
        thresholds['cooling_setpoint']!,
      );
      c['cooling_fan'] = 1;
    } else if (heating) {
      c['heater'] = 1;
      if (c['aircon'] == 1) {
        c['aircon_setpoint'] = math.max(
          c['aircon_setpoint']!.toDouble(),
          thresholds['heating_setpoint']!,
        );
      }
    }
    if (cond.containsKey('co2') || (nightActive && tempState != 'normal')) {
      c['backup_fan'] = 1;
    }
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
    if (cond.containsKey('low_voltage')) c['pump'] = 0;
    if (cond.containsKey('over_current')) {
      c['pump'] = 0;
      c['cooling_fan'] = 0;
    }
    return c;
  }

  String _clearMessage(String key) {
    final v = values;
    if (key == 'temp') return '온실 온도 정상 복귀 (${_f(v['temperature']!, 1)}℃)';
    if (key.startsWith('part:')) {
      final p = key.substring(5);
      return '${_names[p]} 정상 복귀 (${_f(v[p]!, 1)}℃)';
    }
    return {
          'humidity_high': '습도 정상 복귀',
          'humidity_low': '습도 정상 복귀',
          'soil_dry': '토양수분 정상 복귀 (${_f(v['soil_moisture']!, 0)}%)',
          'co2': 'CO2 농도 정상 복귀 (${_f(v['co2']!, 0)}ppm)',
          'nutrient': '양분 정상 복귀',
          'low_voltage': '공급 전압 정상 복귀',
          'over_current': '전류 정상 복귀',
          'power_cut': '외부 전원 복구',
          'fan': '환풍기 경보 해소',
          'fan_backup': '예비 환풍기 정상',
          'intrusion': '야간 움직임 경보 해소',
        }[key] ??
        '$key 해소';
  }

  void _addEvent(
    DateTime now,
    int level,
    String type,
    String key,
    String? trap,
    String message,
    List<String> actions,
  ) {
    events.add({
      'id': nextEventId++,
      'time': _iso(now),
      'level': level,
      'type': type,
      'key': key,
      'trap': trap,
      'message': message,
      'actions': actions,
    });
    if (events.length > _maxEvents) {
      events.removeRange(0, events.length - _maxEvents);
    }
  }

  void _recordEvents(
    DateTime now,
    Map<String, Map<String, dynamic>> cond,
    List<String> changes,
    String? defaultMessage,
  ) {
    final auto = base['control_mode'] == 1;
    final newEvents = <(int, String, String, String?, String, List<String>)>[];
    for (final e in cond.entries) {
      final old = active[e.key];
      if (old == null || old['level'] != e.value['level']) {
        newEvents.add((
          e.value['level'] as int,
          'alarm',
          e.key,
          e.value['trap'] as String?,
          e.value['message'] as String,
          List<String>.of(e.value['guide'] as List<String>),
        ));
      }
    }
    for (final key in active.keys) {
      if (!cond.containsKey(key)) {
        newEvents.add((0, 'clear', key, 'alarmClear', _clearMessage(key), []));
        if (key == 'co2') sim.co2Source = false;
      }
    }
    for (final n in _notes) {
      newEvents.add((
        n.level,
        'info',
        n.key,
        null,
        n.message,
        List.of(n.guide),
      ));
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
      ));
    }
    // 긴급 경보가 맨 앞 (같은 등급은 원래 순서 유지)
    final ordered =
        [for (var i = 0; i < newEvents.length; i++) (i, newEvents[i])]..sort(
          (a, b) => b.$2.$1 != a.$2.$1
              ? b.$2.$1.compareTo(a.$2.$1)
              : a.$1.compareTo(b.$1),
        );
    for (var i = 0; i < ordered.length; i++) {
      final (level, type, key, trap, message, guide) = ordered[i].$2;
      final actions = <String>[];
      if (i == 0) {
        actions.addAll(changes);
        if (type == 'alarm' && level >= 2 && !auto && changes.isEmpty) {
          actions.add('수동 모드라 자동 조치를 하지 않았습니다');
        }
      }
      _addEvent(now, level, type, key, trap, message, [...actions, ...guide]);
    }
    active = cond;
  }

  // ===== 기록 (/api/history) =====
  void _maybeRecord(DateTime now) {
    if (_lastRecord != null &&
        now.difference(_lastRecord!).inSeconds < _recordSeconds) {
      return;
    }
    _lastRecord = now;
    final faults = sensorFaults();
    _readings.add((
      now,
      {
        for (final e in values.entries)
          e.key: faults.contains(e.key) ? null : _round(e.value, 2),
        'greenhouse_power': greenhousePower().toDouble(),
        'alarm_level': alarmLevel().toDouble(),
      },
    ));
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
      final t = start.add(
        Duration(
          milliseconds: ((current! * bucket + bucket / 2) * 1000).round(),
        ),
      );
      points.add({
        'time': _iso(t),
        'value': _round(vals.reduce((a, b) => a + b) / vals.length, 2),
      });
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

  // ===== API =====
  int alarmLevel() =>
      active.values.fold(0, (m, c) => math.max(m, c['level'] as int));

  bool commLost() {
    final until = sim.commLossUntil;
    if (until == null) return false;
    if (DateTime.now().millisecondsSinceEpoch / 1000 >= until) {
      sim.commLossUntil = null;
      return false;
    }
    return true;
  }

  Map<String, dynamic> _powerSummary() {
    final v = values, th = thresholds;
    return {
      'supply_voltage': _round(v['supply_voltage']!, 2),
      'supply_current': _round(v['supply_current']!, 2),
      'supply_power': _round(v['supply_voltage']! * v['supply_current']!, 2),
      'power_ok':
          !sim.powerCut &&
          v['supply_voltage']! >= th['voltage_low']! &&
          v['supply_current']! <= th['current_high']!,
      'greenhouse_power': greenhousePower(),
    };
  }

  Map<String, dynamic> status() {
    final faults = sensorFaults();
    double? val(String n, int d) =>
        faults.contains(n) ? null : _round(values[n]!, d);
    final sorted = active.values.toList()
      ..sort((a, b) => (b['level'] as int).compareTo(a['level'] as int));
    return {
      'time': _iso(DateTime.now()),
      'alarm_level': alarmLevel(),
      'alarm_message': sorted.isEmpty ? '' : sorted.first['message'],
      'conditions': [
        for (final c in sorted)
          {'key': c['key'], 'level': c['level'], 'message': c['message']},
      ],
      'sensors': {
        'temperature': val('temperature', 1),
        'humidity': val('humidity', 1),
        'soil_moisture': val('soil_moisture', 0),
        'co2': val('co2', 0),
        'nutrient_ec': val('nutrient_ec', 2),
      },
      'sensor_errors': faults.toList()..sort(),
      'power': _powerSummary(),
      'part_temps': {for (final p in _parts) p: val(p, 1)},
      'fans': {
        'main_ok': !fanFailed('main'),
        'backup_ok': !fanFailed('backup'),
        'failover': failoverLatched,
      },
      'control': Map.of(control),
      'night': {...settings, 'active': nightActive},
      'ai': Map.of(ai),
    };
  }

  Map<String, dynamic> power() => {
    'time': _iso(DateTime.now()),
    ..._powerSummary(),
    'voltage_low': thresholds['voltage_low'],
    'current_high': thresholds['current_high'],
    'greenhouse_energy_kwh': _round(energyWh / 1000, 3),
    'devices': [
      for (final e in _deviceWatts.entries)
        {
          'name': e.key,
          'label': _names[e.key],
          'watts': e.value,
          'on': _supplyDevices.contains(e.key)
              ? running(e.key)
              : control[e.key] != 0,
        },
    ],
  };

  Map<String, dynamic> updateThresholds(Map<String, dynamic> changes) {
    final next = Map.of(thresholds);
    for (final e in changes.entries) {
      if (!next.containsKey(e.key)) {
        throw DemoRmuError(400, '알 수 없는 임계값: ${e.key}');
      }
      if (e.value is! num) throw DemoRmuError(400, '${e.key}는 숫자여야 합니다');
      next[e.key] = (e.value as num).toDouble();
    }
    for (final (low, high) in [
      ('temp_low', 'temp_high'),
      ('humidity_low', 'humidity_high'),
      ('part_temp_low', 'part_temp_high'),
      ('cooling_setpoint', 'heating_setpoint'),
    ]) {
      if (next[low]! >= next[high]!) {
        throw DemoRmuError(400, '$low는 $high보다 작아야 합니다');
      }
    }
    for (final key in ['cooling_setpoint', 'heating_setpoint']) {
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
      if (!next.containsKey(e.key)) {
        throw DemoRmuError(400, '알 수 없는 설정: ${e.key}');
      }
      final v = e.value;
      if (v is! int) throw DemoRmuError(400, '${e.key}는 정수여야 합니다');
      if (e.key == 'night_mode' && v != 0 && v != 1) {
        throw DemoRmuError(400, 'night_mode는 0 또는 1입니다');
      }
      if (e.key != 'night_mode' && (v < 0 || v >= 24 * 60)) {
        throw DemoRmuError(400, '${e.key}는 0~1439(분) 사이여야 합니다');
      }
      next[e.key] = v;
    }
    if (next['night_start'] == next['night_end']) {
      throw DemoRmuError(400, '야간 시작과 종료 시각이 같을 수 없습니다');
    }
    settings = next;
    _evaluate(DateTime.now(), '야간 모드 설정 변경');
    return Map.of(settings);
  }

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
        if (value != 0 && value != 1) {
          throw DemoRmuError(400, '$device는 0 또는 1입니다');
        }
        base[device] = value as int;
      }
    } else {
      throw DemoRmuError(400, '알 수 없는 장치: $device');
    }
    _evaluate(DateTime.now(), '사용자 조작');
    return Map.of(control);
  }

  String simulate(String? name, Map<String, dynamic> params) {
    final s = sim;
    final severe = params['severe'] == true;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    switch (name) {
      case 'normal':
        final faultsOrComm =
            s.sensorFaults.isNotEmpty || s.commLossUntil != null;
        sim = DemoSim();
        base = Map.of(_defaultBase);
        savedBase = null;
        failoverLatched = false;
        pumpRetryAt = 0;
        values.addAll({
          'temperature': 25.0,
          'soil_moisture': 45.0,
          'co2': 450.0,
          'nutrient_ec': 1.8,
          'rmu_temp': 48.0,
          'main_fan_temp': 35.0,
          'backup_fan_temp': 28.0,
          'cooling_fan_temp': 28.0,
        });
        if (faultsOrComm) _notes.add(_Note(0, 'sim', '센서 오류·통신 두절 해제', []));
        return '모든 시뮬레이션과 장치 설정을 초기화했습니다. 다음 갱신에서 정상으로 돌아옵니다';
      case 'high_temp':
        s.heat = severe ? 0.8 : 0.3;
        s.aiBypass = true;
        return '고온 시작${severe ? ' (냉방으로도 못 막음 → 긴급 경보)' : ' (냉방 후 복구)'}, AI 선가동 끔';
      case 'slow_heat':
        s.heat = 0.2;
        s.aiBypass = false;
        return '온도가 서서히 오릅니다. AI가 상한 도달 전에 냉방을 시작하는지 확인하세요';
      case 'low_temp':
        s.heat = severe ? -1.2 : -0.6;
        return '저온 시작${severe ? ' (난방으로도 못 막음 → 긴급 경보)' : ' (난방 후 복구)'}';
      case 'part_high':
      case 'part_low':
        final part = (params['part'] as String?) ?? 'rmu_temp';
        if (!_parts.contains(part)) {
          throw DemoRmuError(400, 'part는 $_parts 중 하나입니다');
        }
        final load = severe ? 4.0 : 2.0;
        s.partLoad[part] = name == 'part_high' ? load : -load * 1.5;
        return '${_names[part]} ${name == 'part_high' ? '고온' : '저온'} 시작${severe ? ' (악화 → 긴급)' : ''}';
      case 'main_fan_fail':
        s.fanFailed['main'] = true;
        return '메인 환풍기 고장';
      case 'backup_fan_fail':
        s.fanFailed['backup'] = true;
        return '예비 환풍기 고장';
      case 'fans_fail':
        s.fanFailed = {'main': true, 'backup': true};
        return '메인·예비 환풍기 모두 고장';
      case 'fan_repair':
        s.fanFailed = {'main': false, 'backup': false};
        if (failoverLatched) {
          _notes.add(_Note(0, 'fan', '메인 환풍기 복구됨. 확인 후 메인으로 전환하세요', []));
        }
        return '환풍기 수리 완료 (메인 전환은 사용자가 확인 후 직접)';
      case 'soil_dry':
        values['soil_moisture'] = 30.0;
        s.pumpBlocked = severe;
        pumpRetryAt = 0;
        return '토양 건조${severe ? ' (물 공급 문제: 펌프 60초 후 정지)' : ' (펌프로 복구)'}';
      case 'low_voltage':
        s.voltageBase = 4.5;
        return '공급 전압 저하';
      case 'over_current':
        s.currentFault = 2.8;
        return '과전류';
      case 'power_cut':
        s.powerCut = true;
        return '외부 전원 차단';
      case 'power_restore':
        s.voltageBase = _defaultVoltage;
        s.currentFault = 0;
        s.powerCut = false;
        return '전원 정상화';
      case 'co2_high':
        s.co2Source = true;
        return 'CO2 농도 상승 (환기로 복구)';
      case 'nutrient_low':
        s.ecBase = 0.8;
        return '양분 부족';
      case 'nutrient_refill':
        s.ecBase = 1.8;
        return '양액 보충';
      case 'comm_loss':
        final seconds = (params['seconds'] as num?)?.toInt() ?? 30;
        s.commLossUntil = now + seconds;
        return '통신 두절 $seconds초 (그동안 데모 RMU가 응답하지 않습니다)';
      case 'comm_restore':
        s.commLossUntil = null;
        return '통신 복구';
      case 'sensor_fault':
        final sensor = (params['sensor'] as String?) ?? 'humidity';
        if (!_sensors.contains(sensor)) {
          throw DemoRmuError(400, 'sensor는 $_sensors 중 하나입니다');
        }
        s.sensorFaults.add(sensor);
        _notes.add(
          _Note(0, 'sensor_fault', '센서 오류: ${_names[sensor]}', [
            '센서 연결을 확인하세요',
          ]),
        );
        return '${_names[sensor]} 센서 오류';
      case 'sensor_restore':
        s.sensorFaults.clear();
        _notes.add(_Note(0, 'sensor_fault', '센서 정상 복구', []));
        return '센서 오류 해제';
      case 'night_on':
        s.nightOverride = true;
        return '야간 모드 강제 진입 (시계 무시)';
      case 'night_off':
        s.nightOverride = false;
        return '야간 모드 강제 해제 (시계 무시)';
      case 'night_auto':
        s.nightOverride = null;
        return '야간 모드를 설정 시각대로 동작';
      case 'motion':
        if (nightActive) {
          s.motionUntil = now + _motionAlarmSeconds;
          return '야간 움직임 감지';
        }
        _notes.add(_Note(0, 'motion', '주간 움직임 감지 (야간이 아니어서 경보 없음)', []));
        return '주간이라 경보 없음';
    }
    throw DemoRmuError(400, '알 수 없는 시나리오: $name');
  }

  // ===== REST 흉내: RmuApi가 HTTP 대신 부른다 =====
  Map<String, dynamic> handle(
    String method,
    String path,
    Object? body,
    String? token,
  ) {
    final uri = Uri.parse(path);
    final route = uri.path;
    final data = (body as Map<String, dynamic>?) ?? {};
    if (commLost() && route != '/api/simulate') {
      throw DemoRmuError(503, '통신 두절 (시뮬레이션)');
    }
    bool admin() => token != null && _tokens.contains(token);
    void requireAdmin() {
      if (!admin()) throw DemoRmuError(401, '로그인이 필요합니다');
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
      case ('GET', '/api/crops'):
        return {
          for (final e in _crops.entries)
            e.key: Map<String, dynamic>.of(e.value),
        };
      case ('GET', '/api/events'):
        final since = int.tryParse(uri.queryParameters['since'] ?? '0') ?? 0;
        return {
          'events': [
            for (final e in events)
              if ((e['id'] as int) > since) e,
          ],
          'last_id': nextEventId - 1,
        };
      case ('GET', '/api/history'):
        final sensor = uri.queryParameters['sensor'] ?? 'temperature';
        final range = uri.queryParameters['range'] ?? '1h';
        return {
          'sensor': sensor,
          'range': range,
          'points': history(sensor, range),
        };
      case ('GET', '/api/simulate'):
        return {'scenarios': demoScenarios, 'parts': _parts};
      case ('POST', '/api/login'):
        if (data['username'] == _demoAdmin['username'] &&
            data['password'] == _demoAdmin['password']) {
          final token = 'demo-${_rand.nextInt(1 << 32)}';
          _tokens.add(token);
          return {'token': token};
        }
        throw DemoRmuError(401, '아이디 또는 비밀번호가 틀렸습니다');
      case ('POST', '/api/simulate'):
        return {
          'ok': true,
          'scenario': data['scenario'],
          'message': simulate(data['scenario'] as String?, data),
        };
      case ('POST', '/api/control'):
        requireAdmin();
        return {
          'ok': true,
          'control': applyControl(data['device'] as String?, data['value']),
        };
      case ('PUT', '/api/thresholds'):
        requireAdmin();
        return updateThresholds(data);
      case ('PUT', '/api/settings'):
        requireAdmin();
        return updateSettings(data);
    }
    throw DemoRmuError(404, 'not found');
  }
}
