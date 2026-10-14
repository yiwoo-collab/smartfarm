"""
우리 farmAlarm Trap 보내기 (선택: NMS가 있을 때 --trap-host).

라즈베리파이가 계산한 농장 알람(발생·해제)을 NMS로 SNMPv2-Trap으로 알린다.
OID는 oids.json의 우리 확장 {rmu 6} (번호 임시). 보내는 값: 등급, 코드, 메시지.
net-snmp의 snmptrap 명령을 사용한다 (라즈베리파이: sudo apt install snmp).
"""

import shutil
import subprocess
import threading

import oids as oidlib


def build_command(oids, event, host, community):
    """snmptrap 명령 인자. 보낼 필요 없는 이벤트면 None"""
    if event["type"] not in ("alarm", "clear"):
        return None
    objs = oidlib.by_name(oids)
    return ["snmptrap", "-v", "2c", "-c", community, host, "",
            oidlib.notification_oid(oids, "farmAlarm"),
            objs["alarm_level"]["oid"] + ".0", "i", str(event["level"]),
            objs["alarm_code"]["oid"] + ".0", "i", str(event.get("code") or 0),
            oidlib.trap_object_oid(oids, "alarm_message") + ".0", "s", event["message"]]


class TrapSender:
    def __init__(self, host, community="public"):
        self.host = host if ":" in host else f"{host}:162"
        self.community = community
        self.oids = oidlib.load()
        self.enabled = shutil.which("snmptrap") is not None
        if not self.enabled:
            print("[trap] snmptrap 명령이 없습니다. Trap을 보내지 않습니다 (sudo apt install snmp)")

    def send(self, event):
        cmd = build_command(self.oids, event, self.host, self.community)
        if cmd is None or not self.enabled:
            return
        threading.Thread(target=self._run, args=(cmd,), daemon=True).start()

    @staticmethod
    def _run(cmd):
        try:
            subprocess.run(cmd, timeout=5, check=True, capture_output=True)
        except Exception as e:
            print(f"[trap] 전송 실패: {e}")
