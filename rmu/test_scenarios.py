"""
CLAUDE.md 8장 시나리오를 모의 RMU 규칙으로 빠르게 확인하는 테스트.
실제 시간을 기다리지 않고 tick()을 1초 단위로 직접 돌린다.

실행:  python -m unittest test_scenarios -v     (mock_rmu 폴더에서)
"""

import random
import unittest
from datetime import datetime, timedelta

from rmu_model import ControlError, RmuModel, in_night_window

NOON = datetime(2026, 10, 7, 12, 0, 0)  # 낮 12시 (야간 모드 아님)


class ScenarioTest(unittest.TestCase):
    def setUp(self):
        random.seed(1)
        self.m = RmuModel()
        self.now = NOON
        self.run_ticks(5)

    # ----- 도우미 ------------------------------------------------------------
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

    def events(self, etype=None):
        return [e for e in self.m.events if etype is None or e["type"] == etype]

    def all_actions(self):
        return " / ".join(a for e in self.m.events for a in e["actions"])

    # ----- 시나리오 ----------------------------------------------------------
    def test_01_normal(self):
        self.run_ticks(120)
        self.assertEqual(self.level(), 0)
        self.assertEqual(self.events(), [])

    def test_02_high_temp_cool_and_restore(self):
        self.m.simulate("high_temp", {})
        self.run_until(lambda: self.level() == 2, what="고온 경보")
        self.assertEqual(self.ctl("aircon_setpoint"), 22.0)
        self.assertEqual(self.ctl("cooling_fan"), 1)
        self.assertIn("25.0℃에서 22.0℃로 낮췄습니다", self.all_actions())
        self.run_until(lambda: self.level() == 0, what="복구")
        self.assertEqual(self.ctl("aircon_setpoint"), 25.0)  # 원래 값으로 복원
        self.assertEqual(self.ctl("cooling_fan"), 0)
        self.assertEqual(self.events("clear")[-1]["key"], "temp")

    def test_03_high_temp_emergency(self):
        self.m.base["lights"] = 1
        self.m.simulate("high_temp", {"severe": True})
        self.run_until(lambda: self.level() == 3, what="고온 긴급")
        self.assertEqual(self.ctl("aircon"), 1)
        self.assertEqual(self.ctl("cooling_fan"), 1)
        self.assertEqual(self.ctl("main_fan"), 1)
        self.assertEqual(self.ctl("heater"), 0)
        self.assertEqual(self.ctl("lights"), 0)
        emergency = [e for e in self.events("alarm") if e["level"] == 3][0]
        self.assertIn("전구를 모두 소등했습니다", emergency["actions"])

    def test_04_low_temp_heat_and_restore(self):
        self.m.simulate("low_temp", {})
        self.run_until(lambda: self.level() == 2, what="저온 경보")
        self.assertEqual(self.ctl("heater"), 1)
        self.assertEqual(self.ctl("aircon_setpoint"), 28.0)
        self.run_until(lambda: self.level() == 0, what="복구")
        self.assertEqual(self.ctl("heater"), 0)
        self.assertEqual(self.ctl("aircon_setpoint"), 25.0)

    def test_05_low_temp_emergency(self):
        self.m.simulate("low_temp", {"severe": True})
        self.run_until(lambda: self.level() == 3, what="저온 긴급")
        self.assertEqual(self.ctl("heater"), 1)
        self.assertEqual(self.ctl("aircon"), 0)
        self.assertEqual(self.ctl("cooling_fan"), 0)

    def test_06_part_temp(self):
        self.m.simulate("part_high", {"part": "rmu_temp"})
        self.run_until(lambda: self.level() == 1, what="RMU 온도 주의")
        self.assertEqual(self.ctl("cooling_fan"), 1)
        self.run_until(lambda: self.level() == 0, what="RMU 온도 복구")
        self.assertEqual(self.ctl("cooling_fan"), 0)

        self.m.simulate("part_high", {"part": "cooling_fan_temp", "severe": True})
        self.run_until(lambda: self.level() == 3, what="쿨링팬 온도 긴급")

    def test_06b_part_low(self):
        self.m.simulate("part_low", {"part": "main_fan_temp"})
        self.run_until(lambda: self.level() == 1, what="부품 저온 주의")
        self.assertEqual(self.ctl("heater"), 1)
        self.run_until(lambda: self.level() == 0, what="부품 저온 복구")
        self.assertEqual(self.ctl("heater"), 0)

    def test_07_main_fan_failover(self):
        self.m.simulate("main_fan_fail", {})
        self.tick()
        self.assertEqual(self.level(), 2)
        self.assertEqual(self.ctl("main_fan"), 0)
        self.assertEqual(self.ctl("backup_fan"), 1)
        self.assertIn("예비 환풍기로 대체", self.events("alarm")[-1]["message"])

        # 메인을 고쳐도 자동으로 되돌리지 않는다
        self.m.simulate("fan_repair", {})
        self.run_ticks(3)
        self.assertEqual(self.ctl("backup_fan"), 1)
        self.assertEqual(self.ctl("main_fan"), 0)
        # 사용자가 확인하고 전환
        self.m.apply_control("restore_main_fan", None)
        self.assertEqual(self.ctl("main_fan"), 1)
        self.assertEqual(self.ctl("backup_fan"), 0)

    def test_08_both_fans_fail(self):
        self.m.simulate("fans_fail", {})
        self.tick()
        self.assertEqual(self.level(), 3)

    def test_09_soil_dry_pump(self):
        self.m.simulate("soil_dry", {})
        self.tick()
        self.assertEqual(self.level(), 2)
        self.assertEqual(self.ctl("pump"), 1)
        self.run_until(lambda: self.level() == 0, max_ticks=60, what="토양수분 복구")
        self.assertEqual(self.ctl("pump"), 0)

    def test_09b_pump_max_60s(self):
        self.m.simulate("soil_dry", {"severe": True})
        self.tick()
        self.assertEqual(self.ctl("pump"), 1)
        self.run_until(lambda: self.ctl("pump") == 0, max_ticks=70, what="펌프 정지")
        self.assertIn("60초", self.events("info")[-1]["message"])
        self.run_ticks(30)
        self.assertEqual(self.ctl("pump"), 0)  # 바로 다시 돌지 않는다
        self.assertEqual(self.level(), 2)

    def test_10_power(self):
        self.m.simulate("low_voltage", {})
        self.run_until(lambda: "low_voltage" in self.m.active, what="전압 저하")
        self.m.simulate("power_restore", {})
        self.run_until(lambda: self.level() == 0, what="전압 복구")

        self.m.simulate("over_current", {})
        self.run_until(lambda: "over_current" in self.m.active, what="과전류")
        self.assertEqual(self.ctl("pump"), 0)
        self.m.simulate("power_restore", {})

        self.m.simulate("power_cut", {})
        self.tick()
        self.assertEqual(self.level(), 3)
        self.assertFalse(self.m.status()["power"]["power_ok"])
        self.assertNotIn("low_voltage", self.m.active)  # 차단일 때 전압 저하는 중복으로 띄우지 않음

    def test_11_co2_and_nutrient(self):
        self.m.simulate("co2_high", {})
        self.run_until(lambda: "co2" in self.m.active, what="CO2 높음")
        self.assertEqual(self.ctl("backup_fan"), 1)  # 환기 강화
        self.run_until(lambda: "co2" not in self.m.active, what="CO2 복구")
        self.assertEqual(self.ctl("backup_fan"), 0)

        self.m.simulate("nutrient_low", {})
        self.run_until(lambda: "nutrient" in self.m.active, what="양분 부족")
        self.assertIn("양액을 보충하세요", self.events("alarm")[-1]["actions"])
        self.m.simulate("nutrient_refill", {})
        self.run_until(lambda: "nutrient" not in self.m.active, what="양분 복구")

    def test_12_comm_loss(self):
        self.m.simulate("comm_loss", {"seconds": 30})
        self.assertTrue(self.m.comm_lost())
        self.m.simulate("comm_restore", {})
        self.assertFalse(self.m.comm_lost())

    def test_13_sensor_fault(self):
        self.m.simulate("sensor_fault", {"sensor": "humidity"})
        self.tick()
        status = self.m.status()
        self.assertIsNone(status["sensors"]["humidity"])
        self.assertIsNotNone(status["sensors"]["temperature"])
        self.assertEqual(status["sensor_errors"], ["humidity"])
        self.assertEqual(self.level(), 0)  # 센서 오류는 등급이 아니다

    def test_14_night_mode(self):
        self.m.simulate("night_on", {})
        self.tick()
        self.assertEqual(self.ctl("cover"), 1)
        self.assertEqual(self.ctl("lights"), 0)
        self.m.simulate("night_off", {})
        self.tick()
        self.assertEqual(self.ctl("cover"), 0)
        self.assertEqual(self.ctl("lights"), 1)  # 원래대로

    def test_15_night_motion(self):
        self.m.simulate("motion", {})  # 낮에는 경보 없음
        self.tick()
        self.assertEqual(self.level(), 0)
        self.m.simulate("night_on", {})
        self.tick()
        self.m.simulate("motion", {})
        self.tick()
        self.assertIn("intrusion", self.m.active)

    def test_16_night_high_temp(self):
        self.m.simulate("night_on", {})
        self.m.simulate("high_temp", {})
        self.run_until(lambda: self.level() == 2, what="야간 고온")
        self.assertEqual(self.ctl("backup_fan"), 1)  # 환기 먼저
        self.assertEqual(self.ctl("lights"), 0)  # 소등 유지
        self.assertEqual(self.ctl("cooling_fan"), 1)

    def test_21_manual_auto_lock(self):
        with self.assertRaises(ControlError) as e:
            self.m.apply_control("heater", 1)
        self.assertEqual(e.exception.code, 409)  # 자동 모드에서 수동 조작 잠금

        self.m.apply_control("control_mode", 0)
        self.m.apply_control("heater", 1)
        self.assertEqual(self.ctl("heater"), 1)

        self.m.apply_control("heater", 0)
        self.m.simulate("high_temp", {})
        self.run_until(lambda: self.level() == 2, what="수동 모드 고온")
        self.assertEqual(self.ctl("aircon_setpoint"), 25.0)  # 자동 조치 없음
        self.assertIn("수동 모드", self.all_actions())

    def test_21b_manual_roundtrip_does_not_freeze_auto_actions(self):
        # 자동 냉방 중에 수동 → 자동으로 다시 바꿔도 냉방 값이 사용자 설정으로 굳지 않아야 한다
        self.m.simulate("high_temp", {})
        self.run_until(lambda: self.ctl("cooling_fan") == 1, what="자동 냉방")
        self.m.apply_control("control_mode", 0)
        self.assertEqual(self.ctl("cooling_fan"), 1)  # 수동 전환 순간에는 그대로
        self.m.apply_control("heater", 1)  # 사용자가 직접 바꾼 장치
        self.m.apply_control("control_mode", 1)
        self.assertEqual(self.m.base["aircon_setpoint"], 25.0)
        self.assertEqual(self.m.base["cooling_fan"], 0)
        self.assertEqual(self.m.base["heater"], 1)  # 사용자 조작은 유지

    def test_22_ai_precool(self):
        self.m.simulate("slow_heat", {})
        max_level, max_temp = 0, 0.0
        for _ in range(60):
            self.tick()
            if self.m.ai_active:
                break
        self.assertTrue(self.m.ai_active, "AI 선가동이 시작되지 않음")
        self.assertLess(self.m.values["temperature"], self.m.thresholds["temp_high"])  # 상한 전에 시작
        self.assertEqual(self.ctl("aircon_setpoint"), 22.0)
        self.assertEqual(self.ctl("cooling_fan"), 1)
        start = [e for e in self.m.events if e["key"] == "ai"][0]
        self.assertTrue(any("판단 이유" in a and "℃/분" in a for a in start["actions"]))  # 이유를 남긴다
        self.assertIn("상한", self.m.status()["ai"]["reason"])

        # 경보 없이 지나가고, 안정되면 종료하면서 원래 설정으로 복원
        for _ in range(300):
            self.tick()
            max_level = max(max_level, self.level())
            max_temp = max(max_temp, self.m.values["temperature"])
            if not self.m.ai_active:
                break
        self.assertFalse(self.m.ai_active, "AI 선가동이 끝나지 않음")
        self.assertEqual(max_level, 0)  # 경보까지 가지 않았다
        self.assertLess(max_temp, 30.0)
        self.assertEqual(self.ctl("aircon_setpoint"), 25.0)
        self.assertIn("종료", [e for e in self.m.events if e["key"] == "ai"][-1]["message"])

    def test_22b_ai_off_in_manual_mode(self):
        self.m.apply_control("control_mode", 0)
        self.m.simulate("slow_heat", {})
        self.run_ticks(60)
        self.assertFalse(self.m.ai_active)  # 수동 모드에서는 자동 조치 없음

    def test_crop_presets_recover(self):
        """crops.json의 작물별 값으로도 고온·저온 시나리오가 경보 후 복구되는지"""
        import json
        import os
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "crops.json")
        crops = json.load(open(path, encoding="utf-8"))["crops"]
        for crop, values in crops.items():
            for scenario, level_key in (("high_temp", "temp_high"), ("low_temp", "temp_low")):
                with self.subTest(crop=crop, scenario=scenario):
                    random.seed(2)
                    self.m = RmuModel()
                    self.m.update_thresholds(values)
                    self.run_ticks(5)
                    self.m.simulate(scenario, {})
                    self.run_until(lambda: self.level() == 2, what=f"{crop} {scenario} 경보")
                    self.run_until(lambda: self.level() == 0, what=f"{crop} {scenario} 복구")
                    self.assertEqual(self.ctl("aircon_setpoint"), 25.0)

    def test_night_window(self):
        self.assertTrue(in_night_window(22 * 60, 21 * 60, 6 * 60))
        self.assertTrue(in_night_window(3 * 60, 21 * 60, 6 * 60))  # 자정 넘음
        self.assertFalse(in_night_window(12 * 60, 21 * 60, 6 * 60))
        self.assertTrue(in_night_window(1 * 60, 0, 5 * 60))
        with self.assertRaises(ValueError):
            self.m.update_settings({"night_start": 300, "night_end": 300})


if __name__ == "__main__":
    unittest.main()
