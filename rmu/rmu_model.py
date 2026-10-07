"""
모의 RMU의 상태와 규칙.

1초마다 tick()이 불리면 다음 순서로 처리한다.
  1) 센서 값 변화 (물리 흉내)
  2) 온도·부품 온도 상태 판정 (정상 → 경보 → 긴급)
  3) 알람 조건 판정 (등급, Trap 이름, 메시지)
  4) 펌프 타이머, 환풍기 이중화
  5) 장치 출력 계산: 사용자 설정(base) 위에 야간 모드·자동 조치·긴급 정지를 덮어쓴다
  6) 이벤트(알림)와 조치 내역 기록

장치 출력을 매번 base에서 다시 계산하기 때문에, 자동 조치가 끝나면
에어컨 설정온도 같은 값이 저장해 둔 원래 값(base)으로 자연스럽게 돌아간다.
"""

import random
import threading
from datetime import datetime

TICK_SECONDS = 1.0

# ---------------------------------------------------------------------------
# 기준값 (CLAUDE.md 10장. (제안)은 문서에 없어 임시로 정한 값)
# ---------------------------------------------------------------------------

DEFAULT_THRESHOLDS = {
    "temp_low": 15.0,          # ℃
    "temp_high": 30.0,         # ℃
    "humidity_low": 50.0,      # %
    "humidity_high": 85.0,     # %
    "soil_low": 35.0,          # %
    "voltage_low": 4.75,       # V
    "current_high": 3.0,       # A (제안, INA219 한도 3.2A보다 낮게)
    "co2_high": 1500,          # ppm (제안)
    "ec_low": 1.0,             # mS/cm (제안)
    "rmu_temp_high": 80.0,     # ℃
    "part_temp_high": 60.0,    # ℃ 환풍기·쿨링팬 장비 (제안)
    "part_temp_low": 0.0,      # ℃ 모든 부품 (제안)
    # 자동 조치 때 에어컨 설정온도 (작물마다 다름. 앱의 작물 기본값으로 바꾼다)
    "cooling_setpoint": 22.0,  # ℃ 고온 시 (제안)
    "heating_setpoint": 28.0,  # ℃ 저온 시 (제안)
}

# 복귀 여유(히스테리시스): 기준을 이만큼 넘어서 돌아와야 정상으로 본다
HYSTERESIS = {"temp": 2.0, "part": 5.0, "humidity": 2.0, "soil": 5.0,
              "co2": 300, "ec": 0.2, "voltage": 0.1, "current": 0.3}

# 자동 조치 후에도 이만큼 더 악화되면 긴급 경보
EMERGENCY_MARGIN = {"temp": 2.0, "part": 10.0}

PUMP_MAX_SECONDS = 60        # 토양 건조 시 펌프 최대 동작 시간
PUMP_RETRY_SECONDS = 600     # 60초 동작 후에도 건조하면 다시 돌리기까지 대기 (제안)
MOTION_ALARM_SECONDS = 30    # 야간 움직임 경보 유지 시간 (제안)

# AI 선가동 (제안. 모의 RMU는 시간이 빨리 흐르므로 실물에서는 늘려야 할 수 있음)
AI_WINDOW_SECONDS = 30       # 기울기를 구하는 최근 구간
AI_MIN_SAMPLES = 10          # 기울기를 믿기 위한 최소 측정 수
AI_LEAD_SECONDS = 120        # 이 시간 안에 상한 도달이 예상되면 미리 냉방
AI_MIN_SLOPE = 0.002         # ℃/초 (0.12℃/분) 이하 상승은 잡음으로 보고 무시
AI_MIN_HOLD_SECONDS = 60     # 한 번 시작하면 최소 유지 시간 (켜졌다 꺼졌다 반복 방지)
AI_RELEASE_MARGIN = 4.0      # 상한보다 이만큼 낮아지고 더 오르지 않으면 종료
MAX_EVENTS = 500

PARTS = ["rmu_temp", "main_fan_temp", "backup_fan_temp", "cooling_fan_temp"]
SENSORS = ["temperature", "humidity", "soil_moisture", "co2", "nutrient_ec"] + PARTS

NAMES = {
    "temperature": "온도", "humidity": "습도", "soil_moisture": "토양수분",
    "co2": "CO2", "nutrient_ec": "양분(EC)",
    "rmu_temp": "RMU 온도", "main_fan_temp": "메인 환풍기 온도",
    "backup_fan_temp": "예비 환풍기 온도", "cooling_fan_temp": "쿨링팬 온도",
    "main_fan": "메인 환풍기", "backup_fan": "예비 환풍기", "cooling_fan": "쿨링팬",
    "aircon": "에어컨", "heater": "히터", "pump": "펌프", "cover": "덮개", "lights": "전구",
}

# 외부 전원(INA219로 측정)에 연결된 릴레이 장치. 전원이 끊기면 멈춘다.
SUPPLY_DEVICES = ["main_fan", "backup_fan", "cooling_fan", "pump"]

# 온실 전체 사용 전력 시뮬레이션 (W)
DEVICE_WATTS = {"main_fan": 40, "backup_fan": 40, "cooling_fan": 30, "aircon": 1500,
                "heater": 2000, "pump": 60, "cover": 20, "lights": 300}
BASE_WATTS = 30  # CCTV, RMU 등 항상 켜진 장비

# 긴급 경보 시 정지할 장치 (CLAUDE.md 4장: 문제를 해결하는 장비는 유지, 나머지 정지)
#  - 고온 긴급: 에어컨·쿨링팬 유지. 환풍기도 열을 빼는 장비라 유지. 히터·전구·펌프 정지.
#  - 저온 긴급: 히터 유지. 에어컨·쿨링팬·환풍기·전구·펌프 정지.
HIGH_EMERGENCY_STOP = ["heater", "lights", "pump"]
LOW_EMERGENCY_STOP = ["aircon", "cooling_fan", "main_fan", "backup_fan", "lights", "pump"]

DEFAULT_BASE = {
    "main_fan": 1, "backup_fan": 0, "cooling_fan": 0,
    "aircon": 1, "aircon_setpoint": 25.0,
    "heater": 0, "pump": 0, "cover": 0, "lights": 1,
    "control_mode": 1,  # 0=수동 1=자동
}

DEFAULT_SETTINGS = {"night_mode": 1, "night_start": 21 * 60, "night_end": 6 * 60}
DEFAULT_VOLTAGE = 5.05  # 시뮬레이션 공급 전압 (V)


def clamp(v, low, high):
    return max(low, min(high, v))


