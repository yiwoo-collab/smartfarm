"""
1단계(SNMP, Trap, 하드웨어 대체) 테스트. snmpd와 라즈베리파이 없이 PC에서 돌아간다.

실행:  python -m unittest test_snmp -v     (rmu 폴더에서)
"""

import json
import os
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

import oids as oidlib
import server
import traps
from gen_mib import generate
from hardware import Hardware
from rmu_model import RmuModel
from snmp_agent import Agent, RestClient

OIDS = oidlib.load()
BASE = OIDS["base"]


def oid(group, name):
    return BASE + OIDS[group][name]["oid"] + ".0"


class SnmpAgentTest(unittest.TestCase):
    """실제 HTTP 서버를 띄우고 snmp_agent가 REST로 읽고 쓰는지 확인"""

    @classmethod
    def setUpClass(cls):
        server.rmu = RmuModel()
        server.rmu.tick()
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        server.write_internal_token(cls.httpd.server_port)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.agent = Agent(RestClient(f"http://127.0.0.1:{cls.httpd.server_port}"))

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        os.remove(server.internal_token_path(cls.httpd.server_port))

    def run_lines(self, *lines):
        it = iter(lines)
        return self.agent.handle(lambda: next(it))

    def test_ping(self):
        self.assertEqual(self.run_lines("PING"), ["PONG"])

    def test_get_temperature_in_tenths(self):
        o = oid("status", "temperature")
        result = self.run_lines("get", o)
        self.assertEqual(result[0], o)
        self.assertEqual(result[1], "integer")
        expected = round(server.rmu.values["temperature"] * 10)
        self.assertAlmostEqual(int(result[2]), expected, delta=3)

    def test_get_unknown_is_none(self):
        self.assertEqual(self.run_lines("get", BASE + ".9.9.0"), ["NONE"])

    def test_walk_visits_all_objects_in_order(self):
        seen, current = [], BASE
        while True:
            result = self.run_lines("getnext", current)
            if result == ["NONE"]:
                break
            seen.append(result[0])
            current = result[0]
        self.assertEqual(len(seen), len(oidlib.objects(OIDS)))
        self.assertEqual(seen, sorted(seen, key=oidlib.oid_key))

    def test_set_status_is_not_writable(self):
        self.assertEqual(self.run_lines("set", oid("status", "temperature"), "integer 300"),
                         ["not-writable"])

    def test_set_threshold(self):
        o = oid("thresholds", "temp_high")
        self.assertEqual(self.run_lines("set", o, "integer 315"), ["DONE"])
        self.assertEqual(server.rmu.thresholds["temp_high"], 31.5)
        self.assertEqual(self.run_lines("get", o)[2], "315")
        self.run_lines("set", o, "integer 300")

    def test_set_control_locked_in_auto_mode(self):
        # 자동 모드에서는 수동 조작 잠금 → inconsistent-value (시나리오 21)
        self.assertEqual(self.run_lines("set", oid("control", "heater"), "integer 1"),
                         ["inconsistent-value"])
        self.assertEqual(self.run_lines("set", oid("control", "control_mode"), "integer 0"), ["DONE"])
        self.assertEqual(self.run_lines("set", oid("control", "heater"), "integer 1"), ["DONE"])
        self.assertEqual(server.rmu.control["heater"], 1)
        self.run_lines("set", oid("control", "heater"), "integer 0")
        self.run_lines("set", oid("control", "control_mode"), "integer 1")

    def test_set_night_same_start_end_rejected(self):
        start = server.rmu.settings["night_start"]
        self.assertEqual(self.run_lines("set", oid("settings", "night_end"), f"integer {start}"),
                         ["wrong-value"])

    def test_set_wrong_type(self):
        self.assertEqual(self.run_lines("set", oid("control", "pump"), "string on"), ["wrong-type"])

    def test_rest_requires_login_without_token(self):
        error = RestClient(self.agent.client.base)
        error._token = lambda: "wrong"
        self.assertEqual(error.send("POST", "/api/control", {"device": "pump", "value": 1})[0], 401)


