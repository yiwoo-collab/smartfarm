"""
1단계 SNMP 시험 (v3.0). 하드웨어·snmpd 없이 PC에서 돈다.
  - snmp_lite 인코딩/디코딩
  - 라즈베리파이 ↔ 모의 RMU 실물: SNMP 조회, addTrap 등록, Trap 수신 → 등급 계산 (시나리오 28)
  - snmpd 확장 에이전트(snmp_agent.py)가 REST를 거쳐 읽고 쓰는지
  - farmAlarm Trap 명령, 하드웨어 대체, 확장 MIB

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
from mock_pelkorea_rmu import MockRmu, serve_snmp
from rmu_client import RmuPoller, TrapReceiver, register_trap, wait_until
from rmu_model import RmuModel
from snmp_agent import Agent, RestClient
from snmp_lite import GET, SnmpClient, decode_message, encode_message

OIDS = oidlib.load()
OBJ = oidlib.by_name(OIDS)


def inst(name):
    return OBJ[name]["oid"].strip(".") + ".0"


class CodecTest(unittest.TestCase):
    def test_roundtrip(self):
        packet = encode_message("public", GET, 1234, [
            ("1.3.6.1.4.1.61123730.1.1.9.0", "i", -5), ("1.3.6.1.2.1.1.5.0", "s", "스마트팜"),
            ("1.3.6.1.6.3.1.1.4.1.0", "o", "1.3.6.1.4.1.61123730.1.4.2"), ("1.3.6.1.2.1.1.3.0", "t", 300000)])
        msg = decode_message(packet)
        self.assertEqual(msg["request_id"], 1234)
        self.assertEqual(msg["varbinds"][0], ("1.3.6.1.4.1.61123730.1.1.9.0", "i", -5))
        self.assertEqual(msg["varbinds"][1][2], "스마트팜")
        self.assertEqual(msg["varbinds"][2][2], "1.3.6.1.4.1.61123730.1.4.2")
        self.assertEqual(msg["varbinds"][3][2], 300000)

    def test_scale_offset(self):
        self.assertEqual(oidlib.to_value(750, OBJ["temperature"]), 25.0)   # (750 − 500) ÷ 10
        self.assertEqual(oidlib.to_value(2215, OBJ["ac_voltage"]), 221.5)
        self.assertEqual(oidlib.to_raw(25.3, OBJ["temperature"]), 753)
        self.assertEqual(oidlib.to_raw(72.5, OBJ["humidity"]), 725)

    def test_alarm_codes(self):
        self.assertEqual(oidlib.alarm_code_info(OIDS, 61)["level"], 2)
        self.assertEqual(oidlib.alarm_code_info(OIDS, 161)["level"], 2)  # 해제 코드도 원래 코드로 찾는다
        self.assertTrue(oidlib.is_clear_code(OIDS, 161))
        self.assertTrue(oidlib.is_clear_code(OIDS, 303))
        self.assertFalse(oidlib.is_clear_code(OIDS, 203))


class RmuLinkTest(unittest.TestCase):
    """라즈베리파이 ↔ 모의 RMU 실물 (UDP로 실제 SNMP 통신)"""

    def setUp(self):
        self.rmu = MockRmu()
        self.sock, self.port = serve_snmp(self.rmu, 0)
        self.model = RmuModel(mode="live")
        self.poller = RmuPoller(self.model, "127.0.0.1", self.port)

    def tearDown(self):
        self.sock.close()

    def test_poll_converts_values(self):
        self.rmu.raw["temp1"] = 800  # 30.0℃
        self.assertTrue(self.poller.poll_once())
        self.model.tick()
        st = self.model.status()
        self.assertAlmostEqual(st["sensors"]["temperature"], 30.0, delta=0.5)
        self.assertAlmostEqual(st["power"]["ac_voltage"], 220.0, delta=2)
        self.assertEqual(st["states"]["temperature"], "ok")
        self.assertTrue(st["rmu"]["connected"])

    def test_high_temp_from_rmu_triggers_alarm(self):
        self.rmu.raw["temp1"] = 820  # 32.0℃ > 상한 30℃
        self.poller.poll_once()
        self.model.tick()
        self.assertIn("temp", self.model.active)

    def test_offline_when_rmu_silent(self):
        self.poller.poll_once()
        self.sock.close()
        self.poller.client.timeout = 0.2
        self.assertFalse(self.poller.poll_once())
        self.model.tick()
        self.assertEqual(self.model.status()["states"]["temperature"], "offline")

    def test_wrong_community_gets_no_answer(self):
        c = SnmpClient("127.0.0.1", self.port, "wrong", timeout=0.2, retries=0)
        with self.assertRaises(Exception):
            c.get([inst("temperature")])

    def test_trap_registration_and_receive(self):
        receiver = TrapReceiver(self.model, 0)
        receiver.start()
        try:
            self.assertIsNone(register_trap("127.0.0.1", self.port, "private", "127.0.0.1", receiver.port))
            self.assertIn(f"127.0.0.1:{receiver.port}", self.rmu.trap_targets)
            self.rmu.raise_alarm(61)  # UPS 배터리 낮음
            self.assertTrue(wait_until(lambda: "rmu:61" in self.model.active))
            self.assertEqual(self.model.active["rmu:61"]["level"], 2)
            self.rmu.raise_alarm(161)  # 해제
            self.assertTrue(wait_until(lambda: "rmu:61" not in self.model.active))
        finally:
            receiver.close()

    def test_readonly_community_cannot_register(self):
        self.assertIsNotNone(register_trap("127.0.0.1", self.port, "public", "127.0.0.1", 9999))


class ExtensionAgentTest(unittest.TestCase):
    """snmpd pass_persist 에이전트 → REST (우리 확장 {rmu 6})"""

    @classmethod
    def setUpClass(cls):
        server.rmu = RmuModel()
        server.rmu.tick()
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        server.write_internal_token(cls.httpd.server_port)
        cls.agent = Agent(RestClient(f"http://127.0.0.1:{cls.httpd.server_port}"))

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        os.remove(server.internal_token_path(cls.httpd.server_port))

    def run_lines(self, *lines):
        it = iter(lines)
        return self.agent.handle(lambda: next(it))

    def test_get_humidity(self):
        result = self.run_lines("get", inst("humidity"))
        self.assertEqual(result[1], "integer")
        self.assertAlmostEqual(int(result[2]) / 10, server.rmu.values["humidity"], delta=1)

    def test_nodata_not_served(self):
        self.assertEqual(self.run_lines("get", inst("co2")), ["NONE"])  # 정보없음은 값이 없다

    def test_set_threshold_and_mode(self):
        self.assertEqual(self.run_lines("set", inst("temp_high"), "integer 315"), ["DONE"])
        self.assertEqual(server.rmu.thresholds["temp_high"], 31.5)
        self.assertEqual(self.run_lines("set", inst("ai_mode"), "integer 1"), ["DONE"])
        self.assertEqual(server.rmu.mode, "live")
        self.run_lines("set", inst("ai_mode"), "integer 0")
        self.run_lines("set", inst("temp_high"), "integer 300")

    def test_set_control_locked_in_auto(self):
        self.assertEqual(self.run_lines("set", inst("heater"), "integer 1"), ["inconsistent-value"])

    def test_walk_is_ordered(self):
        seen, cur = [], OIDS["ext_base"].strip(".")
        while True:
            r = self.run_lines("getnext", cur)
            if r == ["NONE"]:
                break
            seen.append(r[0])
            cur = r[0]
        self.assertEqual(seen, sorted(seen, key=oidlib.oid_key))
        self.assertNotIn(inst("co2"), seen)


class TrapAndHardwareTest(unittest.TestCase):
    def test_farm_alarm_trap_command(self):
        event = {"type": "alarm", "level": 3, "code": 203, "message": "긴급: 화재 감지", "key": "fire"}
        cmd = traps.build_command(OIDS, event, "10.0.0.5:162", "public")
        self.assertEqual(cmd[7], oidlib.notification_oid(OIDS, "farmAlarm"))
        self.assertIn("203", cmd)
        self.assertIsNone(traps.build_command(OIDS, {"type": "control", "level": 0}, "h", "c"))

    def test_hardware_without_libraries(self):
        cfg = json.load(open(os.path.join(os.path.dirname(__file__), "hardware_config.json"), encoding="utf-8"))
        cfg["cpu_temp_path"] = os.path.join(tempfile.gettempdir(), "no_such_cpu_temp")
        path = os.path.join(tempfile.mkdtemp(), "hw.json")
        json.dump(cfg, open(path, "w", encoding="utf-8"))
        hw = Hardware(path)
        self.assertEqual(hw.read(), {})
        hw.apply({"main_fan": 1})
        self.assertIn("사용 안 함", hw.summary())

    def test_live_mode_uses_pi_readings(self):
        m = RmuModel(mode="live")
        m.set_external({"humidity": 55.0, "fire": 1, "water_level": None}, "pi")
        m.tick()
        st = m.status()
        self.assertEqual(st["sensors"]["humidity"], 55.0)
        self.assertTrue(st["sensors"]["fire"])
        self.assertIn("fire", m.active)
        self.assertEqual(st["states"]["water_level"], "fault")  # 읽기 실패 → 센서 오류

    def test_mib_has_extension_objects(self):
        text = generate(OIDS, last_updated="202601010000Z")
        self.assertIn("::= { enterprises 61123730 1 6 }", text)
        self.assertIn("sfHumidity OBJECT-TYPE", text)
        self.assertIn("farmAlarm NOTIFICATION-TYPE", text)
        self.assertNotIn("sfTemperature", text)  # RMU 실물 항목은 교수님 MIB에 있다


if __name__ == "__main__":
    unittest.main()
