"""
SQLite 기록 (2단계, CLAUDE.md 1장).

  events    이벤트와 조치 내역 (알림 상세) → GET /api/events
  readings  센서 값 기록 (일정 간격)        → GET /api/history

같은 라즈베리파이에 파일 하나(rmu.db)로 저장한다. 별도 서버는 없다.
"""

import json
import sqlite3
import threading
from datetime import datetime, timedelta

RECORD_SECONDS = 10       # 센서 값 기록 간격 (제안)
KEEP_DAYS = 7             # 기록 보관 기간 (제안)

# 기록하는 항목 (REST 이름). 그래프 화면에서 고를 수 있다.
HISTORY_SENSORS = ["temperature", "humidity", "soil_moisture", "co2", "nutrient_ec",
                   "supply_voltage", "supply_current", "greenhouse_power", "rmu_temp",
                   "main_fan_temp", "backup_fan_temp", "cooling_fan_temp", "alarm_level"]

RANGES = {"1h": timedelta(hours=1), "6h": timedelta(hours=6),
          "24h": timedelta(hours=24), "7d": timedelta(days=7)}
MAX_POINTS = 120          # 그래프 한 개에 보내는 최대 점 개수 (구간 평균으로 줄임)


class Storage:
    def __init__(self, path):
        self.lock = threading.Lock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute("""CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY, time TEXT, level INTEGER, type TEXT,
            key TEXT, trap TEXT, message TEXT, actions TEXT)""")
        columns = ", ".join(f"{s} REAL" for s in HISTORY_SENSORS)
        self.db.execute(f"CREATE TABLE IF NOT EXISTS readings (time TEXT PRIMARY KEY, {columns})")
        self.db.commit()
        self._last_record = None

    # ----- 이벤트 -------------------------------------------------------------
    def add_event(self, e):
        with self.lock:
            self.db.execute("INSERT INTO events VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                            (e["id"], e["time"], e["level"], e["type"], e["key"], e["trap"],
                             e["message"], json.dumps(e["actions"], ensure_ascii=False)))
            self.db.commit()

    def events_since(self, since, limit=500):
        with self.lock:
            rows = self.db.execute(
                "SELECT id, time, level, type, key, trap, message, actions FROM events "
                "WHERE id > ? ORDER BY id LIMIT ?", (since, limit)).fetchall()
        return [{"id": r[0], "time": r[1], "level": r[2], "type": r[3], "key": r[4],
                 "trap": r[5], "message": r[6], "actions": json.loads(r[7])} for r in rows]

    def last_event_id(self):
        with self.lock:
            row = self.db.execute("SELECT MAX(id) FROM events").fetchone()
        return row[0] or 0

    # ----- 센서 기록 ----------------------------------------------------------
    def maybe_record(self, now, values):
        """RECORD_SECONDS마다 한 번 기록. values: {이름: 값 또는 None}"""
        if self._last_record and (now - self._last_record).total_seconds() < RECORD_SECONDS:
            return
        self._last_record = now
        row = [now.isoformat(timespec="seconds")] + [values.get(s) for s in HISTORY_SENSORS]
        with self.lock:
            self.db.execute(f"INSERT OR REPLACE INTO readings VALUES ({', '.join('?' * len(row))})", row)
            # 오래된 기록 정리 (하루에 한 번 정도면 충분하지만 단순하게 매번)
            cutoff = (now - timedelta(days=KEEP_DAYS)).isoformat(timespec="seconds")
            self.db.execute("DELETE FROM readings WHERE time < ?", (cutoff,))
            self.db.commit()

    def history(self, sensor, range_name, now=None):
        """구간 평균으로 줄인 기록: [{"time": ..., "value": ...}]"""
        if sensor not in HISTORY_SENSORS:
            raise ValueError(f"sensor는 {HISTORY_SENSORS} 중 하나입니다")
        if range_name not in RANGES:
            raise ValueError(f"range는 {list(RANGES)} 중 하나입니다")
        now = now or datetime.now()
        span = RANGES[range_name]
        start = now - span
        bucket = max(RECORD_SECONDS, int(span.total_seconds() / MAX_POINTS))
        with self.lock:
            rows = self.db.execute(
                f"SELECT time, {sensor} FROM readings WHERE time >= ? ORDER BY time",
                (start.isoformat(timespec="seconds"),)).fetchall()
        # 같은 구간(bucket초)에 들어온 값을 평균 낸다. 센서 오류(None)는 빼고 계산.
        points, current, values = [], None, []
        for t, v in rows:
            index = int((datetime.fromisoformat(t) - start).total_seconds() // bucket)
            if index != current and values:
                points.append(self._point(start, current, bucket, values))
                values = []
            current = index
            if v is not None:
                values.append(v)
        if values:
            points.append(self._point(start, current, bucket, values))
        return points

    @staticmethod
    def _point(start, index, bucket, values):
        t = start + timedelta(seconds=index * bucket + bucket / 2)
        return {"time": t.isoformat(timespec="seconds"), "value": round(sum(values) / len(values), 2)}
