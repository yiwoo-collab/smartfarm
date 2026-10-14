"""
라즈베리파이 게이트웨이 서버 (REST API, CLAUDE.md 6장) — v3.0

  - PC 개발 (데모 모드, 모든 값 시뮬레이션):  python server.py
  - PC에서 모의 RMU 실물과 시험:              python mock_pelkorea_rmu.py
                                              python server.py --rmu-host 127.0.0.1 --rmu-port 1161
  - 라즈베리파이 (실사용):                   python server.py --hardware --rmu-host <RMU IP>

앱은 이 서버에만 접속한다. RMU 값은 rmu_client.py가 SNMP로 읽고, Trap도 받는다.
상태와 규칙은 rmu_model.py.

  GET  /api/status                 현재값, 상태(ok/nodata/fault/offline), 알람 등급·코드, 제어 상태, 모드
  GET  /api/power                  전원 상태(AC 전압·주파수, UPS), 전체 사용 전력(W, kWh)
  GET/PUT /api/thresholds          임계값 (PUT은 관리자)
  POST /api/control      (관리자) 장치 조작 {"device": "aircon", "value": 1}
  GET/PUT /api/settings            야간 모드 (PUT은 관리자)
  GET/PUT /api/mode                AI 모드 demo/live (PUT은 관리자)
  GET  /api/ai/suggestions         실사용 모드 AI 제안과 판단 이유
  POST /api/ai/suggestions/<id>/approve | reject   (관리자)
  GET  /api/events?since=<id>      이벤트와 조치 내역
  GET  /api/history?sensor=&range= 기록 그래프
  GET  /api/crops                  작물별 임계값 기본값
  POST /api/login                  관리자 로그인 → 토큰
  GET/POST /api/simulate           시뮬레이션 목록 / 주입
"""

import argparse
import json
import os
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import oids as oidlib
from rmu_model import PARTS, SCENARIOS, TICK_SECONDS, ControlError, RmuModel

HERE = os.path.dirname(os.path.abspath(__file__))

# 개발용 관리자 계정 (모의 서버 테스트 값). 라즈베리파이에서는 admin.json으로 바꾼다.
MOCK_ADMIN = {"username": "admin", "password": "admin1234"}
ADMIN_PATH = os.path.join(HERE, "admin.json")


def internal_token_path(port):
    """같은 라즈베리파이의 snmp_agent.py가 Set을 REST로 넘길 때 쓰는 토큰 파일"""
    return os.path.join(HERE, f".internal_token_{port}")


rmu = RmuModel()
tokens = set()
admin = dict(MOCK_ADMIN)
push_sender = None
hardware = None
poller = None


def load_admin():
    if os.path.exists(ADMIN_PATH):
        with open(ADMIN_PATH, encoding="utf-8") as f:
            return json.load(f)
    return dict(MOCK_ADMIN)