def josa(word, with_batchim, without_batchim):
    """한글 조사 고르기: 쿨링팬을 / 히터를"""
    last = word[-1]
    if "가" <= last <= "힣" and (ord(last) - 0xAC00) % 28 != 0:
        return word + with_batchim
    return word + without_batchim


def in_night_window(minutes, start, end):
    """minutes(0~1439)가 야간 구간 안인가. 자정을 넘는 구간(예: 21:00~06:00)도 처리한다."""
    if start < end:
        return start <= minutes < end
    return minutes >= start or minutes < end


def describe_changes(before, after):
    """장치 상태 변화를 조치 내역 문장으로 바꾼다."""
    lines = []
    for key in before:
        b, a = before[key], after[key]
        if b == a:
            continue
        if key == "aircon_setpoint":
            verb = "낮췄습니다" if a < b else "높였습니다"
            lines.append(f"에어컨 설정온도를 {b:.1f}℃에서 {a:.1f}℃로 {verb}")
        elif key == "cover":
            lines.append("덮개를 닫아 햇빛을 차단했습니다" if a else "덮개를 열었습니다")
        elif key == "lights":
            lines.append("전구를 모두 켰습니다" if a else "전구를 모두 소등했습니다")
        elif key == "control_mode":
            lines.append("제어 모드를 자동으로 바꿨습니다" if a else "제어 모드를 수동으로 바꿨습니다")
        else:
            lines.append(josa(NAMES[key], "을", "를") + (" 켰습니다" if a else " 껐습니다"))
    return lines


class Sim:
    """시뮬레이션으로 주입한 상황 (POST /api/simulate)."""

    def __init__(self):
        self.heat = 0.0                                  # 온실 열 부하 (+ 고온, - 저온, ℃/초)
        self.part_load = {p: 0.0 for p in PARTS}         # 부품 열 부하
        self.fan_failed = {"main": False, "backup": False}
        self.pump_blocked = False                        # 물 공급 문제로 펌프를 돌려도 수분이 안 오름
        self.soil_override = False                       # 토양 건조 시뮬레이션 중 (실물 값 대신 사용)
        self.ai_bypass = False                           # 경보 시나리오 중에는 AI 선가동을 쓰지 않음
        self.co2_source = False
        self.ec_base = 1.8
        self.voltage_base = DEFAULT_VOLTAGE
        self.current_fault = 0.0
        self.power_cut = False
        self.comm_loss_until = None                      # 통신 두절 끝나는 시각 (timestamp)
        self.sensor_faults = set()
        self.night_override = None                       # None=시계대로, True/False=강제
        self.motion_until = 0.0


