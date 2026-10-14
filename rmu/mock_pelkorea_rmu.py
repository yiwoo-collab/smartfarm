"""
모의 RMU 실물 — 교수님 PELKOREA-RMU-MIB를 흉내 내는 SNMP v2c 에이전트 (PC 개발·시험용).

실물 RMU 없이 라즈베리파이 게이트웨이(server.py --rmu-host)를 시험하려고 만든 것이다.
  - SNMP Get/GetNext/Set 응답 (값은 MIB 원시값: temp1 = 온도×10 + 500, acv1 = 전압×10)
  - addTrap(R.4.1)에 "IP:포트"를 쓰면 그 주소로 alarmTrap(R.4.2)을 보낸다
  - 알람 발생/해제는 HTTP로 흉내 낸다:
      http://localhost:8091/alarm?code=61   → alarm=61, Trap 전송
      http://localhost:8091/clear?code=61   → alarm=161, Trap 전송
      http://localhost:8091/set?name=temp1&value=800   (원시값 직접 설정)

실행:  python mock_pelkorea_rmu.py              (SNMP UDP 1161, HTTP 8091)
       python mock_pelkorea_rmu.py --snmp-port 161   (관리자 권한 필요)
"""

import argparse
import random
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import oids as oidlib
from snmp_lite import (GET, GET_NEXT, RESPONSE, SET, SNMP_TRAP_OID, SYS_UPTIME_OID, TRAP_V2,
                       decode_message, encode_message)


class MockRmu:
    def __init__(self, ro_community="public", rw_community="private"):
        self.ro, self.rw = ro_community, rw_community
        self.lock = threading.Lock()
        self.start_time = time.time()
        oids = oidlib.load()
        self.by_mib = {o["mib"]: o for o in oidlib.objects(oids, source="rmu") if "mib" in o}
        self.trap_oid = oids["rmu_trap"]["oid"].strip(".")
        # MIB 원시값 (temp1 = 25.0℃ → 750, acv1 = 220.0V → 2200)
        self.raw = {
            "acv1": 2200, "ach1": 600, "temp1": 750, "temp2": 740, "doorFront": 0, "alarm": 0,
            "setAcv1Uvt": 1980, "setAcv1Ovt": 2420, "setTempU": 450, "setTempO": 1000,
            "upsIpv": 2200, "upsOpv": 2200, "upsOpc": 12, "upsBl": 100, "upsBb": 0, "upsBz": 0,
            "upsShutdown": "", "addTrap": "",
        }
        self.trap_targets = set()
        self.traps_sent = 0

    # ----- 값 흉내 ------------------------------------------------------------
    def drift(self):
        with self.lock:
            # 실제 온도처럼 천천히: 25.0℃(750)로 돌아가며 ±0.1℃ 정도만 흔들린다
            self.raw["temp1"] += int(round(0.1 * (750 - self.raw["temp1"]) + random.uniform(-1, 1)))
            self.raw["temp2"] = self.raw["temp1"] - 10 + random.randint(-2, 2)
            self.raw["acv1"] = 2200 + random.randint(-15, 15)
            self.raw["ach1"] = 600 + random.randint(-1, 1)

    def instance_table(self):
        """{인스턴스 OID(.0): (MIB 이름, 종류)} 정렬"""
        table = {}
        for name, obj in self.by_mib.items():
            if obj.get("type") == "table":
                continue
            kind = "s" if obj.get("type") == "string" else "i"
            table[obj["oid"].strip(".") + ".0"] = (name, kind)
        return dict(sorted(table.items(), key=lambda kv: oidlib.oid_key(kv[0])))

    # ----- SNMP 처리 ------------------------------------------------------------
    def handle(self, data):
        msg = decode_message(data)
        community, rid = msg["community"], msg["request_id"]
        if community not in (self.ro, self.rw):
            return None  # 커뮤니티가 틀리면 응답하지 않는다 (SNMP 관례)
        table = self.instance_table()
        out = []
        with self.lock:
            if msg["pdu_type"] == GET:
                for oid, _, _ in msg["varbinds"]:
                    if oid in table:
                        name, kind = table[oid]
                        out.append((oid, kind, self.raw[name]))
                    else:
                        out.append((oid, "noSuchObject", None))
            elif msg["pdu_type"] == GET_NEXT:
                for oid, _, _ in msg["varbinds"]:
                    key = oidlib.oid_key(oid)
                    nxt = next((o for o in table if oidlib.oid_key(o) > key), None)
                    if nxt:
                        name, kind = table[nxt]
                        out.append((nxt, kind, self.raw[name]))
                    else:
                        out.append((oid, "endOfMibView", None))
            elif msg["pdu_type"] == SET:
                if community != self.rw:
                    return encode_message(community, RESPONSE, rid, msg["varbinds"], 6, 1)  # noAccess
                for i, (oid, kind, value) in enumerate(msg["varbinds"], 1):
                    if oid not in table or self.by_mib[table[oid][0]]["access"] == "ro":
                        return encode_message(community, RESPONSE, rid, msg["varbinds"], 17, i)  # notWritable
                    name, want = table[oid]
                    if kind != want:
                        return encode_message(community, RESPONSE, rid, msg["varbinds"], 7, i)  # wrongType
                    self.raw[name] = value
                    if name == "addTrap" and value:
                        self.trap_targets.add(value)
                    out.append((oid, kind, value))
            else:
                return None
        return encode_message(community, RESPONSE, rid, out)

    def send_trap(self):
        """alarmTrap: sysUpTime, snmpTrapOID, alarm.0"""
        alarm_oid = self.by_mib["alarm"]["oid"].strip(".") + ".0"
        uptime = int((time.time() - self.start_time) * 100)
        packet = encode_message(self.ro, TRAP_V2, random.randint(1, 2**31 - 1), [
            (SYS_UPTIME_OID, "t", uptime), (SNMP_TRAP_OID, "o", self.trap_oid),
            (alarm_oid, "i", self.raw["alarm"])])
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            for target in list(self.trap_targets):
                host, _, port = target.rpartition(":")
                try:
                    s.sendto(packet, (host, int(port)))
                    self.traps_sent += 1
                except (OSError, ValueError) as e:
                    print(f"[모의 RMU] Trap 전송 실패 {target}: {e}")

    def raise_alarm(self, code):
        with self.lock:
            self.raw["alarm"] = code
        self.send_trap()