SUGGESTION_ROUTE = re.compile(r"^/api/ai/suggestions/(\d+)/(approve|reject)$")


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if not isinstance(body, dict):
            raise ValueError("JSON 객체가 아닙니다")
        return body

    def _is_admin(self):
        auth = self.headers.get("Authorization", "")
        return auth.startswith("Bearer ") and auth[7:] in tokens

    def _require_admin(self):
        if not self._is_admin():
            self._send_json(401, {"error": "로그인이 필요합니다"})
            return False
        return True

    def _route(self):
        return urlparse(self.path).path

    def _comm_lost(self):
        """통신 두절 시뮬레이션 중이면 /api/simulate 외에는 503 (앱 ↔ 라즈베리파이 두절)"""
        with rmu.lock:
            lost = rmu.comm_lost()
        if lost and self._route() != "/api/simulate":
            self._send_json(503, {"error": "통신 두절 (시뮬레이션)"})
            return True
        return False

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    # ----- GET -----------------------------------------------------------------
    def do_GET(self):
        if self._comm_lost():
            return
        route = self._route()
        query = parse_qs(urlparse(self.path).query)
        if route == "/api/status":
            self._send_json(200, rmu.status())
        elif route == "/api/power":
            self._send_json(200, rmu.power())
        elif route == "/api/thresholds":
            self._send_json(200, dict(rmu.thresholds))
        elif route == "/api/settings":
            self._send_json(200, dict(rmu.settings))
        elif route == "/api/mode":
            self._send_json(200, {"mode": rmu.mode})
        elif route == "/api/ai/suggestions":
            self._send_json(200, {"mode": rmu.mode, "suggestions": rmu.list_suggestions()})
        elif route == "/api/events":
            try:
                since = int(query.get("since", ["0"])[0])
            except ValueError:
                self._send_json(400, {"error": "since는 이벤트 번호(정수)입니다"})
                return
            self._send_json(200, {"events": rmu.get_events(since), "last_id": rmu.next_event_id - 1})
        elif route == "/api/history":
            try:
                points = rmu.history(query.get("sensor", ["temperature"])[0], query.get("range", ["1h"])[0])
            except ValueError as e:
                self._send_json(400, {"error": str(e)})
                return
            self._send_json(200, {"sensor": query.get("sensor", ["temperature"])[0],
                                  "range": query.get("range", ["1h"])[0], "points": points})
        elif route == "/api/crops":
            with open(os.path.join(HERE, "crops.json"), encoding="utf-8") as f:
                self._send_json(200, json.load(f)["crops"])
        elif route == "/api/simulate":
            self._send_json(200, {"scenarios": SCENARIOS, "parts": PARTS})
        else:
            self._send_json(404, {"error": "not found"})

    # ----- POST ----------------------------------------------------------------
    def do_POST(self):
        if self._comm_lost():
            return
        route = self._route()
        try:
            body = self._read_json()
        except (ValueError, json.JSONDecodeError):
            self._send_json(400, {"error": "JSON 형식이 아닙니다"})
            return

        match = SUGGESTION_ROUTE.match(route)
        if route == "/api/login":
            if body.get("username") == admin["username"] and body.get("password") == admin["password"]:
                token = secrets.token_hex(16)
                tokens.add(token)
                self._send_json(200, {"token": token})
            else:
                self._send_json(401, {"error": "아이디 또는 비밀번호가 틀렸습니다"})
        elif route == "/api/simulate":
            name = body.get("scenario")
            try:
                message = rmu.simulate(name, body)
            except KeyError:
                self._send_json(400, {"error": f"알 수 없는 시나리오: {name}",
                                      "scenarios": sorted({s['name'] for s in SCENARIOS})})
                return
            except ValueError as e:
                self._send_json(400, {"error": str(e)})
                return
            self._send_json(200, {"ok": True, "scenario": name, "message": message})
        elif route == "/api/control":
            if not self._require_admin():
                return
            try:
                control = rmu.apply_control(body.get("device"), body.get("value"))
            except ControlError as e:
                self._send_json(e.code, {"error": e.message})
                return
            self._send_json(200, {"ok": True, "control": control})
        elif match:
            if not self._require_admin():
                return
            try:
                result = rmu.decide_suggestion(int(match.group(1)), match.group(2) == "approve")
            except ControlError as e:
                self._send_json(e.code, {"error": e.message})
                return
            self._send_json(200, result)
        else:
            self._send_json(404, {"error": "not found"})

    # ----- PUT -----------------------------------------------------------------
    def do_PUT(self):
        if self._comm_lost():
            return
        route = self._route()
        if route not in ("/api/thresholds", "/api/settings", "/api/mode"):
            self._send_json(404, {"error": "not found"})
            return
        if not self._require_admin():
            return
        try:
            body = self._read_json()
            if route == "/api/thresholds":
                result = rmu.update_thresholds(body)
            elif route == "/api/settings":
                result = rmu.update_settings(body)
            else:
                result = rmu.set_mode(body.get("mode"))
        except (ValueError, json.JSONDecodeError) as e:
            self._send_json(400, {"error": str(e)})
            return
        self._send_json(200, result)

    def log_message(self, fmt, *args):
        pass


def tick_loop():
    while True:
        if hardware is not None:
            rmu.set_external(hardware.read(), "pi")  # 라즈베리파이 직결 감지기
            rmu.hw_fan_failed = hardware.fan_failures(rmu.control)
        rmu.tick()
        if push_sender is not None:
            with rmu.lock:
                active = dict(rmu.active)
            push_sender.remind(active)
        time.sleep(TICK_SECONDS)


def check_oid_names(model):
    """응답에 쓰는 이름이 oids.json에 모두 있는지 확인"""
    names = oidlib.names(oidlib.load())
    used = (set(model.values) | set(model.base) | set(model.settings) | set(model.thresholds)
            | {"greenhouse_power", "alarm_level", "alarm_code"})
    missing = used - names
    if missing:
        raise SystemExit(f"oids.json에 없는 이름: {sorted(missing)}")


