"""
RMU 서버 (REST API)

  - PC (0단계 모의 RMU): python server.py
      하드웨어 없이 모든 값을 시뮬레이션한다. Python 표준 라이브러리만 필요.
  - 라즈베리파이 (1단계 실물): python server.py --hardware --trap-host <NMS IP>
      센서·릴레이는 hardware.py, SNMP 조회·Set은 snmp_agent.py(snmpd가 실행), Trap은 traps.py.

상태와 규칙은 rmu_model.py, 이 파일은 HTTP 처리만 한다 (CLAUDE.md 6장).

  GET  /api/status                현재값, 알람 등급, 제어 상태
  GET  /api/power                 전압·전류·전력, 온실 전체 사용 전력(W, kWh)
  GET  /api/thresholds            임계값 조회
  PUT  /api/thresholds   (관리자) 임계값 변경
  POST /api/control      (관리자) 장치 조작 {"device": "aircon", "value": 1}
  GET  /api/settings              야간 모드 설정 조회
  PUT  /api/settings     (관리자) 야간 모드 설정 변경
  GET  /api/events?since=<id>     이벤트와 조치 내역 (SQLite에 저장)
  GET  /api/history?sensor=temperature&range=1h   센서 기록 그래프 (1h, 6h, 24h, 7d)
  POST /api/login                 관리자 로그인 → 토큰
  GET  /api/simulate              시뮬레이션 목록
  POST /api/simulate              시뮬레이션 주입 {"scenario": "high_temp", "severe": true}

실행:  python server.py              (기본 포트 8080, 모의)
       python server.py --port 8081  (농장을 하나 더 띄울 때)
"""

import argparse
import json
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import oids as oidlib
from rmu_model import PARTS, SCENARIOS, TICK_SECONDS, ControlError, RmuModel

HERE = os.path.dirname(os.path.abspath(__file__))

# 개발용 관리자 계정 (모의 서버 테스트 값).
# 라즈베리파이에서는 admin.json({"username": ..., "password": ...})을 만들어 바꾼다.
MOCK_ADMIN = {"username": "admin", "password": "admin1234"}
ADMIN_PATH = os.path.join(HERE, "admin.json")

# 같은 라즈베리파이의 SNMP 에이전트(snmp_agent.py)가 Set을 REST로 전달할 때 쓰는 토큰.
# 서버가 시작할 때 새로 만들어 .internal_token_<포트> 파일에 쓴다 (외부로 나가지 않음).
def internal_token_path(port):
    return os.path.join(HERE, f".internal_token_{port}")

rmu = RmuModel()
tokens = set()  # 로그인으로 발급한 토큰
admin = dict(MOCK_ADMIN)


def load_admin():
    if os.path.exists(ADMIN_PATH):
        with open(ADMIN_PATH, encoding="utf-8") as f:
            return json.load(f)
    return dict(MOCK_ADMIN)