class ConversionTest(unittest.TestCase):
    def test_units(self):
        self.assertEqual(oidlib.to_snmp(25.3, "0.1C"), 253)
        self.assertEqual(oidlib.to_snmp(4.98, "mV"), 4980)
        self.assertEqual(oidlib.to_snmp(1.85, "0.01mS/cm"), 185)
        self.assertEqual(oidlib.to_snmp(True, "0/1"), 1)
        self.assertEqual(oidlib.from_snmp(253, "0.1C"), 25.3)
        self.assertEqual(oidlib.from_snmp(1260, "minutes"), 1260)

    def test_oids_unique(self):
        all_oids = [o for _, _, o, _, _ in oidlib.objects(OIDS)]
        all_oids += [BASE + v["oid"] for v in OIDS["notifications"].values()]
        self.assertEqual(len(all_oids), len(set(all_oids)))

    def test_every_trap_name_used_by_model_exists(self):
        import rmu_model
        source = open(rmu_model.__file__, encoding="utf-8").read()
        for name in OIDS["notifications"]:
            if name in ("alarmClear", "sensorFault"):
                continue  # traps.py에서 사용
            self.assertIn(f'"{name}"', source, f"{name} Trap을 쓰는 곳이 없음")

    def test_mib_has_every_object(self):
        text = generate(OIDS, last_updated="202601010000Z")
        for name, *_ in oidlib.objects(OIDS):
            self.assertIn(f"sf{''.join(p.capitalize() for p in name.split('_'))} OBJECT-TYPE", text)
        for name in OIDS["notifications"]:
            self.assertIn(f"{name} NOTIFICATION-TYPE", text)


class TrapTest(unittest.TestCase):
    def test_alarm_trap_command(self):
        event = {"type": "alarm", "trap": "highTempAlarm", "key": "temp", "level": 2,
                 "message": "온실 온도 상한 초과"}
        cmd = traps.build_command(OIDS, event, "10.0.0.5:162", "public")
        self.assertEqual(cmd[:7], ["snmptrap", "-v", "2c", "-c", "public", "10.0.0.5:162", ""])
        self.assertEqual(cmd[7], BASE + ".1.4.0.1")
        self.assertIn("2", cmd)
        self.assertEqual(cmd[-1], "온실 온도 상한 초과")

    def test_clear_and_skip(self):
        clear = {"type": "clear", "key": "temp", "level": 0, "message": "정상 복귀"}
        self.assertEqual(traps.build_command(OIDS, clear, "h", "c")[7], BASE + ".1.4.0.14")
        control = {"type": "control", "key": "control", "level": 0, "message": "사용자 조작"}
        self.assertIsNone(traps.build_command(OIDS, control, "h", "c"))

    def test_model_calls_on_event(self):
        m = RmuModel()
        sent = []
        m.event_listeners.append(sent.append)
        m.simulate("fans_fail", {})
        m.tick()
        self.assertEqual(sent[-1]["trap"], "emergencyAlarm")


class FakeHardware:
    """하드웨어 대신: 온도 센서만 있고 습도는 읽기 실패"""

    def __init__(self):
        self.applied = None

    def read(self):
        return {"temperature": 31.0, "humidity": None, "rmu_temp": 50.0}

    def fan_failures(self, control):
        return {"main_fan": True}

    def apply(self, control):
        self.applied = dict(control)


class HardwareIntegrationTest(unittest.TestCase):
    def test_real_values_faults_and_relays(self):
        hw = FakeHardware()
        m = RmuModel(hardware=hw)
        for _ in range(3):
            m.tick()
        status = m.status()
        self.assertAlmostEqual(status["sensors"]["temperature"], 31.0)  # 실물 값 사용
        self.assertIn("humidity", status["sensor_errors"])  # 읽기 실패 → 센서 오류
        self.assertIsNone(status["sensors"]["humidity"])
        self.assertIn("temp", m.active)  # 31℃ > 30℃ → 경보
        self.assertFalse(status["fans"]["main_ok"])  # 회전 신호 없음 → 고장
        self.assertEqual(hw.applied["backup_fan"], 1)  # 예비 환풍기로 대체해 릴레이에 반영

    def test_simulation_overrides_real_sensor(self):
        m = RmuModel(hardware=FakeHardware())
        m.simulate("soil_dry", {})
        m.tick()
        self.assertLess(m.values["soil_moisture"], 35)  # 실물 센서가 없어도 시뮬레이션 동작

    def test_hardware_without_libraries(self):
        # PC에는 adafruit/gpiozero가 없다 → 모두 '사용 안 함', read()는 빈 값
        cfg = json.load(open(os.path.join(os.path.dirname(__file__), "hardware_config.json"), encoding="utf-8"))
        cfg["cpu_temp_path"] = os.path.join(tempfile.gettempdir(), "no_such_cpu_temp")
        path = os.path.join(tempfile.mkdtemp(), "hw.json")
        json.dump(cfg, open(path, "w", encoding="utf-8"))
        hw = Hardware(path)
        self.assertEqual(hw.read(), {})
        self.assertEqual(hw.fan_failures({}), {})
        hw.apply({"main_fan": 1})  # 릴레이가 없어도 오류 없이 넘어간다
        self.assertIn("사용 안 함", hw.summary())


if __name__ == "__main__":
    unittest.main()