class RmuModel:
    def __init__(self, hardware=None, storage=None):
        """hardware: hardware.Hardware (라즈베리파이 실물). None이면 전부 시뮬레이션 (모의 RMU).
        storage: storage.Storage (2단계 SQLite 기록). None이면 이벤트를 메모리에만 둔다."""
        self.lock = threading.RLock()
        self.hardware = hardware
        self.storage = storage
        self.hw_faults = set()                # 실물 센서 읽기 실패 (센서 오류)
        self.hw_fan_failed = {}               # 실물 팬 회전 감지 결과 {"main_fan": True, ...}
        self.event_listeners = []             # 새 이벤트를 받을 함수들 (Trap 전송, 푸시 알림)
        self.temp_samples = []                # AI 선가동용 최근 온도 [(시각, 값)]
        self.ai_active = False
        self.ai_started = 0.0
        self.ai = {"active": False, "reason": "데이터 수집 중", "slope_per_min": None, "eta_seconds": None}
        self.values = {
            "temperature": 25.0, "humidity": 72.0, "soil_moisture": 45.0,
            "co2": 450.0, "nutrient_ec": 1.8,
            "supply_voltage": 5.05, "supply_current": 0.6,
            "rmu_temp": 48.0, "main_fan_temp": 35.0,
            "backup_fan_temp": 28.0, "cooling_fan_temp": 28.0,
        }
        self.base = dict(DEFAULT_BASE)        # 사용자가 정한 값 (자동 조치가 끝나면 이 값으로 복원)
        self.saved_base = None                # 수동 모드 전환 전 base
        self.manual_start = {}                # 수동 모드로 넘겨받은 장치 상태
        self.control = dict(DEFAULT_BASE)     # 실제 장치 출력
        self.thresholds = dict(DEFAULT_THRESHOLDS)
        self.settings = dict(DEFAULT_SETTINGS)
        self.sim = Sim()

        self.temp_state = "normal"            # normal / high / high_emergency / low / low_emergency
        self.part_states = {p: "normal" for p in PARTS}
        self.active = {}                      # 현재 알람 조건 {key: {...}}
        self.night_active = False
        self.failover_latched = False         # 메인→예비 전환 상태 (사용자가 확인해야 해제)
        self.pump_started_at = None
        self.pump_retry_at = 0.0
        self.energy_wh = 0.0
        self.events = []
        # 이벤트 번호는 DB에 이어서 매긴다 (재시작해도 번호가 겹치지 않게)
        self.next_event_id = (storage.last_event_id() + 1) if storage else 1
        self._notes = []                      # 이번 틱에 생긴 알림성 사건 (야간 진입 등)

    # =======================================================================
    # 1초마다 호출
    # =======================================================================
    def tick(self, now=None):
        now = now or datetime.now()
        with self.lock:
            self._update_physics()
            if self.hardware is not None:
                self._read_hardware()
            self._update_ai(now.timestamp())
            self._evaluate(now)
            if self.hardware is not None:
                self.hardware.apply(self.control)
            if self.storage is not None:
                self.storage.maybe_record(now, self.history_values())

    # -----------------------------------------------------------------------
    # AI 선가동 (시나리오 22, CLAUDE.md 8장)
    # 최근 AI_WINDOW초 온도의 기울기(최소제곱 직선)로 상한 도달 시각을 예측하고,
    # AI_LEAD초 안에 도달할 것 같으면 경보 전에 미리 냉방한다. 판단 이유는 항상 남긴다.
    # -----------------------------------------------------------------------
    def _update_ai(self, ts):
        temp = self.values["temperature"]
        high = self.thresholds["temp_high"]
        self.temp_samples.append((ts, temp))
        while self.temp_samples and ts - self.temp_samples[0][0] > AI_WINDOW_SECONDS:
            self.temp_samples.pop(0)

        slope = self._slope()  # ℃/초, 데이터가 부족하면 None
        eta = (high - temp) / slope if slope and slope > 0 and temp < high else None
        if slope is None:
            reason = "데이터 수집 중"
        elif eta is not None:
            reason = (f"최근 {AI_WINDOW_SECONDS}초 상승 속도 {slope * 60:.2f}℃/분, "
                      f"이대로면 약 {eta / 60:.1f}분 뒤 상한 {high:.1f}℃ 도달")
        else:
            reason = f"온도 변화 {slope * 60:+.2f}℃/분, 상한 도달 예상 없음"

        auto = self.base["control_mode"] == 1
        # 난방 중(저온·부품 저온 조치)에는 온도가 오르는 게 정상이므로 AI가 끼어들지 않는다
        heating = any(st in ("low", "low_emergency") for st in [self.temp_state, *self.part_states.values()])
        usable = (auto and not heating and not self.sim.ai_bypass
                  and "temperature" not in self.sensor_faults() and self.temp_state == "normal")
        if not self.ai_active:
            if usable and eta is not None and eta <= AI_LEAD_SECONDS and slope >= AI_MIN_SLOPE:
                self.ai_active = True
                self.ai_started = ts
                self._notes.append((0, "ai", "AI 선가동: 상한 도달 전에 냉방을 시작합니다", [f"판단 이유: {reason}"]))
        elif not usable:
            self.ai_active = False  # 수동 모드, 센서 오류, 또는 이미 경보 (경보 규칙이 맡는다)
        elif ts - self.ai_started >= AI_MIN_HOLD_SECONDS and temp <= high - AI_RELEASE_MARGIN and slope is not None and slope <= 0:
            self.ai_active = False
            self.sim.heat = 0.0  # 시나리오 종료
            self._notes.append((0, "ai", "AI 선가동 종료: 온도가 안정되었습니다", [f"판단 이유: {reason}"]))

        self.ai = {"active": self.ai_active, "reason": reason,
                   "slope_per_min": None if slope is None else round(slope * 60, 2),
                   "eta_seconds": None if eta is None else round(eta)}

    def _slope(self):
        pts = self.temp_samples
        if len(pts) < AI_MIN_SAMPLES:
            return None
        n = len(pts)
        mean_t = sum(t for t, _ in pts) / n
        mean_v = sum(v for _, v in pts) / n
        den = sum((t - mean_t) ** 2 for t, _ in pts)
        if den == 0:
            return None
        return sum((t - mean_t) * (v - mean_v) for t, v in pts) / den

    def history_values(self):
        """기록할 값 (센서 오류는 None)"""
        faults = self.sensor_faults()
        row = {k: (None if k in faults else round(v, 2)) for k, v in self.values.items()}
        row["greenhouse_power"] = self.greenhouse_power()
        row["alarm_level"] = self.alarm_level()
        return row

    def _simulated_sensors(self):
        """지금 시뮬레이션이 값을 움직이고 있는 센서. 실물이 있어도 이 센서들은 시뮬레이션 값을 쓴다."""
        s = self.sim
        names = set()
        if s.heat:  # 열 부하 시나리오 중 (정상 복귀하면 0이 되어 다시 실물 값)
            names.add("temperature")
        if s.soil_override:
            names.add("soil_moisture")
        if s.power_cut or s.current_fault or s.voltage_base != DEFAULT_VOLTAGE:
            names.update(["supply_voltage", "supply_current"])
        names.update(p for p, load in s.part_load.items() if load)
        return names

    def _read_hardware(self):
        """라즈베리파이 실물 값으로 바꿔 넣는다 (1단계)."""
        readings = self.hardware.read()
        simulated = self._simulated_sensors()
        self.hw_faults = set()
        for name, value in readings.items():
            if value is None:
                self.hw_faults.add(name)  # 읽기 실패 → 센서 오류 표시 (값은 마지막 값 유지)
            elif name not in simulated:
                self.values[name] = value
        self.hw_fan_failed = self.hardware.fan_failures(self.control)

    def fan_failed(self, which):
        """which: 'main' / 'backup'. 시뮬레이션 고장 또는 실물 회전 감지 고장"""
        return self.sim.fan_failed[which] or self.hw_fan_failed.get(f"{which}_fan", False)

    def sensor_faults(self):
        return self.sim.sensor_faults | self.hw_faults

    def _evaluate(self, now, default_message=None):
        """상태 판정 → 장치 출력 → 이벤트 기록"""
        ts = now.timestamp()
        self._update_temp_states()
        self._update_night(now)
        conditions = self._evaluate_conditions(ts)
        self._update_pump(ts, conditions)
        self._update_failover()
        before = dict(self.control)
        self.control = self._compute_outputs(conditions)
        changes = describe_changes(before, self.control)
        self._record_events(now, conditions, changes, default_message)

    # -----------------------------------------------------------------------
    # 1) 센서 값 변화
    # -----------------------------------------------------------------------
    def running(self, device):
        """장치가 실제로 돌고 있는가 (명령 + 고장 + 전원 반영)"""
        if not self.control[device]:
            return False
        if device in SUPPLY_DEVICES and self.sim.power_cut:
            return False
        if device == "main_fan" and self.fan_failed("main"):
            return False
        if device == "backup_fan" and self.fan_failed("backup"):
            return False
        return True

    def _update_physics(self):
        v, c, s = self.values, self.control, self.sim

        # 온실 온도: 열 부하 + 에어컨(설정온도 쪽으로 당김) + 쿨링팬·히터·환기
        dt = s.heat + random.uniform(-0.05, 0.05)
        if self.running("aircon"):
            dt += 0.03 * (c["aircon_setpoint"] - v["temperature"])
        if self.running("cooling_fan"):
            dt -= 0.2
        if self.running("heater"):
            dt += 0.4
        if self.running("backup_fan"):
            dt -= 0.05
        v["temperature"] = clamp(v["temperature"] + dt, -20, 60)

        # 부품 온도: 기준 온도 쪽으로 돌아가려 하고, 쿨링팬은 식히고 히터는 데운다
        for p in PARTS:
            if p == "rmu_temp":
                base = 48.0
            else:
                device = p.replace("_temp", "")
                base = 35.0 if self.running(device) else 28.0
            t = v[p]
            d = s.part_load[p] - 0.05 * (t - base) + random.uniform(-0.1, 0.1)
            if self.running("cooling_fan") and t > base:
                d -= 1.5
            if self.running("heater") and t < base:
                d += 2.0
            v[p] = clamp(t + d, -60, 150)

        v["humidity"] = clamp(v["humidity"] + 0.1 * (72 - v["humidity"]) + random.uniform(-0.5, 0.5), 0, 100)

        # 토양수분: 펌프가 돌면 오른다 (물 공급 문제면 안 오름)
        pump_effect = 0.5 if self.running("pump") and not s.pump_blocked else 0.0
        v["soil_moisture"] = clamp(
            v["soil_moisture"] + pump_effect + 0.002 * (45 - v["soil_moisture"]) + random.uniform(-0.1, 0.1),
            0, 100)

        # CO2: 발생원이 있으면 오르고, 예비 환풍기까지 돌리면(환기 강화) 내려간다
        dco2 = 0.02 * (450 - v["co2"]) + random.uniform(-5, 5)
        if s.co2_source:
            dco2 += 80
        if self.running("backup_fan"):
            dco2 -= 120
        v["co2"] = clamp(v["co2"] + dco2, 300, 5000)

        v["nutrient_ec"] = clamp(v["nutrient_ec"] + 0.1 * (s.ec_base - v["nutrient_ec"])
                                 + random.uniform(-0.02, 0.02), 0, 5)

        # 공급 전원 (INA219)
        if s.power_cut:
            v["supply_voltage"] = 0.0
            v["supply_current"] = 0.0
        else:
            v["supply_voltage"] += 0.3 * (s.voltage_base - v["supply_voltage"]) + random.uniform(-0.01, 0.01)
            target = (0.4 + 0.2 * self.running("main_fan") + 0.2 * self.running("backup_fan")
                      + 0.3 * self.running("cooling_fan") + 0.5 * self.running("pump") + s.current_fault)
            v["supply_current"] += 0.3 * (target - v["supply_current"]) + random.uniform(-0.02, 0.02)
            v["supply_current"] = max(0.0, v["supply_current"])

        self.energy_wh += self.greenhouse_power() * TICK_SECONDS / 3600

    def greenhouse_power(self):
        """온실 전체 사용 전력 (W, 시뮬레이션)"""
        return BASE_WATTS + sum(w for d, w in DEVICE_WATTS.items() if self.running(d))

    # -----------------------------------------------------------------------
    # 2) 온도 상태 판정 (정상 → 경보 → 긴급)
    # -----------------------------------------------------------------------
    @staticmethod
    def _next_state(state, value, low, high, hyst, margin, auto):
        if state == "normal":
            if value > high:
                return "high"
            if value < low:
                return "low"
        elif state in ("high", "high_emergency"):
            if value <= high - hyst:
                return "normal"
            # 자동 조치(냉방)를 했는데도 더 오르면 긴급. 수동 모드는 조치가 없으므로 경보 유지.
            if state == "high" and auto and value > high + margin:
                return "high_emergency"
        elif state in ("low", "low_emergency"):
            if value >= low + hyst:
                return "normal"
            if state == "low" and auto and value < low - margin:
                return "low_emergency"
        return state

    def _update_temp_states(self):
        th, auto, s = self.thresholds, self.base["control_mode"] == 1, self.sim
        faults = self.sensor_faults()
        if "temperature" not in faults:
            new = self._next_state(self.temp_state, self.values["temperature"], th["temp_low"],
                                   th["temp_high"], HYSTERESIS["temp"], EMERGENCY_MARGIN["temp"], auto)
            if new == "normal" and self.temp_state != "normal":
                s.heat = 0.0  # 시나리오 종료: 정상으로 돌아오면 열 부하도 사라진 것으로 본다
                s.ai_bypass = False
            self.temp_state = new
        for p in PARTS:
            if p in faults:
                continue
            high = th["rmu_temp_high"] if p == "rmu_temp" else th["part_temp_high"]
            new = self._next_state(self.part_states[p], self.values[p], th["part_temp_low"], high,
                                   HYSTERESIS["part"], EMERGENCY_MARGIN["part"], auto)
            if new == "normal" and self.part_states[p] != "normal":
                s.part_load[p] = 0.0
            self.part_states[p] = new

    def _update_night(self, now):
        s = self.sim
        if s.night_override is not None:
            night = s.night_override
        elif self.settings["night_mode"]:
            night = in_night_window(now.hour * 60 + now.minute,
                                    self.settings["night_start"], self.settings["night_end"])
        else:
            night = False
        if night != self.night_active:
            self._notes.append((0, "night", "야간 모드 진입" if night else "야간 모드 해제", []))
        self.night_active = night

    # -----------------------------------------------------------------------
    # 3) 알람 조건 판정
    # -----------------------------------------------------------------------
    def _evaluate_conditions(self, ts):
        v, th, s = self.values, self.thresholds, self.sim
        auto = self.base["control_mode"] == 1
        prev = self.active
        cond = {}

        def add(key, level, trap, message, guide=None):
            cond[key] = {"key": key, "level": level, "trap": trap, "message": message, "guide": guide or []}

        def hyst(key, enter, stay):
            """이미 켜진 조건은 stay 조건으로 유지, 아니면 enter 조건으로 시작"""
            return stay if key in prev else enter

        # 온실 온도
        t = v["temperature"]
        state = self.temp_state
        if state == "high":
            add("temp", 2, "highTempAlarm", f"온실 온도 상한 초과 ({t:.1f}℃ > {th['temp_high']:.1f}℃)")
        elif state == "high_emergency":
            add("temp", 3, "emergencyAlarm", f"긴급: 냉방 후에도 온도 상승 ({t:.1f}℃)")
        elif state == "low":
            add("temp", 2, "lowTempAlarm", f"온실 온도 하한 미만 ({t:.1f}℃ < {th['temp_low']:.1f}℃)")
        elif state == "low_emergency":
            add("temp", 3, "emergencyAlarm", f"긴급: 난방 후에도 온도 하락 ({t:.1f}℃)")
        if state != "normal" and self.night_active:
            cond["temp"]["guide"].append("야간이지만 온도 경보를 우선합니다. 환기를 먼저 가동하고 전구는 소등을 유지합니다")

        # 부품 온도 (1단계 주의, 악화 시 긴급)
        for p in PARTS:
            ps, pv = self.part_states[p], v[p]
            if ps == "high":
                add(f"part:{p}", 1, "partTempAlarm", f"{NAMES[p]} 기준 초과 ({pv:.1f}℃)")
            elif ps == "high_emergency":
                add(f"part:{p}", 3, "emergencyAlarm", f"긴급: 냉각 후에도 {NAMES[p]} 상승 ({pv:.1f}℃)")
            elif ps == "low":
                add(f"part:{p}", 1, "partTempAlarm", f"{NAMES[p]} 기준 미만 ({pv:.1f}℃)")
            elif ps == "low_emergency":
                add(f"part:{p}", 3, "emergencyAlarm", f"긴급: 난방 후에도 {NAMES[p]} 하락 ({pv:.1f}℃)")

        faults = self.sensor_faults()
        h = v["humidity"]
        if "humidity" not in faults:
            if hyst("humidity_high", h > th["humidity_high"], h > th["humidity_high"] - HYSTERESIS["humidity"]):
                # 습도용 Trap은 아직 정의되지 않음 (CLAUDE.md 5장 Notification 목록)
                add("humidity_high", 2, None, f"습도 상한 초과 ({h:.1f}%)", ["환기를 확인하세요"])
            if hyst("humidity_low", h < th["humidity_low"], h < th["humidity_low"] + HYSTERESIS["humidity"]):
                add("humidity_low", 2, None, f"습도 하한 미만 ({h:.1f}%)")

        soil = v["soil_moisture"]
        if "soil_moisture" not in faults and hyst("soil_dry", soil < th["soil_low"],
                                                   soil < th["soil_low"] + HYSTERESIS["soil"]):
            add("soil_dry", 2, "dryAlarm", f"토양 건조 ({soil:.0f}% < {th['soil_low']:.0f}%)")

        co2 = v["co2"]
        if "co2" not in faults and hyst("co2", co2 > th["co2_high"], co2 > th["co2_high"] - HYSTERESIS["co2"]):
            add("co2", 2, "co2HighAlarm", f"CO2 농도 높음 ({co2:.0f}ppm)")

        ec = v["nutrient_ec"]
        if "nutrient_ec" not in faults and hyst("nutrient", ec < th["ec_low"], ec < th["ec_low"] + HYSTERESIS["ec"]):
            add("nutrient", 2, "nutrientLowAlarm", f"양분 부족 (EC {ec:.2f}mS/cm)", ["양액을 보충하세요"])

        # 공급 전원
        volt, cur = v["supply_voltage"], v["supply_current"]
        if s.power_cut or volt < 1.0:
            add("power_cut", 3, "powerCutAlarm", "외부 전원 차단",
                ["환풍기·쿨링팬·펌프가 멈춘 상태입니다. 외부 전원을 확인하세요"])
        elif hyst("low_voltage", volt < th["voltage_low"], volt < th["voltage_low"] + HYSTERESIS["voltage"]):
            add("low_voltage", 2, "lowVoltageAlarm", f"공급 전압 저하 ({volt:.2f}V)",
                ["전압이 회복될 때까지 펌프 사용을 제한합니다"])
        if hyst("over_current", cur > th["current_high"], cur > th["current_high"] - HYSTERESIS["current"]):
            add("over_current", 2, "overCurrentAlarm", f"과전류 ({cur:.2f}A)",
                ["펌프와 쿨링팬을 차단합니다. 배선과 장치를 점검하세요"])

        # 환풍기 이중화
        main_bad, backup_bad = self.fan_failed("main"), self.fan_failed("backup")
        if main_bad and backup_bad:
            add("fan", 3, "emergencyAlarm", "긴급: 메인·예비 환풍기 모두 고장 (대체 수단 없음)",
                ["환풍기를 즉시 점검하세요"])
        elif main_bad:
            if auto:
                add("fan", 2, "ventFailover", "메인 환풍기 고장, 예비 환풍기로 대체")
            else:
                add("fan", 2, "ventFailover", "메인 환풍기 고장", ["수동 모드입니다. 예비 환풍기를 직접 켜세요"])
        elif backup_bad:
            add("fan_backup", 1, "ventFailover", "예비 환풍기 고장 (메인은 정상)")

        # 야간 움직임 감지
        if self.night_active and ts < s.motion_until:
            add("intrusion", 2, "nightIntrusionAlarm", "야간 CCTV 움직임 감지", ["CCTV를 확인하세요"])

        return cond

    # -----------------------------------------------------------------------
    # 4) 펌프 타이머, 환풍기 이중화
    # -----------------------------------------------------------------------
    def _update_pump(self, ts, cond):
        auto = self.base["control_mode"] == 1
        dry = "soil_dry" in cond
        if self.pump_started_at is None:
            if auto and dry and ts >= self.pump_retry_at:
                self.pump_started_at = ts
        elif not auto or not dry:
            self.pump_started_at = None  # 수분이 회복되면 바로 정지
        elif ts - self.pump_started_at >= PUMP_MAX_SECONDS:
            self.pump_started_at = None
            self.pump_retry_at = ts + PUMP_RETRY_SECONDS
            self._notes.append((2, "pump", f"펌프 최대 {PUMP_MAX_SECONDS}초 동작 후 정지 (토양수분이 아직 낮음)",
                                ["물 공급 상태를 확인하세요"]))

    def _update_failover(self):
        # 메인이 고장 나면 예비로 전환하고, 메인이 고쳐져도 자동으로 되돌리지 않는다 (사용자 확인 후 전환)
        if self.base["control_mode"] == 1 and self.fan_failed("main") and self.base["main_fan"]:
            self.failover_latched = True

    # -----------------------------------------------------------------------
    # 5) 장치 출력 계산
    # -----------------------------------------------------------------------
    def _compute_outputs(self, cond):
        c = dict(self.base)

        # 야간 모드: 덮개를 닫아 햇빛 차단, 전구 모두 소등 (해제되면 base 값으로 복원)
        if self.night_active:
            c["cover"] = 1
            c["lights"] = 0

        if c["control_mode"] != 1:
            return c  # 수동 모드: 자동 조치 없음

        parts = self.part_states.values()
        cooling = self.ai_active or self.temp_state in ("high", "high_emergency") or any(
            p in ("high", "high_emergency") for p in parts)
        heating = self.temp_state in ("low", "low_emergency") or any(
            p in ("low", "low_emergency") for p in parts)

        if cooling:
            # 고온: 에어컨 설정온도를 낮추고 쿨링팬 on
            c["aircon"] = 1
            c["aircon_setpoint"] = min(c["aircon_setpoint"], self.thresholds["cooling_setpoint"])
            c["cooling_fan"] = 1
        elif heating:
            # 저온: 히터 on, 에어컨이 켜져 있으면 설정온도를 올린다
            c["heater"] = 1
            if c["aircon"]:
                c["aircon_setpoint"] = max(c["aircon_setpoint"], self.thresholds["heating_setpoint"])

        # 환기 강화 (예비 환풍기 추가 가동): CO2 높음, 야간 중 온도 경보(환기 우선)
        if "co2" in cond or (self.night_active and self.temp_state != "normal"):
            c["backup_fan"] = 1

        # 환풍기 이중화: 메인 고장 → 예비로 대체
        if self.failover_latched:
            c["main_fan"] = 0
            c["backup_fan"] = 1

        if self.pump_started_at is not None:
            c["pump"] = 1

        # 긴급 경보: 문제를 해결하는 장비만 남기고 정지
        states = [self.temp_state, *parts]
        if "high_emergency" in states:
            for d in HIGH_EMERGENCY_STOP:
                c[d] = 0
        elif "low_emergency" in states:
            for d in LOW_EMERGENCY_STOP:
                c[d] = 0

        # 전기 보호가 가장 우선
        if "low_voltage" in cond:
            c["pump"] = 0
        if "over_current" in cond:
            c["pump"] = 0
            c["cooling_fan"] = 0
        return c

    # -----------------------------------------------------------------------
    # 6) 이벤트(알림)와 조치 내역
    # -----------------------------------------------------------------------
    def _clear_message(self, key):
        v = self.values
        if key == "temp":
            return f"온실 온도 정상 복귀 ({v['temperature']:.1f}℃)"
        if key.startswith("part:"):
            p = key[5:]
            return f"{NAMES[p]} 정상 복귀 ({v[p]:.1f}℃)"
        return {
            "humidity_high": "습도 정상 복귀", "humidity_low": "습도 정상 복귀",
            "soil_dry": f"토양수분 정상 복귀 ({v['soil_moisture']:.0f}%)",
            "co2": f"CO2 농도 정상 복귀 ({v['co2']:.0f}ppm)",
            "nutrient": "양분 정상 복귀", "low_voltage": "공급 전압 정상 복귀",
            "over_current": "전류 정상 복귀", "power_cut": "외부 전원 복구",
            "fan": "환풍기 경보 해소", "fan_backup": "예비 환풍기 정상",
            "intrusion": "야간 움직임 경보 해소",
        }.get(key, f"{key} 해소")

    def _add_event(self, now, level, etype, key, trap, message, actions):
        event = {
            "id": self.next_event_id,
            "time": now.isoformat(timespec="seconds"),
            "level": level, "type": etype, "key": key, "trap": trap,
            "message": message, "actions": actions,
        }
        self.next_event_id += 1
        self.events.append(event)
        del self.events[:-MAX_EVENTS]
        if self.storage is not None:
            self.storage.add_event(event)
        print(f"[{event['time']}] #{event['id']} 등급 {level} {etype:<7} | {message}"
              + (" | " + " / ".join(actions) if actions else ""))
        for listener in self.event_listeners:
            listener(event)  # SNMP Trap, 푸시 알림
        return event

    def _record_events(self, now, cond, changes, default_message):
        auto = self.base["control_mode"] == 1
        new_events = []  # (level, type, key, trap, message, guide)

        for key, c in cond.items():
            old = self.active.get(key)
            if old is None or old["level"] != c["level"]:
                new_events.append((c["level"], "alarm", key, c["trap"], c["message"], list(c["guide"])))
        for key, old in self.active.items():
            if key not in cond:
                new_events.append((0, "clear", key, "alarmClear", self._clear_message(key), []))
                if key == "co2":
                    self.sim.co2_source = False  # 환기로 정상 복귀하면 시나리오 종료
                if key == "soil_dry":
                    self.sim.soil_override = False  # 실물이면 다시 센서 값 사용
        for level, key, message, guide in self._notes:
            new_events.append((level, "info", key, None, message, list(guide)))
        self._notes = []

        if not new_events and changes:
            new_events.append((0, "control" if default_message else "action", "control", None,
                               default_message or "자동 조치", []))

        # 긴급 경보가 맨 앞: 알림을 먼저 보내고, 장치 정리 내역은 그 알림 상세에 남긴다
        new_events.sort(key=lambda e: -e[0])
        for i, (level, etype, key, trap, message, guide) in enumerate(new_events):
            actions = []
            if i == 0:
                actions = list(changes)
                if etype == "alarm" and level >= 2 and not auto and not changes:
                    actions.append("수동 모드라 자동 조치를 하지 않았습니다")
            self._add_event(now, level, etype, key, trap, message, actions + guide)

        self.active = cond

    # =======================================================================
    # API에서 쓰는 함수 (server가 호출)
    # =======================================================================
    def alarm_level(self):
        return max((c["level"] for c in self.active.values()), default=0)

    def comm_lost(self):
        until = self.sim.comm_loss_until
        if until is None:
            return False
        if datetime.now().timestamp() >= until:
            self.sim.comm_loss_until = None
            return False
        return True

    def status(self):
        with self.lock:
            v, faults = self.values, self.sensor_faults()
            top = max(self.active.values(), key=lambda c: c["level"], default=None)

            def val(name, digits):
                return None if name in faults else round(v[name], digits)

            return {
                "time": datetime.now().isoformat(timespec="seconds"),
                "alarm_level": self.alarm_level(),
                "alarm_message": top["message"] if top else "",
                "conditions": [{"key": c["key"], "level": c["level"], "message": c["message"]}
                               for c in sorted(self.active.values(), key=lambda c: -c["level"])],
                "sensors": {
                    "temperature": val("temperature", 1),
                    "humidity": val("humidity", 1),
                    "soil_moisture": val("soil_moisture", 0),
                    "co2": val("co2", 0),
                    "nutrient_ec": val("nutrient_ec", 2),
                },
                "sensor_errors": sorted(faults),
                "power": self._power_summary(),
                "part_temps": {p: val(p, 1) for p in PARTS},
                "fans": {"main_ok": not self.fan_failed("main"),
                         "backup_ok": not self.fan_failed("backup"),
                         "failover": self.failover_latched},
                "control": dict(self.control),
                "night": {**self.settings, "active": self.night_active},
                "ai": dict(self.ai),  # AI 선가동 상태와 판단 이유 (화면에 항상 표시)
            }

    def _power_summary(self):
        v, th = self.values, self.thresholds
        return {
            "supply_voltage": round(v["supply_voltage"], 2),
            "supply_current": round(v["supply_current"], 2),
            "supply_power": round(v["supply_voltage"] * v["supply_current"], 2),
            # 홈 화면용 정상/이상
            "power_ok": (not self.sim.power_cut and v["supply_voltage"] >= th["voltage_low"]
                         and v["supply_current"] <= th["current_high"]),
            "greenhouse_power": self.greenhouse_power(),
        }

    def power(self):
        with self.lock:
            th = self.thresholds
            return {
                "time": datetime.now().isoformat(timespec="seconds"),
                **self._power_summary(),
                "voltage_low": th["voltage_low"],
                "current_high": th["current_high"],
                "greenhouse_energy_kwh": round(self.energy_wh / 1000, 3),
                "devices": [{"name": d, "label": NAMES[d], "watts": w,
                             "on": bool(self.running(d) if d in SUPPLY_DEVICES else self.control[d])}
                            for d, w in DEVICE_WATTS.items()],
            }

    def get_events(self, since):
        if self.storage is not None:
            return self.storage.events_since(since)
        with self.lock:
            return [e for e in self.events if e["id"] > since]

    def history(self, sensor, range_name):
        if self.storage is None:
            raise ValueError("기록 저장(SQLite)을 쓰지 않는 서버입니다")
        return self.storage.history(sensor, range_name)

    def update_thresholds(self, changes):
        with self.lock:
            new = dict(self.thresholds)
            for key, value in changes.items():
                if key not in new:
                    raise ValueError(f"알 수 없는 임계값: {key}")
                if not isinstance(value, (int, float)) or isinstance(value, bool):
                    raise ValueError(f"{key}는 숫자여야 합니다")
                new[key] = float(value)
            for low, high in [("temp_low", "temp_high"), ("humidity_low", "humidity_high"),
                              ("part_temp_low", "part_temp_high"), ("cooling_setpoint", "heating_setpoint")]:
                if new[low] >= new[high]:
                    raise ValueError(f"{low}는 {high}보다 작아야 합니다")
            for key in ("cooling_setpoint", "heating_setpoint"):
                if not 16 <= new[key] <= 30:
                    raise ValueError(f"{key}는 16~30℃입니다 (에어컨 설정 범위)")
            self.thresholds = new
            self._evaluate(datetime.now(), "임계값 변경")
            return dict(self.thresholds)

    def update_settings(self, changes):
        with self.lock:
            new = dict(self.settings)
            for key, value in changes.items():
                if key not in new:
                    raise ValueError(f"알 수 없는 설정: {key}")
                if not isinstance(value, int) or isinstance(value, bool):
                    raise ValueError(f"{key}는 정수여야 합니다")
                if key == "night_mode" and value not in (0, 1):
                    raise ValueError("night_mode는 0 또는 1입니다")
                if key in ("night_start", "night_end") and not 0 <= value < 24 * 60:
                    raise ValueError(f"{key}는 0~1439(분) 사이여야 합니다")
                new[key] = value
            if new["night_start"] == new["night_end"]:
                raise ValueError("야간 시작과 종료 시각이 같을 수 없습니다")
            self.settings = new
            self._evaluate(datetime.now(), "야간 모드 설정 변경")
            return dict(self.settings)

    def apply_control(self, device, value):
        """사용자 조작. 문제가 있으면 (http 코드, 메시지)를 담은 ControlError를 던진다."""
        with self.lock:
            auto = self.base["control_mode"] == 1
            if device == "control_mode":
                if value not in (0, 1):
                    raise ControlError(400, "control_mode는 0(수동) 또는 1(자동)입니다")
                if value == 0 and auto:
                    # 수동으로 바꿀 때 지금 장치 상태를 그대로 이어받는다 (갑자기 바뀌지 않게).
                    # 자동으로 돌아올 때 되돌리기 위해 원래 설정과 넘겨받은 상태를 저장한다.
                    self.saved_base = dict(self.base)
                    self.base = dict(self.control)
                    if self.night_active:  # 야간 덮개·전구는 야간 모드가 따로 처리
                        self.base["cover"] = self.saved_base["cover"]
                        self.base["lights"] = self.saved_base["lights"]
                    self.manual_start = dict(self.base)
                    self.pump_started_at = None
                elif value == 1 and not auto and self.saved_base is not None:
                    # 자동으로 돌아올 때: 수동 중 사용자가 직접 바꾼 장치는 그 값을 유지하고,
                    # 손대지 않은 장치는 원래 설정으로 되돌린다 (자동 조치 값이 굳지 않게)
                    for k in self.base:
                        if self.base[k] == self.manual_start[k]:
                            self.base[k] = self.saved_base[k]
                    self.saved_base = None
                self.base["control_mode"] = value
            elif device == "restore_main_fan":
                # 메인 환풍기 복구 확인 → 메인으로 되돌린다
                if self.fan_failed("main"):
                    raise ControlError(409, "메인 환풍기가 아직 고장 상태입니다")
                if not self.failover_latched:
                    raise ControlError(409, "예비 환풍기로 대체 중이 아닙니다")
                self.failover_latched = False
            elif device in self.base:
                if auto:
                    raise ControlError(409, "자동 모드에서는 수동 조작이 잠겨 있습니다. 제어 모드를 수동으로 바꾸세요")
                if device == "aircon_setpoint":
                    if not isinstance(value, (int, float)) or not 16 <= value <= 30:
                        raise ControlError(400, "에어컨 설정온도는 16~30℃입니다")
                    value = float(value)
                elif value not in (0, 1):
                    raise ControlError(400, f"{device}는 0 또는 1입니다")
                self.base[device] = value
            else:
                raise ControlError(400, f"알 수 없는 장치: {device}")
            self._evaluate(datetime.now(), "사용자 조작")
            return dict(self.control)

    # -----------------------------------------------------------------------
    # 시뮬레이션 (POST /api/simulate)
    # -----------------------------------------------------------------------
    def simulate(self, name, params):
        with self.lock:
            s = self.sim
            severe = bool(params.get("severe"))
            now = datetime.now()

            if name == "normal":
                faults_or_comm = s.sensor_faults or s.comm_loss_until
                self.sim = Sim()
                self.base = dict(DEFAULT_BASE)  # 장치 설정도 기본값으로 (시연 초기화)
                self.saved_base = None
                self.failover_latched = False
                self.pump_retry_at = 0.0
                self.values.update({"temperature": 25.0, "soil_moisture": 45.0, "co2": 450.0,
                                    "nutrient_ec": 1.8, "rmu_temp": 48.0, "main_fan_temp": 35.0,
                                    "backup_fan_temp": 28.0, "cooling_fan_temp": 28.0})
                if faults_or_comm:
                    self._notes.append((0, "sim", "센서 오류·통신 두절 해제", []))
                return "모든 시뮬레이션과 장치 설정을 초기화했습니다. 다음 갱신에서 정상으로 돌아옵니다"
            if name == "high_temp":
                s.heat = 0.8 if severe else 0.3
                s.ai_bypass = True  # 경보 흐름을 보여주는 시나리오라 AI 선가동은 끄고 진행
                return "고온 시작" + (" (냉방으로도 못 막음 → 긴급 경보)" if severe else " (냉방 후 복구)") + ", AI 선가동 끔"
            if name == "slow_heat":
                s.heat = 0.2
                s.ai_bypass = False
                return "온도가 서서히 오릅니다. AI가 상한 도달 전에 냉방을 시작하는지 확인하세요"
            if name == "low_temp":
                s.heat = -1.2 if severe else -0.6
                return "저온 시작" + (" (난방으로도 못 막음 → 긴급 경보)" if severe else " (난방 후 복구)")
            if name in ("part_high", "part_low"):
                part = params.get("part", "rmu_temp")
                if part not in PARTS:
                    raise ValueError(f"part는 {PARTS} 중 하나입니다")
                load = 4.0 if severe else 2.0
                s.part_load[part] = load if name == "part_high" else -load * 1.5
                return f"{NAMES[part]} {'고온' if name == 'part_high' else '저온'} 시작" + (" (악화 → 긴급)" if severe else "")
            if name == "main_fan_fail":
                s.fan_failed["main"] = True
                return "메인 환풍기 고장"
            if name == "backup_fan_fail":
                s.fan_failed["backup"] = True
                return "예비 환풍기 고장"
            if name == "fans_fail":
                s.fan_failed = {"main": True, "backup": True}
                return "메인·예비 환풍기 모두 고장"
            if name == "fan_repair":
                s.fan_failed = {"main": False, "backup": False}
                if self.failover_latched:
                    self._notes.append((0, "fan", "메인 환풍기 복구됨. 확인 후 메인으로 전환하세요", []))
                return "환풍기 수리 완료 (메인 전환은 사용자가 확인 후 직접)"
            if name == "soil_dry":
                self.values["soil_moisture"] = 30.0
                s.soil_override = True
                s.pump_blocked = severe
                self.pump_retry_at = 0.0
                return "토양 건조" + (" (물 공급 문제: 펌프 60초 후 정지)" if severe else " (펌프로 복구)")
            if name == "low_voltage":
                s.voltage_base = 4.5
                return "공급 전압 저하"
            if name == "over_current":
                s.current_fault = 2.8
                return "과전류"
            if name == "power_cut":
                s.power_cut = True
                return "외부 전원 차단"
            if name == "power_restore":
                s.voltage_base, s.current_fault, s.power_cut = DEFAULT_VOLTAGE, 0.0, False
                return "전원 정상화"
            if name == "co2_high":
                s.co2_source = True
                return "CO2 농도 상승 (환기로 복구)"
            if name == "nutrient_low":
                s.ec_base = 0.8
                return "양분 부족"
            if name == "nutrient_refill":
                s.ec_base = 1.8
                return "양액 보충"
            if name == "comm_loss":
                seconds = int(params.get("seconds", 30))
                s.comm_loss_until = now.timestamp() + seconds
                return f"통신 두절 {seconds}초 (그동안 /api/simulate 외 모든 API가 응답하지 않습니다)"
            if name == "comm_restore":
                s.comm_loss_until = None
                return "통신 복구"
            if name == "sensor_fault":
                sensor = params.get("sensor", "humidity")
                if sensor not in SENSORS:
                    raise ValueError(f"sensor는 {SENSORS} 중 하나입니다")
                s.sensor_faults.add(sensor)
                self._notes.append((0, "sensor_fault", f"센서 오류: {NAMES[sensor]}", ["센서 연결을 확인하세요"]))
                return f"{NAMES[sensor]} 센서 오류"
            if name == "sensor_restore":
                s.sensor_faults.clear()
                self._notes.append((0, "sensor_fault", "센서 정상 복구", []))
                return "센서 오류 해제"
            if name == "night_on":
                s.night_override = True
                return "야간 모드 강제 진입 (시계 무시)"
            if name == "night_off":
                s.night_override = False
                return "야간 모드 강제 해제 (시계 무시)"
            if name == "night_auto":
                s.night_override = None
                return "야간 모드를 설정 시각대로 동작"
            if name == "motion":
                if self.night_active:
                    s.motion_until = now.timestamp() + MOTION_ALARM_SECONDS
                    return "야간 움직임 감지"
                self._notes.append((0, "motion", "주간 움직임 감지 (야간이 아니어서 경보 없음)", []))
                return "주간이라 경보 없음"
            raise KeyError(name)


