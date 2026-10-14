"""
CLAUDE.md 8장 시나리오(v3.0)를 규칙 엔진으로 빠르게 확인한다. 실제 시간을 기다리지 않고 1초씩 tick.

실행:  python -m unittest test_scenarios -v     (rmu 폴더에서)
"""

import json
import os
import random
import unittest
from datetime import datetime, timedelta

from rmu_model import ControlError, RmuModel, in_night_window

NOON = datetime(2026, 10, 14, 12, 0, 0)


class ScenarioTest(unittest.TestCase):
    def setUp(self):
        random.seed(1)
        self.m = RmuModel()
        self.now = NOON
        self.run_ticks(5)

    def tick(self):
        self.now += timedelta(seconds=1)
        self.m.tick(self.now)

    def run_ticks(self, n):
        for _ in range(n):
            self.tick()

    def run_until(self, check, max_ticks=300, what=""):
        for _ in range(max_ticks):
            self.tick()
            if check():
                return
        self.fail(f"{max_ticks}초 안에 조건을 만족하지 않음: {what}")

    def level(self):
        return self.m.alarm_level()

    def ctl(self, name):
        return self.m.control[name]

    def codes(self):
        return {c["code"] for c in self.m.active.values()}

    def all_actions(self):
        return " / ".join(a for e in self.m.events for a in e["actions"])

    # ----- 1~5 온도 ------------------------------------------------------------
    def test_01_normal(self):
        self.run_ticks(120)
        self.assertEqual(self.level(), 0)
        self.assertEqual([e for e in self.m.events if e["type"] == "alarm"], [])

    def test_02_high_temp_cool_and_restore(self):
        self.m.simulate("high_temp", {})
        self.run_until(lambda: self.level() == 2, what="고온 경보")
        self.assertEqual(self.ctl("aircon_setpoint"), 22.0)
        self.assertEqual(self.ctl("cooling_fan"), 1)
        self.assertIn(9, self.codes())  # RMU temp1 코드 9를 우리 임계값으로 재판정
        self.run_until(lambda: self.level() == 0, what="복구")
        self.assertEqual(self.ctl("aircon_setpoint"), 25.0)
        clear = [e for e in self.m.events if e["type"] == "clear"][-1]
        self.assertEqual(clear["code"], 109)  # 해제 코드 = 코드 + 100

    def test_03_high_temp_emergency(self):
        self.m.simulate("high_temp", {"severe": True})
        self.run_until(lambda: self.level() == 3, what="고온 긴급")
        self.assertEqual(self.ctl("cooling_fan"), 1)
        self.assertEqual(self.ctl("heater"), 0)
        self.assertEqual(self.ctl("lights"), 0)

    def test_03_step_jump_waits_before_emergency(self):
        # RMU 값이 갑자기 35℃로 뛰어도 1초 만에 긴급으로 가지 않는다 (냉방이 효과를 낼 시간)
        self.m.sim.stuck = True                 # 물리 흉내를 멈추고 값을 직접 고정
        self.m.values["temperature"] = 35.0
        self.run_ticks(5)
        self.assertEqual(self.level(), 2)
        self.run_ticks(40)
        self.assertEqual(self.level(), 2)
        self.run_until(lambda: self.level() == 3, max_ticks=30, what="60초 뒤 긴급")
        # 정상으로 돌아오면 AI는 경보 전후 값으로 상승을 오판하지 않는다
        self.m.values["temperature"] = 25.0
        self.run_until(lambda: self.m.temp_state == "normal", max_ticks=5, what="정상 복귀")
        self.m.sim.stuck = False
        self.run_ticks(30)
        self.assertFalse(self.m.ai_active)

    def test_04_05_low_temp(self):
        self.m.simulate("low_temp", {})
        self.run_until(lambda: self.level() == 2, what="저온 경보")
        self.assertEqual(self.ctl("heater"), 1)
        self.run_until(lambda: self.level() == 0, what="복구")
        self.m.simulate("low_temp", {"severe": True})
        self.run_until(lambda: self.level() == 3, what="저온 긴급")
        self.assertEqual(self.ctl("heater"), 1)
        self.assertEqual(self.ctl("aircon"), 0)

    # ----- 6~11 장비·환경 --------------------------------------------------------
    def test_06_part_temp(self):
        self.m.simulate("part_high", {"part": "pi_temp"})
        self.run_until(lambda: self.level() == 1, what="라즈베리파이 온도 주의")
        self.assertIn(207, self.codes())
        self.run_until(lambda: self.level() == 0, what="복구")
        self.m.simulate("part_low", {"part": "main_fan_temp"})
        self.run_until(lambda: self.level() == 1, what="부품 저온")
        self.assertEqual(self.ctl("heater"), 1)

    def test_07_08_fans(self):
        self.m.simulate("main_fan_fail", {})
        self.tick()
        self.assertEqual(self.level(), 2)
        self.assertEqual(self.ctl("backup_fan"), 1)
        self.assertIn(208, self.codes())
        self.m.simulate("fan_repair", {})
        self.run_ticks(2)
        self.assertEqual(self.ctl("main_fan"), 0)  # 자동 복귀하지 않음
        self.m.apply_control("restore_main_fan", None)
        self.assertEqual(self.ctl("main_fan"), 1)
        self.m.simulate("fans_fail", {})
        self.tick()
        self.assertEqual(self.level(), 3)

    def test_09_water_low(self):
        self.m.simulate("water_low", {})
        self.tick()
        self.assertIn("water_low", self.m.active)
        self.assertEqual(self.m.active["water_low"]["code"], 202)
        self.assertEqual(self.ctl("pump"), 0)  # 펌프 제한
        self.m.simulate("water_refill", {})
        self.run_until(lambda: "water_low" not in self.m.active, what="수위 복구")

    def test_10_fire(self):
        self.m.base["heater"] = 1
        self.m.simulate("fire", {})
        self.tick()
        self.assertEqual(self.level(), 3)
        self.assertEqual(self.m.active["fire"]["code"], 203)
        self.assertEqual(self.ctl("heater"), 0)  # 열원 정지
        self.assertEqual(self.ctl("lights"), 0)
        first = [e for e in self.m.events if e["key"] == "fire"][0]
        self.assertTrue(any("오감지" in a for a in first["actions"]))
        self.m.simulate("fire_clear", {})
        self.tick()
        self.assertNotIn("fire", self.m.active)

    def test_11_power(self):
        self.m.simulate("power_abnormal", {})
        self.run_until(lambda: "power" in self.m.active, what="AC 전압 이상")
        self.assertEqual(self.m.active["power"]["code"], 1)
        self.assertFalse(self.m.status()["power"]["power_ok"])
        self.m.simulate("power_cut", {})
        self.tick()
        self.assertIn("차단", self.m.active["power"]["message"])
        self.assertFalse(self.m.running("main_fan"))
        self.m.simulate("power_restore", {})
        self.run_until(lambda: "power" not in self.m.active, what="전원 복구")

    # ----- 12~14 정보없음·두절·오류 ---------------------------------------------------
    def test_12_nodata(self):
        st = self.m.status()
        for name in ("co2", "soil_moisture", "nutrient_ec"):
            self.assertIsNone(st["sensors"][name])  # 0이나 마지막 값으로 채우지 않는다
            self.assertEqual(st["states"][name], "nodata")
        self.assertNotIn(204, self.codes())  # 판정에서 제외

    def test_13_comm_loss_and_rmu_offline(self):
        self.m.simulate("comm_loss", {"seconds": 30})
        self.assertTrue(self.m.comm_lost())
        self.m.simulate("comm_restore", {})
        self.assertFalse(self.m.comm_lost())
        # 실사용 모드에서 RMU가 안 닿으면 RMU 항목은 offline (마지막 값 유지)
        m = RmuModel(mode="live")
        m.rmu_used = True
        m.set_external({"temperature": 24.0, "ac_voltage": 221.0}, "rmu")
        m.tick()
        self.assertEqual(m.status()["states"]["temperature"], "ok")
        m.set_rmu_offline()
        m.tick()
        st = m.status()
        self.assertEqual(st["states"]["temperature"], "offline")
        self.assertIsNotNone(st["rmu"]["last_seen"])

    def test_13_rmu_offline_demo(self):
        # 데모 모드에서도 RMU 두절 흉내: RMU 항목만 회색(마지막 값 고정), 라즈베리파이 항목은 그대로
        self.m.simulate("rmu_offline", {})
        frozen = self.m.status()["sensors"]["temperature"]
        self.m.simulate("high_temp", {})
        self.run_ticks(60)
        st = self.m.status()
        self.assertEqual(st["states"]["temperature"], "offline")
        self.assertEqual(st["states"]["humidity"], "ok")
        self.assertEqual(st["sensors"]["temperature"], frozen)
        self.assertEqual(st["rmu"]["connected"], False)
        self.assertNotIn("temp", self.m.active)  # 두절된 값으로 판정하지 않는다
        self.m.simulate("rmu_online", {})
        self.tick()
        self.assertEqual(self.m.status()["states"]["temperature"], "ok")
        self.assertEqual(self.m.status()["rmu"]["used"], False)

    def test_14_sensor_fault(self):
        self.m.simulate("sensor_fault", {"sensor": "humidity"})
        self.tick()
        st = self.m.status()
        self.assertIsNone(st["sensors"]["humidity"])
        self.assertEqual(st["states"]["humidity"], "fault")
        self.assertEqual(st["states"]["temperature"], "ok")

    # ----- 15~17 야간 -----------------------------------------------------------
    def test_15_16_17_night(self):
        self.m.simulate("night_on", {})
        self.tick()
        self.assertEqual(self.ctl("cover"), 1)
        self.assertEqual(self.ctl("lights"), 0)
        self.m.simulate("motion", {})
        self.tick()
        self.assertIn(210, self.codes())
        self.m.simulate("door_open", {})
        self.tick()
        self.assertIn("침입", self.m.active["door"]["message"])
        self.m.simulate("door_close", {})
        self.m.simulate("high_temp", {})
        self.run_until(lambda: "temp" in self.m.active, what="야간 고온")
        self.assertEqual(self.ctl("backup_fan"), 1)  # 환기 먼저
        self.assertEqual(self.ctl("lights"), 0)

    # ----- 24 수동/자동, 25~27 AI, 28 Trap, 29 모드 ----------------------------------
    def test_24_manual_lock(self):
        with self.assertRaises(ControlError):
            self.m.apply_control("heater", 1)
        self.m.apply_control("control_mode", 0)
        self.m.apply_control("heater", 1)
        self.assertEqual(self.ctl("heater"), 1)

    def test_25_ai_precool_demo(self):
        self.m.simulate("slow_heat", {})
        self.run_until(lambda: self.m.ai_active, max_ticks=60, what="AI 선가동")
        self.assertLess(self.m.values["temperature"], 30)
        self.assertEqual(self.ctl("aircon_setpoint"), 22.0)  # 데모: 자동 실행
        ai_event = [e for e in self.m.events if e["key"] == "ai"][0]
        self.assertTrue(ai_event["ai"])
        self.assertTrue(any("판단 이유" in a for a in ai_event["actions"]))

    def test_26_ai_live_suggestion(self):
        self.m.simulate("ai_live_demo", {})
        self.assertEqual(self.m.mode, "live")
        self.run_until(lambda: self.m.ai_fan, max_ticks=60, what="쿨링팬 자동")
        self.assertEqual(self.ctl("cooling_fan"), 1)        # 위험 낮은 조치: 자동
        self.assertEqual(self.ctl("aircon_setpoint"), 25.0)  # 위험 높은 조치: 아직 안 함
        pending = [s for s in self.m.list_suggestions() if s["status"] == "pending"]
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["risk"], "high")
        self.m.decide_suggestion(pending[0]["id"], True)
        self.assertEqual(self.ctl("aircon_setpoint"), 22.0)  # 승인 후 실행
        with self.assertRaises(ControlError):
            self.m.decide_suggestion(pending[0]["id"], True)  # 두 번 승인 안 됨

    def test_27_ai_sensor_checks(self):
        self.m.simulate("sensor_mismatch", {})
        self.run_until(lambda: "mismatch" in self.m.active, max_ticks=60, what="센서 불일치")
        self.assertEqual(self.m.active["mismatch"]["code"], 209)
        self.assertTrue(self.m.active["mismatch"]["ai"])
        self.m.simulate("sensor_match", {})
        self.run_until(lambda: "mismatch" not in self.m.active, max_ticks=10, what="불일치 해소")
        self.m.simulate("water_leak", {})
        self.run_until(lambda: "leak" in self.m.active, max_ticks=60, what="누수 의심")
        self.m.simulate("water_refill", {})
        self.m.simulate("sensor_stuck", {})
        self.run_until(lambda: "stuck" in self.m.active, max_ticks=200, what="값 고정")

    def test_28_rmu_trap(self):
        self.m.simulate("rmu_trap", {"code": 61})
        self.assertEqual(self.m.active["rmu:61"]["level"], 2)  # UPS 배터리 낮음 → 2단계
        self.assertTrue(any(e["key"] == "rmu_trap" for e in self.m.events))
        self.m.simulate("rmu_trap_clear", {"code": 61})
        self.assertNotIn("rmu:61", self.m.active)
        self.m.handle_rmu_alarm(98)  # UPS 통신 장애 → 1단계
        self.assertEqual(self.m.active["rmu:98"]["level"], 1)

    def test_29_mode_switch(self):
        self.assertEqual(self.m.status()["mode"], "demo")
        self.m.set_mode("live")
        self.assertEqual(self.m.status()["mode"], "live")
        with self.assertRaises(ValueError):
            self.m.set_mode("auto")

    def test_crop_presets_recover(self):
        crops = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "crops.json"),
                               encoding="utf-8"))["crops"]
        for crop, values in crops.items():
            for scenario in ("high_temp", "low_temp"):
                with self.subTest(crop=crop, scenario=scenario):
                    random.seed(2)
                    self.m = RmuModel()
                    self.m.update_thresholds(values)
                    self.run_ticks(5)
                    self.m.simulate(scenario, {})
                    self.run_until(lambda: self.level() == 2, what=f"{crop} {scenario}")
                    self.run_until(lambda: self.level() == 0, what=f"{crop} 복구")

    def test_night_window(self):
        self.assertTrue(in_night_window(22 * 60, 21 * 60, 6 * 60))
        self.assertTrue(in_night_window(3 * 60, 21 * 60, 6 * 60))
        self.assertFalse(in_night_window(12 * 60, 21 * 60, 6 * 60))
        with self.assertRaises(ValueError):
            self.m.update_settings({"night_start": 300, "night_end": 300})


if __name__ == "__main__":
    unittest.main()
