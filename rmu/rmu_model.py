"""
스마트팜 게이트웨이(라즈베리파이)의 상태와 규칙 — v3.0 (CLAUDE.md 1·4·7장)

라즈베리파이는 RMU 실물 값(온도·전원·도어·알람 코드)과 직접 연결한 감지기 값(습도·화재·수위)을
모아서 판단한다. RMU는 등급을 주지 않으므로 등급은 여기서 계산한다.

모드
  - demo(데모): 모든 값을 시뮬레이션한다. AI 조치는 자동 실행.
  - live(실사용): RMU·센서 실제 값을 쓴다. AI는 위험이 낮은 조치만 자동, 나머지는 제안 → 사용자 승인.

1초마다 tick()이 불리면
  1) 값 갱신 (시뮬레이션 → 실사용이면 실제 값으로 덮어쓰기)
  2) AI 판단 (선가동, 센서 불일치, 값 고정, 누수 의심)
  3) 온도·부품 온도 상태 판정 (정상 → 경보 → 긴급)
  4) 알람 조건 판정 (등급, 코드)
  5) 장치 출력 계산: 사용자 설정(base) 위에 야간·자동 조치·긴급 정지를 덮어쓴다
  6) 이벤트(알림)와 조치 내역 기록
"""

import random
import threading
from datetime import datetime

TICK_SECONDS = 1.0

# ---------------------------------------------------------------------------
# 기준값 ((제안)은 문서에 없어 임시로 정한 값)
# ---------------------------------------------------------------------------
DEFAULT_THRESHOLDS = {
    "temp_low": 15.0, "temp_high": 30.0,            # ℃ (15℃ 하한은 RMU에 못 넣으므로 여기서 판정)
    "humidity_low": 50.0, "humidity_high": 85.0,    # %
    "water_level_low": 20.0,                        # % (제안)
    "ac_voltage_low": 200.0, "ac_voltage_high": 240.0,  # V (제안)
    "pi_temp_high": 80.0,                           # ℃
    "part_temp_high": 60.0, "part_temp_low": 0.0,   # ℃ 환풍기·쿨링팬 장비 (제안)
    "cooling_setpoint": 22.0, "heating_setpoint": 28.0,  # ℃ 자동 냉방/난방 때 에어컨 설정온도 (제안)
    "sensor_mismatch": 3.0,                         # ℃ RMU 온도와 온습도감지기 온도 허용 차이 (제안)
    "soil_low": 35.0, "co2_high": 1500, "ec_low": 1.0,  # 감지기가 연결되면 사용
}

HYSTERESIS = {"temp": 2.0, "part": 5.0, "humidity": 2.0, "water": 5.0, "ac_voltage": 3.0,
              "soil": 5.0, "co2": 300, "ec": 0.2}
EMERGENCY_MARGIN = {"temp": 2.0, "part": 10.0}
EMERGENCY_MIN_SECONDS = 60     # 경보가 이 시간 이상 계속된 뒤에만 긴급으로 (자동 조치가 효과를 낼 시간, 제안)

PUMP_MAX_SECONDS = 60
PUMP_RETRY_SECONDS = 600
MOTION_ALARM_SECONDS = 30
POWER_CUT_VOLTAGE = 50.0       # V 이하면 전원 차단으로 본다 (제안)

# AI (제안. 모의 환경은 시간이 빨리 흐르므로 실물에서는 늘려야 할 수 있다)
AI_WINDOW_SECONDS = 30
AI_MIN_SAMPLES = 10
AI_LEAD_SECONDS = 120
AI_MIN_SLOPE = 0.002           # ℃/초
AI_MIN_HOLD_SECONDS = 60
AI_RELEASE_MARGIN = 4.0
AI_MAX_ACTIONS_PER_HOUR = 10   # AI 자동 조치 횟수 한도
MISMATCH_SECONDS = 30          # 이 시간 동안 계속 차이가 나야 불일치로 본다
STUCK_SECONDS = 120            # 값이 이 시간 동안 전혀 안 변하면 고장 의심
LEAK_WINDOW_SECONDS = 60
LEAK_RATE = -0.15              # %/초보다 빨리 줄면(펌프가 꺼져 있는데) 누수 의심

# AI 허용 목록: AI가 바꿀 수 있는 장치와 위험도. 위험 low만 실사용 모드에서 자동 실행.
AI_ALLOW_LIST = {"cooling_fan": "low", "aircon_setpoint": "high"}

MAX_EVENTS = 500

PARTS = ["pi_temp", "main_fan_temp", "backup_fan_temp", "cooling_fan_temp"]
OPTIONAL = ["co2", "soil_moisture", "nutrient_ec"]          # 감지기 연결 시에만 (기본 정보없음)
RMU_ITEMS = ["temperature", "temp2", "ac_voltage", "ac_frequency", "door_front", "ups_battery"]
SENSORS = ["temperature", "temp2", "humidity", "hum_temp", "water_level", "fire",
           "ac_voltage", *PARTS, *OPTIONAL]                  # 센서 오류를 흉내 낼 수 있는 항목

NAMES = {
    "temperature": "온도", "temp2": "온도2", "humidity": "습도", "hum_temp": "온습도감지기 온도",
    "water_level": "수위", "fire": "화재", "ac_voltage": "AC 전압", "ac_frequency": "AC 주파수",
    "door_front": "전면 도어", "ups_battery": "UPS 배터리",
    "co2": "CO2", "soil_moisture": "토양수분", "nutrient_ec": "양분(EC)",
    "pi_temp": "라즈베리파이 온도", "main_fan_temp": "메인 환풍기 온도",
    "backup_fan_temp": "예비 환풍기 온도", "cooling_fan_temp": "쿨링팬 온도",
    "main_fan": "메인 환풍기", "backup_fan": "예비 환풍기", "cooling_fan": "쿨링팬",
    "aircon": "에어컨", "heater": "히터", "pump": "펌프", "cover": "덮개", "lights": "전구",
}

SUPPLY_DEVICES = ["main_fan", "backup_fan", "cooling_fan", "pump"]  # AC 전원이 끊기면 멈춤
DEVICE_WATTS = {"main_fan": 40, "backup_fan": 40, "cooling_fan": 30, "aircon": 1500,
                "heater": 2000, "pump": 60, "cover": 20, "lights": 300}
BASE_WATTS = 30

# 긴급 경보 시 정지 (문제를 해결하는 장비는 유지, CLAUDE.md 4장)
HIGH_EMERGENCY_STOP = ["heater", "lights", "pump"]
LOW_EMERGENCY_STOP = ["aircon", "cooling_fan", "main_fan", "backup_fan", "lights", "pump"]
FIRE_STOP = ["heater", "lights", "pump"]  # 화재: 열원·전기 장비 정지 (환기는 팀 결정 전이라 그대로)

DEFAULT_BASE = {
    "main_fan": 1, "backup_fan": 0, "cooling_fan": 0,
    "aircon": 1, "aircon_setpoint": 25.0,
    "heater": 0, "pump": 0, "cover": 0, "lights": 1,
    "control_mode": 1,
}
DEFAULT_SETTINGS = {"night_mode": 1, "night_start": 21 * 60, "night_end": 6 * 60}
DEFAULT_AC = 220.0


def clamp(v, low, high):
    return max(low, min(high, v))


def josa(word, with_batchim, without_batchim):
    last = word[-1]
    if "가" <= last <= "힣" and (ord(last) - 0xAC00) % 28 != 0:
        return word + with_batchim
    return word + without_batchim


def in_night_window(minutes, start, end):
    if start < end:
        return start <= minutes < end
    return minutes >= start or minutes < end  # 자정을 넘는 구간


def describe_changes(before, after):
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


