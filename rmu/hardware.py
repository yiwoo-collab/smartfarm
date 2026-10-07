"""
라즈베리파이 하드웨어 (1단계 실물).

실물 (CLAUDE.md 9장)
  - 온습도 BME280 (I2C)
  - 토양수분 + ADS1115 (I2C)
  - 공급 전압·전류 INA219 (I2C)
  - RMU 온도: CPU 온도 파일
  - 릴레이: 메인/예비 환풍기, 쿨링팬, 펌프 (외부 전원)
  - (선택) 팬 회전 신호로 고장 감지

라이브러리가 없거나 센서가 응답하지 않으면 그 항목은 None을 돌려준다.
None인 센서는 RmuModel이 '센서 오류'로 표시한다 (시나리오 13).
PC에서는 라이브러리가 없어서 모든 항목이 '없음'으로 시작한다.
"""

import json
import os
import time

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hardware_config.json")

# 실물 센서가 공급하는 값 이름 (rmu_model.values의 키와 같음)
REAL_SENSORS = ["temperature", "humidity", "soil_moisture", "supply_voltage", "supply_current", "rmu_temp"]


def _addr(text):
    return int(text, 16) if isinstance(text, str) else text


class Hardware:
    def __init__(self, config_path=CONFIG_PATH):
        with open(config_path, encoding="utf-8") as f:
            self.cfg = json.load(f)
        self.available = {}   # 장치 이름 → 연결 성공 여부 (시작할 때 출력)
        self._i2c = None
        self._bme = self._ads_chan = self._ina = None
        self._relays = {}
        self._tach = {}       # 팬 이름 → [마지막 회전 신호 시각]
        self._fan_on_since = {}
        self._init_i2c_devices()
        self._init_relays()
        self._init_tach()

    # ----- 초기화 ------------------------------------------------------------
    def _get_i2c(self):
        if self._i2c is None:
            import board
            import busio
            self._i2c = busio.I2C(board.SCL, board.SDA)
        return self._i2c

    def _try(self, name, func):
        """장치 초기화. 실패해도 멈추지 않고 '없음'으로 기록한다."""
        try:
            result = func()
            self.available[name] = True
            return result
        except Exception as e:  # 라이브러리 없음, 배선 문제 등
            self.available[name] = False
            print(f"[hardware] {name} 사용 안 함: {type(e).__name__}: {e}")
            return None

    def _init_i2c_devices(self):
        c = self.cfg
        if c["bme280"]["enabled"]:
            def bme():
                from adafruit_bme280 import basic as adafruit_bme280
                return adafruit_bme280.Adafruit_BME280_I2C(self._get_i2c(), address=_addr(c["bme280"]["address"]))
            self._bme = self._try("bme280", bme)
        if c["ads1115"]["enabled"]:
            def ads():
                import adafruit_ads1x15.ads1115 as ADS
                from adafruit_ads1x15.analog_in import AnalogIn
                dev = ADS.ADS1115(self._get_i2c(), address=_addr(c["ads1115"]["address"]))
                pin = [ADS.P0, ADS.P1, ADS.P2, ADS.P3][c["ads1115"]["soil_channel"]]
                return AnalogIn(dev, pin)
            self._ads_chan = self._try("ads1115", ads)
        if c["ina219"]["enabled"]:
            def ina():
                from adafruit_ina219 import INA219
                return INA219(self._get_i2c(), addr=_addr(c["ina219"]["address"]))
            self._ina = self._try("ina219", ina)
        self.available["cpu_temp"] = os.path.exists(c["cpu_temp_path"])

    def _init_relays(self):
        relays = self.cfg["relays"]
        for device, pin in relays["pins"].items():
            def make(pin=pin):
                from gpiozero import OutputDevice
                return OutputDevice(pin, active_high=not relays["active_low"], initial_value=False)
            dev = self._try(f"relay:{device}", make)
            if dev is not None:
                self._relays[device] = dev

    def _init_tach(self):
        for fan, pin in self.cfg["fan_tach"]["pins"].items():
            if pin is None:
                continue
            def make(pin=pin, fan=fan):
                from gpiozero import DigitalInputDevice
                dev = DigitalInputDevice(pin, pull_up=True)
                self._tach[fan] = [0.0]
                dev.when_activated = lambda: self._tach[fan].__setitem__(0, time.monotonic())
                return dev
            self._try(f"tach:{fan}", make)

    # ----- 읽기 --------------------------------------------------------------
    def read(self):
        """센서 값 읽기. {이름: 값 또는 None}. None = 읽기 실패(센서 오류)."""
        values = {}
        if self.available.get("bme280"):
            values["temperature"] = self._safe(lambda: self._bme.temperature)
            values["humidity"] = self._safe(lambda: self._bme.relative_humidity)
        if self.available.get("ads1115"):
            values["soil_moisture"] = self._safe(self._read_soil)
        if self.available.get("ina219"):
            # 공급 전압 = 버스 전압 + 션트 전압
            values["supply_voltage"] = self._safe(lambda: self._ina.bus_voltage + self._ina.shunt_voltage / 1000)
            values["supply_current"] = self._safe(lambda: max(0.0, self._ina.current / 1000))
        if self.available.get("cpu_temp"):
            values["rmu_temp"] = self._safe(self._read_cpu_temp)
        return values

    @staticmethod
    def _safe(func):
        try:
            return float(func())
        except Exception:
            return None

    def _read_soil(self):
        """ADS1115 raw 값 → 토양수분 % (마른 값 0%, 젖은 값 100%로 직선 보정)"""
        c = self.cfg["ads1115"]
        raw = self._ads_chan.value
        pct = (c["soil_dry_raw"] - raw) / (c["soil_dry_raw"] - c["soil_wet_raw"]) * 100
        return max(0.0, min(100.0, pct))

    def _read_cpu_temp(self):
        with open(self.cfg["cpu_temp_path"]) as f:
            return int(f.read().strip()) / 1000  # 밀리도 → ℃

    def fan_failures(self, control):
        """회전 신호로 팬 고장 판정. {팬: True(고장)/False}. 감지 핀이 없는 팬은 빠진다.
        켜라는 명령 후 timeout 초 동안 회전 신호가 없으면 고장 (CLAUDE.md 7장 제안)."""
        timeout = self.cfg["fan_tach"]["timeout_seconds"]
        now = time.monotonic()
        result = {}
        for fan, last in self._tach.items():
            if not control.get(fan):
                self._fan_on_since.pop(fan, None)
                result[fan] = False
                continue
            on_since = self._fan_on_since.setdefault(fan, now)
            started_long_ago = now - on_since >= timeout
            result[fan] = started_long_ago and now - last[0] >= timeout
        return result

    # ----- 쓰기 --------------------------------------------------------------
    def apply(self, control):
        """장치 출력을 릴레이에 반영. 릴레이가 없는 장치(에어컨 등)는 시뮬레이션."""
        for device, relay in self._relays.items():
            try:
                relay.value = bool(control.get(device))
            except Exception as e:
                print(f"[hardware] 릴레이 {device} 쓰기 실패: {e}")

    def close(self):
        for relay in self._relays.values():
            try:
                relay.off()
                relay.close()
            except Exception:
                pass

    def summary(self):
        ok = [k for k, v in self.available.items() if v]
        missing = [k for k, v in self.available.items() if not v]
        return f"실물 연결: {', '.join(ok) or '없음'} / 사용 안 함: {', '.join(missing) or '없음'}"
