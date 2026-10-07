"""
SNMP 에이전트 (net-snmp snmpd의 pass_persist 확장).

snmpd가 이 스크립트를 띄워 두고, 우리 OID(.1.3.6.1.4.1.99999.1) 아래의 요청을 넘겨준다.
  - GET / GETNEXT : 같은 라즈베리파이의 REST API(/api/status, /api/thresholds, /api/settings)에서 값을 읽어 응답
  - SET           : REST API(/api/control, /api/thresholds, /api/settings)로 전달
                    → 앱과 똑같은 규칙(자동 모드 잠금, 값 검사)을 거친다
값을 한 곳(server.py의 RmuModel)에서만 관리하기 위해 이렇게 나눴다.

snmpd.conf 예:  pass_persist .1.3.6.1.4.1.99999.1 /usr/bin/python3 /home/pi/smartfarm/rmu/snmp_agent.py

pass_persist 규칙 (net-snmp snmpd.conf 문서):
  PING                 → PONG
  get\n<OID>           → <OID>\n<type>\n<value>   또는 NONE
  getnext\n<OID>       → 다음 OID의 값             또는 NONE
  set\n<OID>\n<type> <value> → DONE / not-writable / wrong-type / wrong-value / inconsistent-value
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import oids as oidlib

HERE = os.path.dirname(os.path.abspath(__file__))
REST_URL = os.environ.get("RMU_REST_URL", "http://127.0.0.1:8080")
CACHE_SECONDS = 2  # snmpwalk처럼 연달아 오는 요청은 같은 값으로 응답


class RestClient:
    """같은 라즈베리파이의 RMU REST API 호출"""

    def __init__(self, base=REST_URL):
        self.base = base

    def _token(self):
        """server.py가 시작할 때 만든 내부 토큰 (.internal_token_<포트>)"""
        port = urllib.parse.urlparse(self.base).port or 80
        with open(os.path.join(HERE, f".internal_token_{port}"), encoding="utf-8") as f:
            return f.read().strip()

    def get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=3) as res:
            return json.loads(res.read().decode("utf-8"))

    def send(self, method, path, body):
        """성공하면 None, 실패하면 (HTTP 코드, 메시지)"""
        req = urllib.request.Request(
            self.base + path, method=method, data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {self._token()}"})
        try:
            with urllib.request.urlopen(req, timeout=3):
                return None
        except urllib.error.HTTPError as e:
            return (e.code, e.read().decode("utf-8", "replace"))


class Agent:
    def __init__(self, client, oids=None):
        self.client = client
        self.oids = oids or oidlib.load()
        # 인스턴스 OID(.0을 붙임) → (이름, 그룹, 단위)
        self.table = {}
        for name, group, oid, unit, _ in oidlib.objects(self.oids):
            self.table[oid + ".0"] = (name, group, unit)
        self.sorted_oids = sorted(self.table, key=oidlib.oid_key)
        self._cache = None
        self._cache_time = 0.0

    # ----- 값 읽기 -------------------------------------------------------------
    def _snapshot(self):
        """REST에서 받은 값을 이름 → REST 값 사전으로 합친다"""
        now = time.monotonic()
        if self._cache is not None and now - self._cache_time < CACHE_SECONDS:
            return self._cache
        status = self.client.get("/api/status")
        flat = {}
        flat.update(status["sensors"])
        flat.update(status["part_temps"])
        flat.update(status["power"])
        flat.update(status["control"])
        flat["alarm_level"] = status["alarm_level"]
        flat.update(self.client.get("/api/thresholds"))
        flat.update(self.client.get("/api/settings"))
        self._cache, self._cache_time = flat, now
        return flat

    def value_of(self, oid):
        """(type, value) 또는 None. 센서 오류(null)는 값이 없으므로 None."""
        name, _, unit = self.table[oid]
        value = self._snapshot().get(name)
        if value is None:
            return None
        return "integer", oidlib.to_snmp(value, unit)

    def get(self, oid):
        if oid not in self.table:
            return None
        v = self.value_of(oid)
        return None if v is None else (oid, *v)

    def getnext(self, oid):
        key = oidlib.oid_key(oid)
        for candidate in self.sorted_oids:
            if oidlib.oid_key(candidate) > key:
                v = self.value_of(candidate)
                if v is not None:  # 센서 오류인 항목은 건너뛴다
                    return (candidate, *v)
        return None

    # ----- 값 쓰기 -------------------------------------------------------------
    def set(self, oid, type_and_value):
        if oid not in self.table:
            return "not-writable"
        name, group, unit = self.table[oid]
        if group not in oidlib.WRITABLE_GROUPS:
            return "not-writable"
        parts = type_and_value.split(None, 1)
        if len(parts) != 2 or parts[0].lower() not in ("integer", "integer32", "gauge", "unsigned"):
            return "wrong-type"
        try:
            raw = int(parts[1])
        except ValueError:
            return "wrong-type"
        value = oidlib.from_snmp(raw, unit)

        if group == "control":
            error = self.client.send("POST", "/api/control", {"device": name, "value": value})
        elif group == "thresholds":
            error = self.client.send("PUT", "/api/thresholds", {name: value})
        else:
            error = self.client.send("PUT", "/api/settings", {name: int(value)})
        self._cache = None
        if error is None:
            return "DONE"
        code, _ = error
        # 409: 자동 모드라 수동 조작 잠김 → 지금 상태와 맞지 않는 값
        return "inconsistent-value" if code == 409 else "wrong-value"

    # ----- pass_persist 처리 ---------------------------------------------------
    def handle(self, lines):
        """명령 한 개를 처리한다. lines는 다음 줄을 돌려주는 함수. 응답 줄 목록을 돌려준다."""
        command = lines().strip()
        if command == "PING":
            return ["PONG"]
        if command in ("get", "getnext"):
            oid = lines().strip()
            try:
                result = self.get(oid) if command == "get" else self.getnext(oid)
            except Exception:
                result = None  # RMU 서버가 응답하지 않음
            if result is None:
                return ["NONE"]
            return [result[0], result[1], str(result[2])]
        if command == "set":
            oid = lines().strip()
            type_and_value = lines().strip()
            try:
                return [self.set(oid, type_and_value)]
            except Exception:
                return ["not-writable"]
        return ["NONE"]


def main():
    agent = Agent(RestClient())
    while True:
        line = sys.stdin.readline()
        if not line:  # snmpd가 끝남
            break
        line = line.lstrip("﻿")  # 일부 셸이 붙이는 BOM 제거
        if not line.strip():
            continue  # 빈 줄은 명령이 아니다
        first = [line]
        response = agent.handle(lambda: first.pop() if first else sys.stdin.readline())
        sys.stdout.write("\n".join(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