class ControlError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


# 앱의 시뮬레이션 화면이 버튼을 만들 때 쓰는 목록 (GET /api/simulate)
SCENARIOS = [
    {"name": "normal", "label": "전부 정상으로", "scenario": 1},
    {"name": "high_temp", "label": "고온 → 냉방 → 복구", "scenario": 2},
    {"name": "high_temp", "label": "고온 지속 → 긴급", "scenario": 3, "params": {"severe": True}},
    {"name": "low_temp", "label": "저온 → 난방 → 복구", "scenario": 4},
    {"name": "low_temp", "label": "저온 지속 → 긴급", "scenario": 5, "params": {"severe": True}},
    {"name": "part_high", "label": "RMU 온도 높음", "scenario": 6, "params": {"part": "rmu_temp"}},
    {"name": "part_high", "label": "쿨링팬 온도 높음 → 긴급", "scenario": 6,
     "params": {"part": "cooling_fan_temp", "severe": True}},
    {"name": "part_low", "label": "메인 환풍기 온도 낮음", "scenario": 6, "params": {"part": "main_fan_temp"}},
    {"name": "main_fan_fail", "label": "메인 환풍기 고장", "scenario": 7},
    {"name": "fans_fail", "label": "환풍기 둘 다 고장", "scenario": 8},
    {"name": "fan_repair", "label": "환풍기 수리", "scenario": 7},
    {"name": "soil_dry", "label": "토양 건조", "scenario": 9},
    {"name": "soil_dry", "label": "토양 건조 (물 공급 문제)", "scenario": 9, "params": {"severe": True}},
    {"name": "low_voltage", "label": "공급 전압 저하", "scenario": 10},
    {"name": "over_current", "label": "과전류", "scenario": 10},
    {"name": "power_cut", "label": "전원 차단", "scenario": 10},
    {"name": "power_restore", "label": "전원 정상화", "scenario": 10},
    {"name": "co2_high", "label": "CO2 농도 높음", "scenario": 11},
    {"name": "nutrient_low", "label": "양분 부족", "scenario": 11},
    {"name": "nutrient_refill", "label": "양액 보충", "scenario": 11},
    {"name": "comm_loss", "label": "통신 두절 30초", "scenario": 12, "params": {"seconds": 30}},
    {"name": "comm_restore", "label": "통신 복구", "scenario": 12},
    {"name": "sensor_fault", "label": "습도 센서 오류", "scenario": 13, "params": {"sensor": "humidity"}},
    {"name": "sensor_restore", "label": "센서 오류 해제", "scenario": 13},
    {"name": "night_on", "label": "야간 모드 진입", "scenario": 14},
    {"name": "night_off", "label": "야간 모드 해제", "scenario": 14},
    {"name": "night_auto", "label": "야간 모드 시각대로", "scenario": 14},
    {"name": "motion", "label": "CCTV 움직임 감지", "scenario": 15},
    {"name": "slow_heat", "label": "온도 서서히 상승 (AI 선가동)", "scenario": 22},
]
