"""
2단계 SQLite 기록 테스트.

실행:  python -m unittest test_storage -v     (rmu 폴더에서)
"""

import os
import tempfile
import unittest
from datetime import datetime, timedelta

from rmu_model import RmuModel
from storage import RECORD_SECONDS, Storage

START = datetime(2026, 10, 7, 12, 0, 0)


class StorageTest(unittest.TestCase):
    def setUp(self):
        self.path = os.path.join(tempfile.mkdtemp(), "rmu.db")

    def run_model(self, model, seconds, start=START):
        now = start
        for _ in range(seconds):
            now += timedelta(seconds=1)
            model.tick(now)
        return now

    def test_events_survive_restart_and_ids_continue(self):
        m = RmuModel(storage=Storage(self.path))
        m.simulate("main_fan_fail", {})
        self.run_model(m, 2)
        first = m.get_events(0)
        self.assertTrue(first)
        self.assertIn("예비 환풍기로 대체", first[0]["message"])
        self.assertIn("예비 환풍기를 켰습니다", first[0]["actions"])  # 조치 내역도 저장

        # RMU 재시작: 같은 DB 파일로 새 모델
        m2 = RmuModel(storage=Storage(self.path))
        self.assertEqual(len(m2.get_events(0)), len(first))
        m2.simulate("fans_fail", {})
        self.run_model(m2, 2)
        ids = [e["id"] for e in m2.get_events(0)]
        self.assertEqual(ids, sorted(set(ids)))  # 번호가 겹치지 않고 이어진다
        self.assertEqual(m2.get_events(first[-1]["id"])[0]["id"], first[-1]["id"] + 1)

    def test_history_records_and_averages(self):
        m = RmuModel(storage=Storage(self.path))
        m.simulate("high_temp", {})
        end = self.run_model(m, 600)  # 10분
        points = m.storage.history("temperature", "1h", now=end)
        # 10초마다 기록, 1시간 범위는 30초 구간 평균 → 10분이면 약 20개
        self.assertTrue(15 <= len(points) <= 21, len(points))
        values = [p["value"] for p in points]
        self.assertGreater(max(values), 27.5)  # 올라갔던 기록 (구간 평균이라 순간 최고값보다 낮다)
        self.assertLess(values[-1], max(values))  # 냉방 후 내려온 기록
        times = [p["time"] for p in points]
        self.assertEqual(times, sorted(times))

    def test_sensor_fault_is_null_in_history(self):
        m = RmuModel(storage=Storage(self.path))
        m.simulate("sensor_fault", {"sensor": "humidity"})
        end = self.run_model(m, RECORD_SECONDS * 3)
        self.assertEqual(m.storage.history("humidity", "1h", now=end), [])  # 오류 값은 그래프에서 빠짐
        self.assertTrue(m.storage.history("temperature", "1h", now=end))

    def test_invalid_query(self):
        s = Storage(self.path)
        with self.assertRaises(ValueError):
            s.history("password", "1h")
        with self.assertRaises(ValueError):
            s.history("temperature", "1y")

    def test_without_storage_history_is_error(self):
        with self.assertRaises(ValueError):
            RmuModel().history("temperature", "1h")


if __name__ == "__main__":
    unittest.main()