def write_internal_token(port):
    token = secrets.token_hex(16)
    tokens.add(token)
    path = internal_token_path(port)
    with open(path, "w", encoding="utf-8") as f:
        f.write(token)
    try:
        os.chmod(path, 0o644)  # snmpd(Debian-snmp)도 읽어야 한다. 토큰은 127.0.0.1 REST에만 쓰인다
    except OSError:
        pass


def main():
    global rmu, admin, push_sender, hardware, poller
    p = argparse.ArgumentParser(description="스마트팜 게이트웨이 서버 (기본: 데모 모드)")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--mode", choices=["demo", "live"], help="AI 모드 (기본: RMU·하드웨어를 쓰면 live, 아니면 demo)")
    p.add_argument("--hardware", action="store_true", help="라즈베리파이 직결 감지기·릴레이 사용")
    p.add_argument("--rmu-host", help="RMU 실물 주소 (SNMP로 조회)")
    p.add_argument("--rmu-port", type=int, default=161)
    p.add_argument("--rmu-community", default="public")
    p.add_argument("--rmu-write-community", default="private", help="addTrap 등록용 쓰기 커뮤니티")
    p.add_argument("--trap-listen-port", type=int, default=1162, help="RMU Trap을 받을 포트")
    p.add_argument("--pi-ip", help="addTrap에 쓸 라즈베리파이 IP (기본: 자동)")
    p.add_argument("--trap-host", help="우리 farmAlarm Trap을 보낼 NMS 주소 (선택)")
    p.add_argument("--trap-community", default="public")
    p.add_argument("--db", help="SQLite 기록 파일 (기본: rmu/data/rmu_<포트>.db)")
    p.add_argument("--no-db", action="store_true")
    p.add_argument("--push-url", help="푸시 알림 주소 (ntfy 토픽 URL 등)")
    p.add_argument("--push-min-level", type=int, default=2)
    p.add_argument("--farm-name", default="스마트팜")
    args = p.parse_args()

    if args.hardware:
        from hardware import Hardware
        hardware = Hardware()
        print("[hardware] " + hardware.summary())
    storage = None
    if not args.no_db:
        from storage import Storage
        db_path = args.db or os.path.join(HERE, "data", f"rmu_{args.port}.db")
        os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
        storage = Storage(db_path)
        print(f"[db] 기록 파일: {db_path}")

    oids = oidlib.load()
    mode = args.mode or ("live" if (args.hardware or args.rmu_host) else "demo")
    rmu = RmuModel(hardware=hardware, storage=storage, unavailable=oidlib.unavailable(oids), mode=mode)
    check_oid_names(rmu)

    admin = load_admin()
    if (args.hardware or args.rmu_host) and admin == MOCK_ADMIN:
        print("[주의] 개발용 관리자 계정을 쓰고 있습니다. rmu/admin.json을 만들어 바꾸세요.")
    write_internal_token(args.port)

    if args.rmu_host:
        from rmu_client import RmuPoller, TrapReceiver, local_ip_for, register_trap
        poller = RmuPoller(rmu, args.rmu_host, args.rmu_port, args.rmu_community)
        receiver = TrapReceiver(rmu, args.trap_listen_port, on_trap=lambda code: poller.poll_now())
        receiver.start()
        my_ip = args.pi_ip or local_ip_for(args.rmu_host)
        error = register_trap(args.rmu_host, args.rmu_port, args.rmu_write_community, my_ip, receiver.port)
        print(f"[rmu] {args.rmu_host}:{args.rmu_port} 조회 시작, Trap 수신 udp/{receiver.port}, "
              + (f"addTrap 등록 {my_ip}:{receiver.port}" if error is None else f"addTrap 등록 실패: {error}"))
        poller.start()

    if args.trap_host:
        from traps import TrapSender
        sender = TrapSender(args.trap_host, args.trap_community)
        rmu.event_listeners.append(sender.send)
    if args.push_url:
        from push import PushSender
        push_sender = PushSender(args.push_url, args.farm_name, args.push_min_level)
        rmu.event_listeners.append(push_sender.on_event)

    threading.Thread(target=tick_loop, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"게이트웨이 서버 실행 중 ({'데모' if mode == 'demo' else '실사용'} 모드): "
          f"http://localhost:{args.port}/api/status  (종료: Ctrl+C)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n종료합니다")
    finally:
        if hardware is not None:
            hardware.close()


if __name__ == "__main__":
    main()
