"""
라즈베리파이 → RMU 실물 (교수님 PELKOREA-RMU-MIB) 연결 (CLAUDE.md 1장).

  RmuPoller     5초마다 SNMP Get으로 RMU 값을 읽어 RmuModel에 넣는다 (실사용 모드에서 사용)
  register_trap RMU의 addTrap(R.4.1)에 "라즈베리파이IP:포트"를 써서 Trap 수신자로 등록한다
  TrapReceiver  RMU가 보내는 alarmTrap(R.4.2)을 받아 알람 코드를 RmuModel에 넘긴다

OID와 값 변환(scale/offset)은 oids.json에서만 가져온다.
"""

import socket
import threading
import time

import oids as oidlib
from snmp_lite import SnmpClient, SnmpError, decode_message, TRAP_V2, SNMP_TRAP_OID

POLL_SECONDS = 5
# 주기적으로 읽는 RMU 항목 (oids.json name)
POLL_NAMES = ["ac_voltage", "ac_frequency", "temperature", "temp2", "door_front", "rmu_alarm", "ups_battery"]


def local_ip_for(host):
    """RMU 쪽으로 나가는 라즈베리파이의 IP (addTrap 등록용)"""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect((host, 9))
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"


class RmuPoller:
    def __init__(self, model, host, port=161, community="public", interval=POLL_SECONDS):
        self.model = model
        self.client = SnmpClient(host, port, community)
        self.interval = interval
        self.oids = oidlib.load()
        objs = oidlib.by_name(self.oids)
        self.items = [objs[n] for n in POLL_NAMES]
        self.last_alarm = 0
        self._stop = threading.Event()
        self._kick = threading.Event()
        model.rmu_used = True

    def poll_once(self):
        """한 번 읽기. 성공하면 True"""
        try:
            raw = self.client.get([o["oid"] + ".0" for o in self.items])
        except (SnmpError, OSError) as e:
            self.model.set_rmu_offline()
            print(f"[rmu] 조회 실패: {e}")
            return False
        values = {}
        for obj in self.items:
            values[obj["name"]] = oidlib.to_value(raw.get(obj["oid"].strip(".") + ".0"), obj)
        alarm = values.pop("rmu_alarm")
        self.model.set_external(values, "rmu")
        # alarm 스칼라가 바뀌면 알람으로 처리 (Trap을 놓쳤을 때 대비)
        if alarm is not None and int(alarm) != self.last_alarm:
            self.last_alarm = int(alarm)
            if self.last_alarm:
                self.model.handle_rmu_alarm(self.last_alarm, via="poll")
        return True

    def run(self):
        while not self._stop.is_set():
            self.poll_once()
            self._kick.wait(self.interval)
            self._kick.clear()

    def poll_now(self):
        """Trap을 받으면 바로 다시 읽는다"""
        self._kick.set()

    def start(self):
        threading.Thread(target=self.run, daemon=True).start()

    def stop(self):
        self._stop.set()
        self._kick.set()


def register_trap(host, port, write_community, my_ip, trap_port):
    """RMU addTrap(R.4.1)에 "IP:포트"를 쓴다. 실패하면 이유를 돌려준다."""
    oids = oidlib.load()
    obj = oidlib.by_name(oids)["add_trap"]
    try:
        SnmpClient(host, port, write_community).set(obj["oid"] + ".0", "s", f"{my_ip}:{trap_port}")
        return None
    except (SnmpError, OSError) as e:
        return str(e)


class TrapReceiver:
    """SNMPv2-Trap 받기 (기본 포트 1162: 162번은 관리자 권한이 필요)"""

    def __init__(self, model, port=1162, on_trap=None, community=None):
        self.model = model
        self.port = port
        self.on_trap = on_trap
        self.community = community  # None이면 커뮤니티를 따지지 않는다
        self.oids = oidlib.load()
        self.trap_oid = self.oids["rmu_trap"]["oid"].strip(".")
        self.alarm_oid = oidlib.by_name(self.oids)["rmu_alarm"]["oid"].strip(".")
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("0.0.0.0", port))
        self.port = self.sock.getsockname()[1]
        self.received = 0

    def handle(self, data):
        """Trap 하나 처리. 알람 코드를 찾으면 돌려준다."""
        msg = decode_message(data)
        if msg["pdu_type"] != TRAP_V2:
            return None
        if self.community and msg["community"] != self.community:
            return None
        vbs = {o: v for o, _, v in msg["varbinds"]}
        if vbs.get(SNMP_TRAP_OID) != self.trap_oid:
            return None
        code = None
        for oid, value in vbs.items():
            if oid.startswith(self.alarm_oid) and isinstance(value, int):
                code = value
        self.received += 1
        if code is not None:
            self.model.handle_rmu_alarm(code, via="trap")
        if self.on_trap:
            self.on_trap(code)
        return code

    def run(self):
        while True:
            try:
                data, _ = self.sock.recvfrom(65535)
                self.handle(data)
            except OSError:
                break
            except Exception as e:  # 잘못된 패킷은 무시
                print(f"[trap] 해석 실패: {e}")

    def start(self):
        threading.Thread(target=self.run, daemon=True).start()

    def close(self):
        self.sock.close()


def wait_until(cond, timeout=3.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.02)
    return cond()
