"""
3단계 푸시 알림 테스트. 실제 HTTP 서버를 띄워 ntfy 형식으로 받는지 확인한다.

실행:  python -m unittest test_push -v     (rmu 폴더에서)
"""

import base64
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from push import PushSender
from rmu_model import RmuModel

received = []


class FakeNtfy(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode("utf-8")
        received.append({"path": self.path, "body": body, "title": self.headers["Title"],
                         "priority": self.headers["Priority"]})
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


def wait_for(count, timeout=3):
    end = time.time() + timeout
    while len(received) < count and time.time() < end:
        time.sleep(0.02)


class PushTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), FakeNtfy)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.httpd.server_port}/smartfarm-test"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def setUp(self):
        received.clear()

    def test_alarm_and_clear_are_pushed_with_actions(self):
        m = RmuModel()
        push = PushSender(self.url, "방울토마토 1동")
        m.event_listeners.append(push.on_event)
        m.simulate("main_fan_fail", {})
        m.tick()
        wait_for(1)
        self.assertEqual(len(received), 1)
        msg = received[0]
        self.assertEqual(msg["path"], "/smartfarm-test")
        self.assertIn("[경보] 메인 환풍기 고장", msg["body"])
        self.assertIn("예비 환풍기를 켰습니다", msg["body"])  # 조치 내역 포함
        self.assertEqual(msg["priority"], "high")
        title = base64.b64decode(msg["title"][10:-2]).decode("utf-8")
        self.assertEqual(title, "방울토마토 1동")

        m.simulate("fan_repair", {})
        m.tick()
        wait_for(2)
        self.assertIn("[해소]", received[1]["body"])

    def test_low_levels_and_control_not_pushed(self):
        push = PushSender(self.url)
        push.on_event({"type": "alarm", "key": "part:rmu_temp", "level": 1, "message": "주의", "actions": []})
        push.on_event({"type": "control", "key": "control", "level": 0, "message": "사용자 조작", "actions": []})
        push.on_event({"type": "clear", "key": "part:rmu_temp", "level": 0, "message": "복귀", "actions": []})
        time.sleep(0.2)
        self.assertEqual(received, [])  # 주의(1) 이하는 기본 설정에서 보내지 않음

    def test_min_interval_and_emergency_repeat(self):
        push = PushSender(self.url, min_interval=300, emergency_repeat=60)
        alarm = {"type": "alarm", "key": "soil_dry", "level": 2, "message": "건조", "actions": []}
        push.on_event(alarm, now=1000)
        push.on_event(alarm, now=1100)  # 5분 안 → 보내지 않음
        push.on_event(alarm, now=1400)  # 5분 지남 → 보냄
        wait_for(2)
        self.assertEqual(len(received), 2)

        emergency = {"fan": {"level": 3, "message": "환풍기 모두 고장"}}
        push.remind(emergency, now=2000)
        push.remind(emergency, now=2030)  # 1분 안
        push.remind(emergency, now=2061)
        wait_for(4)
        self.assertEqual(len(received), 4)
        self.assertIn("긴급 경보 계속", received[-1]["body"])
        self.assertEqual(received[-1]["priority"], "urgent")


if __name__ == "__main__":
    unittest.main()