def slope(points):
    """[(시각, 값)] 최소제곱 기울기 (값/초). 점이 부족하면 None"""
    if len(points) < AI_MIN_SAMPLES:
        return None
    n = len(points)
    mt = sum(t for t, _ in points) / n
    mv = sum(v for _, v in points) / n
    den = sum((t - mt) ** 2 for t, _ in points)
    if den == 0:
        return None
    return sum((t - mt) * (v - mv) for t, v in points) / den


class Sim:
    """시뮬레이션으로 주입한 상황 (POST /api/simulate)"""

    def __init__(self):
        self.heat = 0.0
        self.part_load = {p: 0.0 for p in PARTS}
        self.fan_failed = {"main": False, "backup": False}
        self.ai_bypass = False
        self.ac_base = DEFAULT_AC
        self.power_cut = False
        self.water_target = 80.0
        self.leak = False
        self.fire = False
        self.door_open = False
        self.mismatch = 0.0           # 온습도감지기 온도를 일부러 어긋나게
        self.stuck = False            # 온도 값 고정
        self.comm_loss_until = None
        self.sensor_faults = set()
        self.night_override = None
        self.motion_until = 0.0
        self.rmu_offline = False      # RMU 통신 두절 흉내 (데모에서도 RMU 항목을 '통신 두절'로)
        self.rmu_frozen = {}          # 두절 순간의 RMU 항목 값 (마지막 수신값으로 보여준다)
        self.rmu_offline_since = None