class Handler(BaseHTTPRequestHandler):
    # ----- 공통 ------------------------------------------------------------
    def _send_json(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")  # 웹 빌드에서 테스트할 때 필요
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

    def _route(self):
        return urlparse(self.path).path

    def _comm_lost(self):
        """통신 두절 시뮬레이션 중이면 /api/simulate 외에는 응답하지 않은 것처럼 503"""
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

    # ----- GET -------------------------------------------------------------
    def do_GET(self):
        if self._comm_lost():
            return
        route = self._route()
        if route == "/api/status":
            self._send_json(200, rmu.status())
        elif route == "/api/power":
            self._send_json(200, rmu.power())
        elif route == "/api/thresholds":
            self._send_json(200, dict(rmu.thresholds))
        elif route == "/api/settings":
            self._send_json(200, dict(rmu.settings))
        elif route == "/api/events":
            query = parse_qs(urlparse(self.path).query)
            try:
                since = int(query.get("since", ["0"])[0])
            except ValueError:
                self._send_json(400, {"error": "since는 이벤트 번호(정수)입니다"})
                return
            # last_id: 앱이 RMU 재시작(번호가 1부터 다시 시작)을 알아챌 수 있게 함께 보낸다
            self._send_json(200, {"events": rmu.get_events(since), "last_id": rmu.next_event_id - 1})
        elif route == "/api/history":
            query = parse_qs(urlparse(self.path).query)
            sensor = query.get("sensor", ["temperature"])[0]
            range_name = query.get("range", ["1h"])[0]
            try:
                points = rmu.history(sensor, range_name)
            except ValueError as e:
                self._send_json(400, {"error": str(e)})
                return
            self._send_json(200, {"sensor": sensor, "range": range_name, "points": points})
        elif route == "/api/crops":
            # 작물별 임계값 기본값 (crops.json)
            with open(os.path.join(HERE, "crops.json"), encoding="utf-8") as f:
                self._send_json(200, json.load(f)["crops"])
        elif route == "/api/simulate":
            self._send_json(200, {"scenarios": SCENARIOS, "parts": PARTS})
        else:
            self._send_json(404, {"error": "not found"})

    # ----- POST / PUT ------------------------------------------------------
    def do_POST(self):
        if self._comm_lost():
            return
        route = self._route()
        try:
            body = self._read_json()
        except (ValueError, json.JSONDecodeError):
            self._send_json(400, {"error": "JSON 형식이 아닙니다"})
            return

        if route == "/api/login":
            if (body.get("username") == admin["username"]
                    and body.get("password") == admin["password"]):
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
            if not self._is_admin():
                self._send_json(401, {"error": "로그인이 필요합니다"})
                return
            try:
                control = rmu.apply_control(body.get("device"), body.get("value"))
            except ControlError as e:
                self._send_json(e.code, {"error": e.message})
                return
            self._send_json(200, {"ok": True, "control": control})
        else:
            self._send_json(404, {"error": "not found"})

    def do_PUT(self):
        if self._comm_lost():
            return
        route = self._route()
        if route not in ("/api/thresholds", "/api/settings"):
            self._send_json(404, {"error": "not found"})
            return
        if not self._is_admin():
            self._send_json(401, {"error": "로그인이 필요합니다"})
            return
        try:
            body = self._read_json()
            if route == "/api/thresholds":
                result = rmu.update_thresholds(body)
            else:
                result = rmu.update_settings(body)
        except (ValueError, json.JSONDecodeError) as e:
            self._send_json(400, {"error": str(e)})
            return
        self._send_json(200, result)

    def log_message(self, fmt, *args):
        pass  # 5초마다 오는 요청 로그는 생략 (이벤트만 출력)


push_sender = None  # --push-url을 주면 PushSender


def tick_loop():
    while True:
        rmu.tick()
        if push_sender is not None:
            with rmu.lock:
                active = dict(rmu.active)
            push_sender.remind(active)  # 긴급 경보 반복 푸시
        time.sleep(TICK_SECONDS)


def check_oid_names(model):
    """응답에 쓰는 이름이 oids.json에 모두 있는지 확인 (이름-OID 연결이 어긋나지 않게)"""
    names = oidlib.names(oidlib.load())
    used = (set(model.values) | set(model.base) | set(model.settings) | set(model.thresholds)
            | {"supply_power", "greenhouse_power", "alarm_level"})
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
        # snmpd(Debian-snmp 사용자)가 실행하는 snmp_agent.py도 읽어야 하므로 읽기는 허용,
        # 쓰기는 소유자만. 토큰은 127.0.0.1의 REST 호출에만 쓰인다.
        os.chmod(path, 0o644)
    except OSError:
        pass


def main():
    global rmu, admin, push_sender
    parser = argparse.ArgumentParser(description="RMU 서버 (기본: 모의 RMU)")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--hardware", action="store_true", help="라즈베리파이 실물 센서·릴레이 사용")
    parser.add_argument("--trap-host", help="SNMP Trap을 받을 NMS 주소 (예: 192.168.0.20)")
    parser.add_argument("--trap-community", default="public")
    parser.add_argument("--db", help="SQLite 기록 파일 (기본: rmu/data/rmu_<포트>.db)")
    parser.add_argument("--no-db", action="store_true", help="기록하지 않음 (이벤트는 메모리에만)")
    parser.add_argument("--push-url", help="푸시 알림 주소 (ntfy 토픽 URL 등). 앱이 꺼져 있어도 알림")
    parser.add_argument("--push-min-level", type=int, default=2, help="이 등급 이상만 푸시 (기본 2=경보)")
    parser.add_argument("--farm-name", default="스마트팜", help="푸시 알림 제목에 쓸 농장 이름")
    args = parser.parse_args()

    hardware = None
    if args.hardware:
        from hardware import Hardware  # PC에서는 불러오지 않는다
        hardware = Hardware()
        print("[hardware] " + hardware.summary())
    storage = None
    if not args.no_db:
        from storage import Storage
        db_path = args.db or os.path.join(HERE, "data", f"rmu_{args.port}.db")
        os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
        storage = Storage(db_path)
        print(f"[db] 기록 파일: {db_path}")
    rmu = RmuModel(hardware=hardware, storage=storage)
    check_oid_names(rmu)

    admin = load_admin()
    if args.hardware and admin == MOCK_ADMIN:
        print("[주의] 개발용 관리자 계정을 쓰고 있습니다. rmu/admin.json을 만들어 바꾸세요.")
    write_internal_token(args.port)

    if args.trap_host:
        from traps import TrapSender
        sender = TrapSender(args.trap_host, args.trap_community)
        rmu.event_listeners.append(sender.send)
        print(f"[trap] {sender.host} 로 Trap을 보냅니다")

    if args.push_url:
        from push import PushSender
        push_sender = PushSender(args.push_url, args.farm_name, args.push_min_level)
        rmu.event_listeners.append(push_sender.on_event)
        print(f"[push] {args.push_url} 로 푸시 알림을 보냅니다 (등급 {args.push_min_level} 이상)")

    threading.Thread(target=tick_loop, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    mode = "실물 RMU" if args.hardware else "모의 RMU"
    print(f"{mode} 서버 실행 중: http://localhost:{args.port}/api/status  (종료: Ctrl+C)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n종료합니다")
    finally:
        if hardware is not None:
            hardware.close()  # 릴레이를 모두 끈다


if __name__ == "__main__":
    main()