def serve_snmp(rmu, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    port = sock.getsockname()[1]

    def loop():
        while True:
            try:
                data, addr = sock.recvfrom(65535)
                reply = rmu.handle(data)
                if reply:
                    sock.sendto(reply, addr)
            except OSError:
                break
            except Exception as e:
                print(f"[모의 RMU] 잘못된 요청: {e}")
    threading.Thread(target=loop, daemon=True).start()
    return sock, port


def make_http_handler(rmu):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            url = urlparse(self.path)
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            try:
                if url.path == "/alarm":
                    rmu.raise_alarm(int(q["code"]))
                elif url.path == "/clear":
                    rmu.raise_alarm(int(q["code"]) + 100)
                elif url.path == "/set":
                    with rmu.lock:
                        rmu.raw[q["name"]] = int(q["value"])
                elif url.path != "/":
                    raise KeyError(url.path)
                body = f"ok {rmu.raw} traps_sent={rmu.traps_sent} targets={sorted(rmu.trap_targets)}"
                self.send_response(200)
            except (KeyError, ValueError) as e:
                body = f"error {e}"
                self.send_response(400)
            data = body.encode("utf-8")
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass
    return Handler


def main():
    parser = argparse.ArgumentParser(description="모의 RMU 실물 (PELKOREA-RMU-MIB)")
    parser.add_argument("--snmp-port", type=int, default=1161)
    parser.add_argument("--http-port", type=int, default=8091)
    args = parser.parse_args()
    rmu = MockRmu()
    _, port = serve_snmp(rmu, args.snmp_port)
    http = ThreadingHTTPServer(("0.0.0.0", args.http_port), make_http_handler(rmu))
    threading.Thread(target=http.serve_forever, daemon=True).start()
    print(f"모의 RMU 실행 중: SNMP udp/{port} (public/private), 제어 http://localhost:{args.http_port}/")
    try:
        while True:
            rmu.drift()
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n종료합니다")


if __name__ == "__main__":
    main()