class RmuModel:
    def __init__(self, hardware=None, storage=None, unavailable=None, mode="demo"):
        """hardware: 라즈베리파이 직결 감지기·릴레이 (hardware.Hardware)
        storage: SQLite 기록 (storage.Storage)
        unavailable: 감지기가 없어 정보없음인 항목 (oids.json available=false)"""
        self.lock = threading.RLock()
        self.hardware = hardware
        self.storage = storage
        self.unavailable = set(OPTIONAL if unavailable is None else unavailable)
        self.mode = mode
        self.event_listeners = []

        # 시뮬레이션 세계 (데모 모드 값, 실사용 모드에서도 시뮬레이션 장치 값)
        self.values = {
            "temperature": 25.0, "temp2": 24.0, "humidity": 72.0, "hum_temp": 25.0,
            "water_level": 80.0, "fire": 0.0, "ac_voltage": DEFAULT_AC, "ac_frequency": 60.0,
            "door_front": 0.0, "ups_battery": 100.0,
            "pi_temp": 48.0, "main_fan_temp": 35.0, "backup_fan_temp": 28.0, "cooling_fan_temp": 28.0,
            "co2": 450.0, "soil_moisture": 45.0, "nutrient_ec": 1.8,
        }
        # 실사용 모드: 밖에서 들어온 실제 값 (RMU 조회, 직결 감지기)
        self.external = {}
        self.rmu_used = False            # RMU를 조회하고 있는가 (--rmu-host)
        self.rmu_connected = None        # 마지막 조회 성공 여부
        self.rmu_last_seen = None
        self.rmu_alarms = {}             # RMU가 알린 알람 코드 → 받은 시각 (Trap 또는 alarm 스칼라)
        self.hw_faults = set()
        self.hw_fan_failed = {}          # 실물 팬 회전 감지 결과 (hardware.fan_failures)

        self.base = dict(DEFAULT_BASE)
        self.saved_base = None
        self.manual_start = {}
        self.control = dict(DEFAULT_BASE)
        self.thresholds = dict(DEFAULT_THRESHOLDS)
        self.settings = dict(DEFAULT_SETTINGS)
        self.sim = Sim()

        self.temp_state = "normal"
        self.part_states = {p: "normal" for p in PARTS}
        self.state_since = {}            # 온도·부품 경보가 시작된 시각 (긴급 판정용)
        self.active = {}
        self.night_active = False
        self.failover_latched = False
        self.pump_started_at = None
        self.pump_retry_at = 0.0
        self.energy_wh = 0.0
        self.events = []
        self.next_event_id = (storage.last_event_id() + 1) if storage else 1
        self._notes = []

        # AI
        self.temp_samples = []
        self.water_samples = []
        self.mismatch_since = None
        self.stuck_since = None
        self.stuck_value = None
        self.ai_active = False           # 미리 냉방 전체 (데모: 자동, 실사용: 승인 후)
        self.ai_fan = False              # 위험 낮은 조치만 (실사용: 쿨링팬)
        self.ai_started = 0.0
        self.ai_action_times = []
        self.suggestions = []
        self.next_suggestion_id = 1
        self.ai = {"active": False, "reason": "데이터 수집 중", "slope_per_min": None, "eta_seconds": None}

    # =======================================================================
    # 1초마다
    # =======================================================================
    def tick(self, now=None):
        now = now or datetime.now()
        with self.lock:
            self._update_physics()
            if self.mode == "live":
                self._apply_external()
            ts = now.timestamp()
            self._update_ai(ts)
            self._evaluate(now)
            if self.hardware is not None:
                self.hardware.apply(self.control)
            if self.storage is not None:
                self.storage.maybe_record(now, self.history_values())

    # ----- 값 출처 -----------------------------------------------------------
    def _simulated_sensors(self):
        """시뮬레이션이 움직이고 있는 값 (실사용 모드에서도 이 값들은 시뮬레이션을 쓴다)"""
        s = self.sim
        names = set()
        if s.heat or s.stuck:
            names.add("temperature")
        if s.mismatch:
            names.add("hum_temp")
        if s.power_cut or s.ac_base != DEFAULT_AC:
            names.update(["ac_voltage", "ac_frequency"])
        if s.leak or s.water_target != 80.0:
            names.add("water_level")
        if s.fire:
            names.add("fire")
        if s.door_open:
            names.add("door_front")
        names.update(p for p, load in s.part_load.items() if load)
        return names

    def set_external(self, readings, source):
        """실제 값 받기. source: 'rmu' 또는 'pi'. 값이 None이면 그 항목은 읽기 실패."""
        with self.lock:
            now = datetime.now()
            for name, value in readings.items():
                self.external[name] = value
            if source == "rmu":
                self.rmu_connected = True
                self.rmu_last_seen = now

    def set_rmu_offline(self):
        with self.lock:
            self.rmu_connected = False

    def _apply_external(self):
        simulated = self._simulated_sensors()
        self.hw_faults = set()
        rmu_down = self.rmu_used and (not self.rmu_connected or self.sim.rmu_offline)
        for name, value in self.external.items():
            if name in simulated:
                continue
            if name in RMU_ITEMS and rmu_down:
                continue  # 통신 두절: 마지막 값 유지
            if value is None:
                self.hw_faults.add(name)
            else:
                self.values[name] = float(value)

    def item_state(self, name):
        """ok / nodata / fault / offline (CLAUDE.md 3장 정보없음 규칙)"""
        if name in self.unavailable:
            return "nodata"
        if name in self.sensor_faults():
            return "fault"
        if name in RMU_ITEMS:
            if self.sim.rmu_offline:
                return "offline"
            if self.mode == "live" and self.rmu_used and not self.rmu_connected:
                return "offline" if self.rmu_last_seen else "nodata"
        return "ok"

    def usable(self, name):
        """알람·AI 판단에 쓸 수 있는 값인가 (정보없음·오류·두절은 제외)"""
        return self.item_state(name) == "ok"

    def sensor_faults(self):
        return self.sim.sensor_faults | self.hw_faults

    def fan_failed(self, which):
        """시뮬레이션 고장 또는 실물 회전 감지 고장 (실사용 모드)"""
        hw = self.mode == "live" and self.hw_fan_failed.get(f"{which}_fan", False)
        return self.sim.fan_failed[which] or hw

    def running(self, device):
        if not self.control[device]:
            return False
        if device in SUPPLY_DEVICES and self.power_down():
            return False
        if device == "main_fan" and self.fan_failed("main"):
            return False
        if device == "backup_fan" and self.fan_failed("backup"):
            return False
        return True

    def power_down(self):
        return self.sim.power_cut or (self.usable("ac_voltage") and self.values["ac_voltage"] < POWER_CUT_VOLTAGE)

    # ----- 시뮬레이션 세계 ----------------------------------------------------
    def _update_physics(self):
        v, c, s = self.values, self.control, self.sim
        if not s.stuck:
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
        v["temp2"] = clamp(v["temp2"] + 0.1 * (v["temperature"] - 1.0 - v["temp2"]) + random.uniform(-0.05, 0.05), -20, 60)
        # 온습도감지기 온도: 같은 온실이라 RMU 온도와 거의 같다 (불일치 시나리오면 어긋남)
        v["hum_temp"] = v["temperature"] + s.mismatch + random.uniform(-0.2, 0.2)

        for p in PARTS:
            if p == "pi_temp":
                base = 48.0
            else:
                base = 35.0 if self.running(p.replace("_temp", "")) else 28.0
            t = v[p]
            d = s.part_load[p] - 0.05 * (t - base) + random.uniform(-0.1, 0.1)
            if self.running("cooling_fan") and t > base:
                d -= 1.5
            if self.running("heater") and t < base:
                d += 2.0
            v[p] = clamp(t + d, -60, 150)

        v["humidity"] = clamp(v["humidity"] + 0.1 * (72 - v["humidity"]) + random.uniform(-0.5, 0.5), 0, 100)

        # 수위(물탱크): 목표 수위 쪽으로 천천히, 펌프를 쓰면 줄고, 누수면 빨리 준다
        if s.leak:
            dw = -0.4 + random.uniform(-0.05, 0.05)  # 새는 동안은 채워지지 않는다
        else:
            dw = 0.02 * (s.water_target - v["water_level"]) + random.uniform(-0.05, 0.05)
        if self.running("pump"):
            dw -= 0.2
        v["water_level"] = clamp(v["water_level"] + dw, 0, 100)
        v["fire"] = 1.0 if s.fire else 0.0
        v["door_front"] = 1.0 if s.door_open else 0.0

        if s.power_cut:
            v["ac_voltage"], v["ac_frequency"] = 0.0, 0.0
        else:
            v["ac_voltage"] += 0.3 * (s.ac_base - v["ac_voltage"]) + random.uniform(-0.3, 0.3)
            v["ac_frequency"] = 60.0 + random.uniform(-0.05, 0.05)

        # 정보없음 항목도 내부에서는 흉내 값을 돌린다 (감지기가 연결되면 쓰기 위해)
        v["co2"] = clamp(v["co2"] + 0.02 * (450 - v["co2"]) + random.uniform(-5, 5), 300, 5000)
        v["soil_moisture"] = clamp(v["soil_moisture"] + 0.002 * (45 - v["soil_moisture"])
                                   + (0.5 if self.running("pump") else 0) + random.uniform(-0.1, 0.1), 0, 100)
        v["nutrient_ec"] = clamp(v["nutrient_ec"] + 0.1 * (1.8 - v["nutrient_ec"]) + random.uniform(-0.02, 0.02), 0, 5)

        self.energy_wh += self.greenhouse_power() * TICK_SECONDS / 3600

    def greenhouse_power(self):
        return BASE_WATTS + sum(w for d, w in DEVICE_WATTS.items() if self.running(d))

    # =======================================================================
    # AI 판단 (CLAUDE.md 7장 AI 판단)
    # =======================================================================
    def _ai_budget_ok(self, ts):
        """AI 자동 조치 횟수 한도"""
        self.ai_action_times = [t for t in self.ai_action_times if ts - t < 3600]
        return len(self.ai_action_times) < AI_MAX_ACTIONS_PER_HOUR

    def _add_suggestion(self, ts, kind, title, reason, action):
        if any(s["kind"] == kind and s["status"] == "pending" for s in self.suggestions):
            return
        self.suggestions.append({
            "id": self.next_suggestion_id, "kind": kind, "title": title, "reason": reason,
            "action": action, "risk": AI_ALLOW_LIST.get(action["device"], "high"),
            "status": "pending", "time": datetime.fromtimestamp(ts).isoformat(timespec="seconds"),
        })
        self.next_suggestion_id += 1
        del self.suggestions[:-50]
        self._notes.append((1, "ai_suggest", f"AI 제안: {title}", [f"판단 이유: {reason}", "승인하면 실행합니다"], True))

    def _expire_suggestions(self, kind):
        for s in self.suggestions:
            if s["kind"] == kind and s["status"] == "pending":
                s["status"] = "expired"

    def _update_ai(self, ts):
        th = self.thresholds
        temp = self.values["temperature"]
        high = th["temp_high"]
        auto = self.base["control_mode"] == 1

        # --- 1) 온도 상승 속도로 선가동 ---
        temp_ok = self.usable("temperature")
        if temp_ok:
            self.temp_samples.append((ts, temp))
        self.temp_samples = [p for p in self.temp_samples if ts - p[0] <= AI_WINDOW_SECONDS]
        # 창(30초)이 다 찰 때까지는 판단하지 않는다: 시작 직후 몇 개 값의 흔들림을 상승으로 오판하지 않게
        full = bool(self.temp_samples) and ts - self.temp_samples[0][0] >= AI_WINDOW_SECONDS * 0.9
        sl = slope(self.temp_samples) if temp_ok and full else None
        eta = (high - temp) / sl if sl and sl > 0 and temp < high else None
        if not temp_ok:
            reason = f"온도 값을 쓸 수 없어 판단하지 않습니다 ({self.item_state('temperature')})"
        elif sl is None:
            reason = "데이터 수집 중"
        elif eta is not None:
            reason = (f"최근 {AI_WINDOW_SECONDS}초 상승 속도 {sl * 60:.2f}℃/분, "
                      f"이대로면 약 {eta / 60:.1f}분 뒤 상한 {high:.1f}℃ 도달")
        else:
            reason = f"온도 변화 {sl * 60:+.2f}℃/분, 상한 도달 예상 없음"

        heating = any(st in ("low", "low_emergency") for st in [self.temp_state, *self.part_states.values()])
        usable = auto and temp_ok and not heating and not self.sim.ai_bypass and self.temp_state == "normal"
        rising = usable and eta is not None and eta <= AI_LEAD_SECONDS and sl >= AI_MIN_SLOPE
        engaged = self.ai_active or self.ai_fan
        if not engaged and rising:
            if self.mode == "demo":
                if self._ai_budget_ok(ts):
                    self.ai_active = True
                    self.ai_started = ts
                    self.ai_action_times.append(ts)
                    self._notes.append((0, "ai", "AI 선가동: 상한 도달 전에 냉방을 시작합니다",
                                        [f"판단 이유: {reason}"], True))
            else:
                # 실사용: 위험 낮은 쿨링팬만 자동, 에어컨 설정온도 변경은 제안
                if self._ai_budget_ok(ts):
                    self.ai_fan = True
                    self.ai_started = ts
                    self.ai_action_times.append(ts)
                    self._notes.append((0, "ai", "AI 선가동: 쿨링팬을 미리 켭니다 (위험 낮은 조치는 자동)",
                                        [f"판단 이유: {reason}"], True))
                self._add_suggestion(ts, "precool", f"에어컨 설정온도를 {th['cooling_setpoint']:.0f}℃로 낮춰 미리 냉방",
                                     reason, {"device": "aircon_setpoint", "value": th["cooling_setpoint"]})
        elif engaged and not usable:
            self.ai_active = self.ai_fan = False
            self._expire_suggestions("precool")
        elif engaged and ts - self.ai_started >= AI_MIN_HOLD_SECONDS and temp <= high - AI_RELEASE_MARGIN \
                and sl is not None and sl <= 0:
            self.ai_active = self.ai_fan = False
            self.sim.heat = 0.0
            self._expire_suggestions("precool")
            self._notes.append((0, "ai", "AI 선가동 종료: 온도가 안정되었습니다", [f"판단 이유: {reason}"], True))

        self.ai = {"active": self.ai_active or self.ai_fan, "reason": reason, "mode": self.mode,
                   "slope_per_min": None if sl is None else round(sl * 60, 2),
                   "eta_seconds": None if eta is None else round(eta),
                   "pending": sum(1 for s in self.suggestions if s["status"] == "pending")}

        # --- 2) 센서 불일치: RMU 온도 vs 온습도감지기 온도 ---
        if self.usable("temperature") and self.usable("hum_temp") \
                and abs(temp - self.values["hum_temp"]) > th["sensor_mismatch"]:
            self.mismatch_since = self.mismatch_since or ts
        else:
            self.mismatch_since = None

        # --- 3) 값 고정: 온도가 오래 똑같으면 센서 고장 의심 ---
        if temp_ok and self.stuck_value is not None and abs(temp - self.stuck_value) < 1e-6:
            self.stuck_since = self.stuck_since or ts
        else:
            self.stuck_since = None
        self.stuck_value = temp if temp_ok else None

        # --- 4) 수위 하락 속도: 펌프가 꺼져 있는데 빨리 줄면 누수 의심 ---
        if self.usable("water_level"):
            self.water_samples.append((ts, self.values["water_level"]))
        self.water_samples = [p for p in self.water_samples if ts - p[0] <= LEAK_WINDOW_SECONDS]

    def water_slope(self):
        return slope(self.water_samples)

    # =======================================================================
    # 판정 → 출력 → 이벤트
    # =======================================================================
    def _evaluate(self, now, default_message=None):
        ts = now.timestamp()
        self._update_temp_states(ts)
        self._update_night(now)
        cond = self._evaluate_conditions(ts)
        self._update_pump(ts, cond)
        self._update_failover()
        before = dict(self.control)
        self.control = self._compute_outputs(cond)
        self._record_events(now, cond, describe_changes(before, self.control), default_message)

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
            if state == "high" and auto and value > high + margin:
                return "high_emergency"
        elif state in ("low", "low_emergency"):
            if value >= low + hyst:
                return "normal"
            if state == "low" and auto and value < low - margin:
                return "low_emergency"
        return state

    def _hold_emergency(self, key, old, new, ts):
        """경보 → 긴급은 경보가 EMERGENCY_MIN_SECONDS 이상 계속됐을 때만 (냉방·난방이 효과를 낼 시간).
        RMU 값이 갑자기 뛰어도 1초 만에 긴급으로 가지 않게 한다."""
        if new == "normal":
            self.state_since.pop(key, None)
            return new
        if old == "normal":
            self.state_since[key] = ts
        if new.endswith("_emergency") and not old.endswith("_emergency")                 and ts - self.state_since.get(key, ts) < EMERGENCY_MIN_SECONDS:
            return old
        return new

    def _update_temp_states(self, ts):
        th, auto, s = self.thresholds, self.base["control_mode"] == 1, self.sim
        if self.usable("temperature"):
            new = self._next_state(self.temp_state, self.values["temperature"], th["temp_low"],
                                   th["temp_high"], HYSTERESIS["temp"], EMERGENCY_MARGIN["temp"], auto)
            new = self._hold_emergency("temp", self.temp_state, new, ts)
            if new == "normal" and self.temp_state != "normal":
                s.heat = 0.0
                s.ai_bypass = False
                self.temp_samples = []  # 경보 전후 값으로 AI가 상승을 오판하지 않게 새로 모은다
            self.temp_state = new
        for p in PARTS:
            if not self.usable(p):
                continue
            high = th["pi_temp_high"] if p == "pi_temp" else th["part_temp_high"]
            new = self._next_state(self.part_states[p], self.values[p], th["part_temp_low"], high,
                                   HYSTERESIS["part"], EMERGENCY_MARGIN["part"], auto)
            new = self._hold_emergency(p, self.part_states[p], new, ts)
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
            self._notes.append((0, "night", "야간 모드 진입" if night else "야간 모드 해제", [], False))
        self.night_active = night

    def _evaluate_conditions(self, ts):
        v, th, s = self.values, self.thresholds, self.sim
        auto = self.base["control_mode"] == 1
        prev = self.active
        cond = {}

        def add(key, level, code, message, guide=None, ai=False):
            cond[key] = {"key": key, "level": level, "code": code, "message": message,
                         "guide": list(guide or []), "ai": ai}

        def hyst(key, enter, stay):
            return stay if key in prev else enter

        # 온실 온도 (RMU temp1, 코드 9를 우리 임계값으로 재판정)
        t = v["temperature"]
        st = self.temp_state
        if st == "high":
            add("temp", 2, 9, f"온실 온도 상한 초과 (현재 {t:.1f}℃, 상한 {th['temp_high']:.1f}℃)")
        elif st == "high_emergency":
            add("temp", 3, 9, f"긴급: 냉방 후에도 온도 상승 ({t:.1f}℃)")
        elif st == "low":
            add("temp", 2, 9, f"온실 온도 하한 미만 (현재 {t:.1f}℃, 하한 {th['temp_low']:.1f}℃)")
        elif st == "low_emergency":
            add("temp", 3, 9, f"긴급: 난방 후에도 온도 하락 ({t:.1f}℃)")
        if st != "normal" and self.night_active:
            cond["temp"]["guide"].append("야간이지만 온도 경보를 우선합니다. 환기를 먼저 가동하고 전구는 소등을 유지합니다")

        # 부품 온도 (207)
        for p in PARTS:
            ps, pv = self.part_states[p], v[p]
            if ps == "high":
                add(f"part:{p}", 1, 207, f"{NAMES[p]} 기준 초과 ({pv:.1f}℃)")
            elif ps == "high_emergency":
                add(f"part:{p}", 3, 207, f"긴급: 냉각 후에도 {NAMES[p]} 상승 ({pv:.1f}℃)")
            elif ps == "low":
                add(f"part:{p}", 1, 207, f"{NAMES[p]} 기준 미만 ({pv:.1f}℃)")
            elif ps == "low_emergency":
                add(f"part:{p}", 3, 207, f"긴급: 난방 후에도 {NAMES[p]} 하락 ({pv:.1f}℃)")

        # 습도 (201)
        h = v["humidity"]
        if self.usable("humidity"):
            if hyst("humidity_high", h > th["humidity_high"], h > th["humidity_high"] - HYSTERESIS["humidity"]):
                add("humidity_high", 2, 201, f"습도 상한 초과 ({h:.1f}%)", ["환기를 확인하세요"])
            if hyst("humidity_low", h < th["humidity_low"], h < th["humidity_low"] + HYSTERESIS["humidity"]):
                add("humidity_low", 2, 201, f"습도 하한 미만 ({h:.1f}%)")

        # 수위 (202): 부족하면 펌프 제한
        w = v["water_level"]
        if self.usable("water_level") and hyst("water_low", w < th["water_level_low"],
                                                w < th["water_level_low"] + HYSTERESIS["water"]):
            add("water_low", 2, 202, f"수위 부족 (현재 {w:.0f}%, 하한 {th['water_level_low']:.0f}%)",
                ["물이 부족해 펌프 사용을 제한합니다. 물탱크를 채우세요"])

        # 누수 의심 (AI, 202 주의): 펌프가 꺼져 있는데 수위가 빨리 줄어든다
        ws = self.water_slope()
        if self.usable("water_level") and ws is not None and not self.running("pump") \
                and hyst("leak", ws < LEAK_RATE, ws < LEAK_RATE / 2):
            add("leak", 1, 202, f"누수 의심: 수위가 분당 {abs(ws) * 60:.1f}%씩 줄고 있습니다",
                [f"판단 이유: 최근 {LEAK_WINDOW_SECONDS}초 수위 하락 속도 {ws * 60:.1f}%/분 (펌프 꺼짐)",
                 "배관과 물탱크를 확인하세요"], ai=True)

        # 화재 (203, 긴급)
        if self.usable("fire") and v["fire"] >= 1:
            add("fire", 3, 203, "긴급: 화재 감지",
                ["열원과 전기 장비(히터·전구·펌프)를 정지했습니다",
                 "오감지일 수 있으니 현장을 확인하세요"])

        # 감지기가 연결된 경우에만 (기본은 정보없음이라 판정 제외)
        if self.usable("co2") and hyst("co2", v["co2"] > th["co2_high"], v["co2"] > th["co2_high"] - HYSTERESIS["co2"]):
            add("co2", 2, 204, f"CO2 농도 높음 ({v['co2']:.0f}ppm)")
        if self.usable("nutrient_ec") and hyst("nutrient", v["nutrient_ec"] < th["ec_low"],
                                                v["nutrient_ec"] < th["ec_low"] + HYSTERESIS["ec"]):
            add("nutrient", 2, 205, f"양분 부족 (EC {v['nutrient_ec']:.2f}mS/cm)", ["양액을 보충하세요"])
        if self.usable("soil_moisture") and hyst("soil_dry", v["soil_moisture"] < th["soil_low"],
                                                  v["soil_moisture"] < th["soil_low"] + HYSTERESIS["soil"]):
            add("soil_dry", 2, 206, f"토양 건조 ({v['soil_moisture']:.0f}%)")

        # AC 전원 (RMU acv1, 코드 1)
        ac = v["ac_voltage"]
        if self.power_down():
            add("power", 2, 1, "AC 전원 차단", ["환풍기·쿨링팬·펌프가 멈춘 상태입니다. 전원을 확인하세요"])
        elif self.usable("ac_voltage") and hyst(
                "power", not th["ac_voltage_low"] <= ac <= th["ac_voltage_high"],
                not th["ac_voltage_low"] + HYSTERESIS["ac_voltage"] <= ac <= th["ac_voltage_high"] - HYSTERESIS["ac_voltage"]):
            add("power", 2, 1, f"AC 전압 이상 ({ac:.1f}V)", ["전압이 정상이 될 때까지 펌프 사용을 제한합니다"])

        # 전면 도어 (RMU doorFront, 코드 21)
        motion = self.night_active and ts < s.motion_until
        if self.usable("door_front") and v["door_front"] >= 1:
            msg = "야간 전면 도어 열림 + CCTV 움직임 (침입 의심)" if motion else "전면 도어 열림"
            add("door", 2, 21, msg, ["현장을 확인하세요"])
        elif motion:
            add("intrusion", 2, 210, "야간 CCTV 움직임 감지", ["CCTV를 확인하세요"])

        # 환풍기 이중화 (208)
        main_bad, backup_bad = self.fan_failed("main"), self.fan_failed("backup")
        if main_bad and backup_bad:
            add("fan", 3, 208, "긴급: 메인·예비 환풍기 모두 고장 (대체 수단 없음)", ["환풍기를 즉시 점검하세요"])
        elif main_bad:
            if auto:
                add("fan", 2, 208, "메인 환풍기 고장, 예비 환풍기로 대체")
            else:
                add("fan", 2, 208, "메인 환풍기 고장", ["수동 모드입니다. 예비 환풍기를 직접 켜세요"])
        elif backup_bad:
            add("fan_backup", 1, 208, "예비 환풍기 고장 (메인은 정상)")

        # 센서 불일치·값 고정 (AI, 209 주의)
        if self.mismatch_since is not None and ts - self.mismatch_since >= MISMATCH_SECONDS:
            diff = v["temperature"] - v["hum_temp"]
            add("mismatch", 1, 209, f"센서 불일치 의심: RMU 온도와 온습도감지기 온도 차이 {abs(diff):.1f}℃",
                [f"판단 이유: {MISMATCH_SECONDS}초 넘게 차이가 {th['sensor_mismatch']:.1f}℃보다 큽니다 "
                 f"(RMU {v['temperature']:.1f}℃, 온습도감지기 {v['hum_temp']:.1f}℃)",
                 "두 감지기 위치와 배선을 확인하세요"], ai=True)
        if self.stuck_since is not None and ts - self.stuck_since >= STUCK_SECONDS:
            add("stuck", 1, 209, f"센서 고장 의심: 온도가 {STUCK_SECONDS // 60}분 넘게 {v['temperature']:.1f}℃로 고정",
                [f"판단 이유: {STUCK_SECONDS}초 동안 값이 전혀 변하지 않았습니다", "온도감지기를 확인하세요"], ai=True)

        # RMU가 알려 준 그 밖의 알람 코드 (Trap 또는 alarm 스칼라)
        for code in sorted(self.rmu_alarms):
            if code in (1, 9, 10, 21):
                continue  # 값으로 직접 판정하는 항목
            info = RMU_CODE_TEXT.get(code)
            if info:
                add(f"rmu:{code}", info[0], code, f"{info[1]} (RMU 알람 {code})", ["RMU 장비를 확인하세요"])
        return cond

    def _update_pump(self, ts, cond):
        """토양수분 감지기가 연결된 경우에만 자동 급수 (기본은 정보없음이라 동작 안 함)"""
        auto = self.base["control_mode"] == 1
        dry = "soil_dry" in cond and "water_low" not in cond
        if self.pump_started_at is None:
            if auto and dry and ts >= self.pump_retry_at:
                self.pump_started_at = ts
        elif not auto or not dry:
            self.pump_started_at = None
        elif ts - self.pump_started_at >= PUMP_MAX_SECONDS:
            self.pump_started_at = None
            self.pump_retry_at = ts + PUMP_RETRY_SECONDS
            self._notes.append((2, "pump", f"펌프 최대 {PUMP_MAX_SECONDS}초 동작 후 정지", [], False))

    def _update_failover(self):
        if self.base["control_mode"] == 1 and self.fan_failed("main") and self.base["main_fan"]:
            self.failover_latched = True

    def _compute_outputs(self, cond):
        c = dict(self.base)
        if self.night_active:
            c["cover"] = 1
            c["lights"] = 0
        if c["control_mode"] != 1:
            return c

        parts = list(self.part_states.values())
        cooling = self.ai_active or self.temp_state in ("high", "high_emergency") or any(
            p in ("high", "high_emergency") for p in parts)
        heating = self.temp_state in ("low", "low_emergency") or any(
            p in ("low", "low_emergency") for p in parts)
        if cooling:
            c["aircon"] = 1
            c["aircon_setpoint"] = min(c["aircon_setpoint"], self.thresholds["cooling_setpoint"])
            c["cooling_fan"] = 1
        elif heating:
            c["heater"] = 1
            if c["aircon"]:
                c["aircon_setpoint"] = max(c["aircon_setpoint"], self.thresholds["heating_setpoint"])
        if self.ai_fan:
            c["cooling_fan"] = 1  # 실사용 모드 AI: 위험 낮은 조치(허용 목록)
        if "co2" in cond or (self.night_active and self.temp_state != "normal"):
            c["backup_fan"] = 1
        if self.failover_latched:
            c["main_fan"] = 0
            c["backup_fan"] = 1
        if self.pump_started_at is not None:
            c["pump"] = 1

        states = [self.temp_state, *parts]
        if "high_emergency" in states:
            for d in HIGH_EMERGENCY_STOP:
                c[d] = 0
        elif "low_emergency" in states:
            for d in LOW_EMERGENCY_STOP:
                c[d] = 0
        if "fire" in cond:
            for d in FIRE_STOP:
                c[d] = 0
        if "water_low" in cond or "power" in cond:
            c["pump"] = 0
        return c

    def _clear_message(self, key):
        v = self.values
        if key == "temp":
            return f"온실 온도 정상 복귀 ({v['temperature']:.1f}℃)"
        if key.startswith("part:"):
            p = key[5:]
            return f"{NAMES[p]} 정상 복귀 ({v[p]:.1f}℃)"
        if key.startswith("rmu:"):
            return f"RMU 알람 {key[4:]} 해제"
        return {
            "humidity_high": "습도 정상 복귀", "humidity_low": "습도 정상 복귀",
            "water_low": f"수위 정상 복귀 ({v['water_level']:.0f}%)", "leak": "수위 하락 멈춤 (누수 의심 해소)",
            "fire": "화재 감지 해제", "power": "AC 전원 정상 복귀", "door": "전면 도어 닫힘",
            "intrusion": "야간 움직임 경보 해소", "fan": "환풍기 경보 해소", "fan_backup": "예비 환풍기 정상",
            "mismatch": "센서 불일치 해소", "stuck": "온도 값이 다시 변합니다 (고장 의심 해소)",
            "co2": "CO2 정상 복귀", "nutrient": "양분 정상 복귀", "soil_dry": "토양수분 정상 복귀",
        }.get(key, f"{key} 해소")

    def _add_event(self, now, level, etype, key, code, message, actions, ai=False):
        event = {
            "id": self.next_event_id, "time": now.isoformat(timespec="seconds"),
            "level": level, "type": etype, "key": key, "code": code,
            "trap": "farmAlarm" if etype in ("alarm", "clear") else None,
            "message": message, "actions": actions, "ai": ai,
        }
        self.next_event_id += 1
        self.events.append(event)
        del self.events[:-MAX_EVENTS]
        if self.storage is not None:
            self.storage.add_event(event)
        print(f"[{event['time']}] #{event['id']} 등급 {level} {etype:<7} | {message}"
              + (" | " + " / ".join(actions) if actions else ""))
        for listener in self.event_listeners:
            listener(event)
        return event

    def _record_events(self, now, cond, changes, default_message):
        auto = self.base["control_mode"] == 1
        new_events = []  # (level, type, key, code, message, guide, ai)
        for key, c in cond.items():
            old = self.active.get(key)
            if old is None or old["level"] != c["level"]:
                new_events.append((c["level"], "alarm", key, c["code"], c["message"], list(c["guide"]), c["ai"]))
        for key, old in self.active.items():
            if key not in cond:
                code = old["code"] + 100 if old["code"] else None  # 해제 코드 = 코드 + 100
                new_events.append((0, "clear", key, code, self._clear_message(key), [], old["ai"]))
        for level, key, message, guide, ai in self._notes:
            new_events.append((level, "info", key, None, message, list(guide), ai))
        self._notes = []
        if not new_events and changes:
            new_events.append((0, "control" if default_message else "action", "control", None,
                               default_message or "자동 조치", [], False))

        # 긴급 경보가 맨 앞: 알림을 먼저 보내고, 장치 정리 내역은 그 알림 상세에 남긴다
        new_events.sort(key=lambda e: -e[0])
        for i, (level, etype, key, code, message, guide, ai) in enumerate(new_events):
            actions = []
            if i == 0:
                actions = list(changes)
                if etype == "alarm" and level >= 2 and not auto and not changes:
                    actions.append("수동 모드라 자동 조치를 하지 않았습니다")
            self._add_event(now, level, etype, key, code, message, actions + guide, ai)
        self.active = cond

    # =======================================================================
    # API용
    # =======================================================================
    def alarm_level(self):
        return max((c["level"] for c in self.active.values()), default=0)

    def _top(self):
        return max(self.active.values(), key=lambda c: c["level"], default=None)

    def comm_lost(self):
        until = self.sim.comm_loss_until
        if until is None:
            return False
        if datetime.now().timestamp() >= until:
            self.sim.comm_loss_until = None
            return False
        return True

    def history_values(self):
        row = {}
        for k, val in self.values.items():
            row[k] = round(val, 2) if self.usable(k) else None
        row["greenhouse_power"] = self.greenhouse_power()
        row["alarm_level"] = self.alarm_level()
        return row

    def _val(self, name, digits):
        state = self.item_state(name)
        if state == "offline" and name in self.sim.rmu_frozen:
            return round(self.sim.rmu_frozen[name], digits)  # 마지막 수신값
        return round(self.values[name], digits) if state in ("ok", "offline") else None

    def _rmu_link(self):
        """라즈베리파이 ↔ RMU 연결 상태 (시뮬레이션 두절 포함)"""
        used = (self.rmu_used and self.mode == "live") or self.sim.rmu_offline
        if not used:
            return {"used": False, "connected": None, "last_seen": None}
        down = self.sim.rmu_offline or not self.rmu_connected
        seen = self.rmu_last_seen if self.rmu_used else None
        if self.sim.rmu_offline and seen is None:
            seen = self.sim.rmu_offline_since
        return {"used": True, "connected": not down,
                "last_seen": seen.isoformat(timespec="seconds") if seen else None}

    def status(self):
        with self.lock:
            top = self._top()
            states = {n: self.item_state(n) for n in
                      ["temperature", "temp2", "humidity", "hum_temp", "water_level", "fire",
                       "ac_voltage", "ac_frequency", "door_front", "ups_battery", *PARTS, *OPTIONAL]}
            fire = self._val("fire", 0)
            door = self._val("door_front", 0)
            return {
                "time": datetime.now().isoformat(timespec="seconds"),
                "mode": self.mode,
                "alarm_level": self.alarm_level(),
                "alarm_code": top["code"] if top else 0,
                "alarm_message": top["message"] if top else "",
                "conditions": [{"key": c["key"], "level": c["level"], "code": c["code"],
                                "message": c["message"], "ai": c["ai"]}
                               for c in sorted(self.active.values(), key=lambda c: -c["level"])],
                "sensors": {
                    "temperature": self._val("temperature", 1),
                    "temp2": self._val("temp2", 1),
                    "humidity": self._val("humidity", 1),
                    "hum_temp": self._val("hum_temp", 1),
                    "water_level": self._val("water_level", 0),
                    "fire": None if fire is None else fire >= 1,
                    "co2": self._val("co2", 0),
                    "soil_moisture": self._val("soil_moisture", 0),
                    "nutrient_ec": self._val("nutrient_ec", 2),
                },
                "states": states,
                "sensor_errors": sorted(n for n, s in states.items() if s == "fault"),
                "power": self._power_summary(),
                "part_temps": {p: self._val(p, 1) for p in PARTS},
                "door_open": None if door is None else door >= 1,
                "fans": {"main_ok": not self.fan_failed("main"), "backup_ok": not self.fan_failed("backup"),
                         "failover": self.failover_latched},
                "control": dict(self.control),
                "night": {**self.settings, "active": self.night_active},
                "ai": dict(self.ai),
                "rmu": self._rmu_link(),
            }

    def _power_summary(self):
        th = self.thresholds
        ac = self._val("ac_voltage", 1)  # RMU 두절이면 마지막 수신값, 정보없음·오류면 None
        return {
            "ac_voltage": ac,
            "ac_frequency": self._val("ac_frequency", 1),
            "power_ok": (not self.power_down() and ac is not None
                         and th["ac_voltage_low"] <= ac <= th["ac_voltage_high"]),
            "ups_battery": self._val("ups_battery", 0),
            "greenhouse_power": self.greenhouse_power(),
        }

    def power(self):
        with self.lock:
            th = self.thresholds
            return {
                "time": datetime.now().isoformat(timespec="seconds"),
                **self._power_summary(),
                "ac_voltage_low": th["ac_voltage_low"], "ac_voltage_high": th["ac_voltage_high"],
                "greenhouse_energy_kwh": round(self.energy_wh / 1000, 3),
                "devices": [{"name": d, "label": NAMES[d], "watts": w, "on": bool(self.running(d))}
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

    # ----- RMU 알람 (Trap / alarm 스칼라) --------------------------------------
    def handle_rmu_alarm(self, code, via="trap"):
        """RMU 알람 코드 받기. 해제 코드(코드+100)면 지운다. 시나리오 28."""
        with self.lock:
            if code <= 0:
                return
            if 100 < code < 200:
                self.rmu_alarms.pop(code - 100, None)
            else:
                if code not in self.rmu_alarms:
                    text = RMU_CODE_TEXT.get(code, (0, f"알 수 없는 코드 {code}"))[1]
                    self._notes.append((0, "rmu_trap", f"RMU {'Trap' if via == 'trap' else '알람'} 수신: 코드 {code} ({text})",
                                        ["라즈베리파이가 등급을 계산해 알립니다"], False))
                self.rmu_alarms[code] = datetime.now().timestamp()
            self._evaluate(datetime.now())

    # ----- 설정 ---------------------------------------------------------------
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
                              ("part_temp_low", "part_temp_high"), ("cooling_setpoint", "heating_setpoint"),
                              ("ac_voltage_low", "ac_voltage_high")]:
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

    def set_mode(self, mode):
        """AI 모드 전환 (시나리오 29)"""
        with self.lock:
            if mode not in ("demo", "live"):
                raise ValueError("mode는 demo 또는 live입니다")
            if mode != self.mode:
                self.mode = mode
                self.ai_active = self.ai_fan = False
                for s in self.suggestions:
                    if s["status"] == "pending":
                        s["status"] = "expired"
                self._notes.append((0, "mode", "AI 모드: 데모로 전환 (시뮬레이션 값, AI 자동 실행)" if mode == "demo"
                                    else "AI 모드: 실사용으로 전환 (실제 값, AI는 위험 낮은 조치만 자동)", [], False))
                self._evaluate(datetime.now())
            return {"mode": self.mode}

    # ----- AI 제안 (실사용 모드) ------------------------------------------------
    def list_suggestions(self):
        with self.lock:
            return [dict(s) for s in reversed(self.suggestions)]

    def decide_suggestion(self, sid, approve):
        with self.lock:
            s = next((x for x in self.suggestions if x["id"] == sid), None)
            if s is None:
                raise ControlError(404, "제안을 찾을 수 없습니다")
            if s["status"] != "pending":
                raise ControlError(409, f"이미 처리된 제안입니다 ({s['status']})")
            if s["action"]["device"] not in AI_ALLOW_LIST:
                raise ControlError(409, "허용 목록에 없는 조치입니다")
            if approve:
                if self.base["control_mode"] != 1:
                    raise ControlError(409, "수동 모드에서는 AI 조치를 실행하지 않습니다 (수동 조작 우선)")
                s["status"] = "approved"
                if s["kind"] == "precool":
                    self.ai_active = True
                    self.ai_started = datetime.now().timestamp()
                self._notes.append((0, "ai", f"AI 제안 승인: {s['title']}", [f"판단 이유: {s['reason']}"], True))
            else:
                s["status"] = "rejected"
                self._notes.append((0, "ai", f"AI 제안 거절: {s['title']}", [], True))
            self._evaluate(datetime.now(), "AI 제안 처리")
            return dict(s)

    # ----- 사용자 조작 -----------------------------------------------------------
    def apply_control(self, device, value):
        with self.lock:
            auto = self.base["control_mode"] == 1
            if device == "control_mode":
                if value not in (0, 1):
                    raise ControlError(400, "control_mode는 0(수동) 또는 1(자동)입니다")
                if value == 0 and auto:
                    self.saved_base = dict(self.base)
                    self.base = dict(self.control)
                    if self.night_active:
                        self.base["cover"] = self.saved_base["cover"]
                        self.base["lights"] = self.saved_base["lights"]
                    self.manual_start = dict(self.base)
                    self.pump_started_at = None
                    self.ai_active = self.ai_fan = False  # 수동 조작 우선
                elif value == 1 and not auto and self.saved_base is not None:
                    for k in self.base:
                        if self.base[k] == self.manual_start[k]:
                            self.base[k] = self.saved_base[k]
                    self.saved_base = None
                self.base["control_mode"] = value
            elif device == "restore_main_fan":
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

    # ----- 시뮬레이션 -------------------------------------------------------------
    def simulate(self, name, params):
        with self.lock:
            s = self.sim
            severe = bool(params.get("severe"))
            now = datetime.now()
            if name == "normal":
                faults_or_comm = s.sensor_faults or s.comm_loss_until
                self.sim = Sim()
                self.base = dict(DEFAULT_BASE)
                self.saved_base = None
                self.failover_latched = False
                self.pump_retry_at = 0.0
                self.rmu_alarms = {}
                self.values.update({"temperature": 25.0, "water_level": 80.0, "pi_temp": 48.0,
                                    "main_fan_temp": 35.0, "backup_fan_temp": 28.0, "cooling_fan_temp": 28.0})
                self.temp_samples, self.water_samples = [], []
                self.ai_active = self.ai_fan = False
                for sug in self.suggestions:
                    if sug["status"] == "pending":
                        sug["status"] = "expired"
                if faults_or_comm:
                    self._notes.append((0, "sim", "센서 오류·통신 두절 해제", [], False))
                return "모든 시뮬레이션과 장치 설정을 초기화했습니다"
            if name == "high_temp":
                s.heat = 0.8 if severe else 0.3
                s.ai_bypass = True
                return "고온 시작" + (" (냉방으로도 못 막음 → 긴급 경보)" if severe else " (냉방 후 복구)") + ", AI 선가동 끔"
            if name == "slow_heat":
                s.heat, s.ai_bypass = 0.2, False
                return "온도가 서서히 오릅니다. AI 선가동을 확인하세요"
            if name == "ai_live_demo":
                s.heat, s.ai_bypass = 0.2, False
                self.set_mode("live")
                return "실사용 모드로 바꾸고 온도를 서서히 올립니다. 쿨링팬은 자동, 에어컨은 제안 → 승인"
            if name == "low_temp":
                s.heat = -1.2 if severe else -0.6
                return "저온 시작" + (" (난방으로도 못 막음 → 긴급 경보)" if severe else " (난방 후 복구)")
            if name in ("part_high", "part_low"):
                part = params.get("part", "pi_temp")
                if part not in PARTS:
                    raise ValueError(f"part는 {PARTS} 중 하나입니다")
                load = 4.0 if severe else 2.0
                s.part_load[part] = load if name == "part_high" else -load * 1.5
                return f"{NAMES[part]} {'고온' if name == 'part_high' else '저온'} 시작" + (" (악화 → 긴급)" if severe else "")
            if name == "main_fan_fail":
                s.fan_failed["main"] = True
                return "메인 환풍기 고장"
            if name == "fans_fail":
                s.fan_failed = {"main": True, "backup": True}
                return "메인·예비 환풍기 모두 고장"
            if name == "fan_repair":
                s.fan_failed = {"main": False, "backup": False}
                if self.failover_latched:
                    self._notes.append((0, "fan", "메인 환풍기 복구됨. 확인 후 메인으로 전환하세요", [], False))
                return "환풍기 수리 완료 (메인 전환은 사용자가 확인 후 직접)"
            if name == "water_low":
                s.water_target = 10.0
                self.values["water_level"] = 15.0
                return "수위 부족 (물탱크가 거의 비었습니다)"
            if name == "water_leak":
                s.leak = True
                return "누수 흉내: 펌프가 꺼져 있는데 수위가 빨리 줄어듭니다 (AI 누수 의심)"
            if name == "water_refill":
                s.water_target, s.leak = 80.0, False
                self.values["water_level"] = 80.0
                return "물탱크를 채웠습니다"
            if name == "fire":
                s.fire = True
                return "화재 감지"
            if name == "fire_clear":
                s.fire = False
                return "화재 감지 해제"
            if name == "power_abnormal":
                s.ac_base = 250.0 if params.get("high", True) else 180.0
                return f"AC 전압 이상 ({s.ac_base:.0f}V)"
            if name == "power_cut":
                s.power_cut = True
                return "AC 전원 차단"
            if name == "power_restore":
                s.ac_base, s.power_cut = DEFAULT_AC, False
                return "전원 정상화"
            if name == "comm_loss":
                seconds = int(params.get("seconds", 30))
                s.comm_loss_until = now.timestamp() + seconds
                return f"통신 두절 {seconds}초 (그동안 라즈베리파이가 응답하지 않습니다)"
            if name == "comm_restore":
                s.comm_loss_until = None
                return "통신 복구"
            if name == "rmu_offline":
                if not s.rmu_offline:
                    s.rmu_offline = True
                    s.rmu_offline_since = now
                    s.rmu_frozen = {n: self.values[n] for n in RMU_ITEMS}
                return "RMU 통신 두절 흉내: RMU 항목(온도·전원)은 마지막 값을 회색으로 표시"
            if name == "rmu_online":
                s.rmu_offline, s.rmu_frozen, s.rmu_offline_since = False, {}, None
                return "RMU 통신 복구"
            if name == "sensor_fault":
                sensor = params.get("sensor", "humidity")
                if sensor not in SENSORS:
                    raise ValueError(f"sensor는 {SENSORS} 중 하나입니다")
                s.sensor_faults.add(sensor)
                self._notes.append((0, "sensor_fault", f"센서 오류: {NAMES[sensor]}", ["센서 연결을 확인하세요"], False))
                return f"{NAMES[sensor]} 센서 오류"
            if name == "sensor_restore":
                s.sensor_faults.clear()
                s.stuck = False
                self._notes.append((0, "sensor_fault", "센서 정상 복구", [], False))
                return "센서 오류 해제"
            if name == "sensor_mismatch":
                s.mismatch = 5.0
                return "온습도감지기 온도가 RMU 온도와 5℃ 어긋납니다 (30초 뒤 AI 불일치 판단)"
            if name == "sensor_match":
                s.mismatch = 0.0
                return "센서 불일치 해제"
            if name == "sensor_stuck":
                s.stuck = True
                return f"온도 값을 고정합니다 ({STUCK_SECONDS}초 뒤 AI 고장 의심)"
            if name == "night_on":
                s.night_override = True
                return "야간 모드 강제 진입"
            if name == "night_off":
                s.night_override = False
                return "야간 모드 강제 해제"
            if name == "night_auto":
                s.night_override = None
                return "야간 모드를 설정 시각대로"
            if name == "motion":
                if self.night_active:
                    s.motion_until = now.timestamp() + MOTION_ALARM_SECONDS
                    return "야간 움직임 감지"
                self._notes.append((0, "motion", "주간 움직임 감지 (야간이 아니어서 경보 없음)", [], False))
                return "주간이라 경보 없음"
            if name == "door_open":
                s.door_open = True
                return "전면 도어 열림 (RMU doorFront)"
            if name == "door_close":
                s.door_open = False
                return "전면 도어 닫힘"
            if name == "rmu_trap":
                code = int(params.get("code", 61))
                self.handle_rmu_alarm(code, via="trap")
                return f"RMU Trap 흉내: 알람 코드 {code} 수신"
            if name == "rmu_trap_clear":
                code = int(params.get("code", 61))
                self.handle_rmu_alarm(code + 100, via="trap")
                return f"RMU Trap 흉내: 해제 코드 {code + 100} 수신"
            if name in ("mode_demo", "mode_live"):
                self.set_mode(name[5:])
                return f"AI 모드를 {'데모' if name == 'mode_demo' else '실사용'}로 바꿨습니다"
            raise KeyError(name)


class ControlError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def _load_rmu_codes():
    """oids.json의 알람 코드 표 → {코드: (등급, 설명)}"""
    try:
        import oids as oidlib
        table = oidlib.load()["alarm_codes"]
        return {int(k): (v["level"], v["text"]) for k, v in table.items() if not k.startswith("_")}
    except Exception:
        return {}


RMU_CODE_TEXT = _load_rmu_codes()

# 앱의 시뮬레이션 화면 버튼 (GET /api/simulate). scenario = CLAUDE.md 8장 번호
SCENARIOS = [
    {"name": "normal", "label": "전부 정상으로", "scenario": 1},
    {"name": "high_temp", "label": "고온 → 냉방 → 복구", "scenario": 2},
    {"name": "high_temp", "label": "고온 지속 → 긴급", "scenario": 3, "params": {"severe": True}},
    {"name": "low_temp", "label": "저온 → 난방 → 복구", "scenario": 4},
    {"name": "low_temp", "label": "저온 지속 → 긴급", "scenario": 5, "params": {"severe": True}},
    {"name": "part_high", "label": "라즈베리파이 온도 높음", "scenario": 6, "params": {"part": "pi_temp"}},
    {"name": "part_high", "label": "쿨링팬 온도 높음 → 긴급", "scenario": 6,
     "params": {"part": "cooling_fan_temp", "severe": True}},
    {"name": "part_low", "label": "메인 환풍기 온도 낮음", "scenario": 6, "params": {"part": "main_fan_temp"}},
    {"name": "main_fan_fail", "label": "메인 환풍기 고장", "scenario": 7},
    {"name": "fan_repair", "label": "환풍기 수리", "scenario": 7},
    {"name": "fans_fail", "label": "환풍기 둘 다 고장", "scenario": 8},
    {"name": "water_low", "label": "수위 부족", "scenario": 9},
    {"name": "water_refill", "label": "물탱크 채우기", "scenario": 9},
    {"name": "fire", "label": "화재 감지", "scenario": 10},
    {"name": "fire_clear", "label": "화재 해제", "scenario": 10},
    {"name": "power_abnormal", "label": "AC 전압 이상", "scenario": 11},
    {"name": "power_cut", "label": "AC 전원 차단", "scenario": 11},
    {"name": "power_restore", "label": "전원 정상화", "scenario": 11},
    {"name": "comm_loss", "label": "통신 두절 30초", "scenario": 13, "params": {"seconds": 30}},
    {"name": "comm_restore", "label": "통신 복구", "scenario": 13},
    {"name": "rmu_offline", "label": "RMU 통신 두절", "scenario": 13},
    {"name": "rmu_online", "label": "RMU 통신 복구", "scenario": 13},
    {"name": "sensor_fault", "label": "습도 센서 오류", "scenario": 14, "params": {"sensor": "humidity"}},
    {"name": "sensor_restore", "label": "센서 오류 해제", "scenario": 14},
    {"name": "night_on", "label": "야간 모드 진입", "scenario": 15},
    {"name": "night_off", "label": "야간 모드 해제", "scenario": 15},
    {"name": "night_auto", "label": "야간 모드 시각대로", "scenario": 15},
    {"name": "motion", "label": "CCTV 움직임 감지", "scenario": 16},
    {"name": "door_open", "label": "전면 도어 열림", "scenario": 16},
    {"name": "door_close", "label": "전면 도어 닫힘", "scenario": 16},
    {"name": "slow_heat", "label": "온도 서서히 상승 (AI 선가동)", "scenario": 25},
    {"name": "ai_live_demo", "label": "실사용 AI: 제안·승인 흉내", "scenario": 26},
    {"name": "sensor_mismatch", "label": "센서 불일치 (AI)", "scenario": 27},
    {"name": "sensor_match", "label": "센서 불일치 해제", "scenario": 27},
    {"name": "sensor_stuck", "label": "온도 값 고정 (AI)", "scenario": 27},
    {"name": "water_leak", "label": "누수 의심 (AI)", "scenario": 27},
    {"name": "rmu_trap", "label": "RMU Trap: UPS 배터리 낮음", "scenario": 28, "params": {"code": 61}},
    {"name": "rmu_trap_clear", "label": "RMU Trap: 해제", "scenario": 28, "params": {"code": 61}},
    {"name": "mode_live", "label": "실사용 모드로", "scenario": 29},
    {"name": "mode_demo", "label": "데모 모드로", "scenario": 29},
]
