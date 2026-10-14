"""
라즈베리파이 직결 감지기·릴레이 (CLAUDE.md 1·9장, v3.0).

  - 온습도감지기 (BME280 I2C 또는 DHT22)  → humidity, hum_temp
  - 화재감지기 (접점 출력, GPIO)          → fire (0/1)
  - 수위감지기 (플로트 스위치 또는 ADS1115) → water_level (%)
  - 라즈베리파이 CPU 온도                  → pi_temp
  - 릴레이: 메인/예비 환풍기, 쿨링팬, 펌프 (외부 전원)
  - (선택) 팬 회전 신호

온도(temp1)·전원(acv1)은 RMU 실물에서 SNMP로 읽는다 (rmu_client.py).
라이브러리가 없거나 장치가 응답하지 않으면 그 항목은 None → '센서 오류'로 표시된다.
"""

import json
import os
import time

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hardware_config.json")

# 라즈베리파이가 직접 읽는 값 이름
PI_SENSORS = ["humidity", "hum_temp", "fire", "water_level", "pi_temp"]


def _addr(text):
    return int(text, 16) if isinstance(text, str) else text


class Hardware:
    def __init__(self, config_path=CONFIG_PATH):
        with open(config_path, encoding="utf-8") as f:
            self.cfg = json.load(f)
        self.available = {}
        self._i2c = None
        self._bme = self._dht = self._fire = self._water = self._water_adc = None
        self._relays = {}
        self._tach = {}
        self._fan_on_since = {}
        self._init_sensors()
        self._init_relays()
        self._init_tach()

    def _get_i2c(self):
        if self._i2c is None:
            import board
            import busio
            self._i2c = busio.I2C(board.SCL, board.SDA)
        return self._i2c

    def _try(self, name, func):
        try:
            result = func()
            self.available[name] = True
            return result
        except Exception as e:
            self.available[name] = False
            print(f"[hardware] {name} 사용 안 함: {type(e).__name__}: {e}")
            return None

    def _init_sensors(self):
        c = self.cfg
        hs = c["humidity_sensor"]
        if hs["enabled"]:
            if hs["type"] == "bme280":
                def bme():
                    from adafruit_bme280 import basic as adafruit_bme280
                    return adafruit_bme280.Adafruit_BME280_I2C(self._get_i2c(), address=_addr(hs["address"]))
                self._bme = self._try("humidity:bme280", bme)
            else:
                def dht():
                    import adafruit_dht
                    import board
                    return adafruit_dht.DHT22(getattr(board, f"D{hs['pin']}"))
                self._dht = self._try("humidity:dht22", dht)

        fs = c["fire_sensor"]
        if fs["enabled"]:
            def fire():
                from gpiozero import DigitalInputDevice
                return DigitalInputDevice(fs["pin"], pull_up=fs["active_low"])
            self._fire = self._try("fire", fire)

        ws = c["water_level"]
        if ws["enabled"]:
            if ws["mode"] == "analog":
                def adc():
                    import adafruit_ads1x15.ads1115 as ADS
                    from adafruit_ads1x15.analog_in import AnalogIn
                    dev = ADS.ADS1115(self._get_i2c(), address=_addr(ws["ads1115_address"]))
                    return AnalogIn(dev, [ADS.P0, ADS.P1, ADS.P2, ADS.P3][ws["channel"]])
                self._water_adc = self._try("water_level:analog", adc)
            else:
                def switch():
                    from gpiozero import DigitalInputDevice
                    return DigitalInputDevice(ws["pin"], pull_up=ws["active_low"])
                self._water = self._try("water_level:digital", switch)

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

    # ----- 읽기 ----------------------------------------------------------------
    @staticmethod
    def _safe(func):
        try:
            return float(func())
        except Exception:
            return None

    def read(self):
        """{이름: 값 또는 None}. 연결하지 않은(설정에서 끈) 항목은 빠진다."""
        v = {}
        if self._bme is not None:
            v["humidity"] = self._safe(lambda: self._bme.relative_humidity)
            v["hum_temp"] = self._safe(lambda: self._bme.temperature)
        elif self._dht is not None:
            v["humidity"] = self._safe(lambda: self._dht.humidity)
            v["hum_temp"] = self._safe(lambda: self._dht.temperature)
        if self._fire is not None:
            v["fire"] = self._safe(lambda: 1 if self._fire.value else 0)
        if self._water is not None:
            v["water_level"] = self._safe(lambda: 100 if self._water.value else 0)
        elif self._water_adc is not None:
            v["water_level"] = self._safe(self._read_water_adc)
        if self.available.get("cpu_temp"):
            v["pi_temp"] = self._safe(self._read_cpu_temp)
        return v

    def _read_water_adc(self):
        c = self.cfg["water_level"]
        pct = (self._water_adc.value - c["empty_raw"]) / (c["full_raw"] - c["empty_raw"]) * 100
        return max(0.0, min(100.0, pct))

    def _read_cpu_temp(self):
        with open(self.cfg["cpu_temp_path"]) as f:
            return int(f.read().strip()) / 1000

    def fan_failures(self, control):
        timeout = self.cfg["fan_tach"]["timeout_seconds"]
        now = time.monotonic()
        result = {}
        for fan, last in self._tach.items():
            if not control.get(fan):
                self._fan_on_since.pop(fan, None)
                result[fan] = False
                continue
            on_since = self._fan_on_since.setdefault(fan, now)
            result[fan] = now - on_since >= timeout and now - last[0] >= timeout
        return result

    # ----- 쓰기 ----------------------------------------------------------------
    def apply(self, control):
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
