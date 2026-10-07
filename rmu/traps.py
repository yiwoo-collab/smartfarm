"""
SNMP Trap(Notification) 보내기.

RMU에 새 이벤트가 생기면 NMS로 SNMPv2-Trap을 보낸다 (CLAUDE.md 5장 Notification).
net-snmp의 snmptrap 명령을 사용한다 (라즈베리파이: sudo apt install snmp).
보내는 값: 알람 등급(sfAlarmLevel.0)과 메시지(sfAlarmMessage.0)
"""

import shutil
import subprocess
import threading

import oids as oidlib


def trap_name_for(event):
    """이벤트 → Trap 이름. 보낼 필요 없는 이벤트는 None."""
    if event["type"] == "alarm":
        return event.get("trap")  # 습도처럼 Trap이 정해지지 않은 것은 None
    if event["type"] == "clear":
        return "alarmClear"
    if event["type"] == "info" and event["key"] == "sensor_fault" and event["message"].startswith("센서 오류"):
        return "sensorFault"
    return None


def build_command(oids, event, host, community):
    """snmptrap 명령 인자 목록. 테스트에서 확인할 수 있게 따로 만든다."""
    trap = trap_name_for(event)
    if trap is None:
        return None
    trap_oid = oidlib.notification_oid(oids, trap)
    level_oid = oids["base"] + oids["status"]["alarm_level"]["oid"] + ".0"
    message_oid = oidlib.trap_object_oid(oids, "alarm_message") + ".0"
    return ["snmptrap", "-v", "2c", "-c", community, host, "",  # '' = 현재 sysUpTime
            trap_oid, level_oid, "i", str(event["level"]), message_oid, "s", event["message"]]


class TrapSender:
    def __init__(self, host, community="public"):
        self.host = host if ":" in host else f"{host}:162"
        self.community = community
        self.oids = oidlib.load()
        if shutil.which("snmptrap") is None:
            print("[trap] snmptrap 명령이 없습니다. Trap을 보내지 않습니다 (sudo apt install snmp)")
            self.enabled = False
        else:
            self.enabled = True

    def send(self, event):
        cmd = build_command(self.oids, event, self.host, self.community)
        if cmd is None or not self.enabled:
            return
        # 화면/제어가 느려지지 않게 별도 스레드에서 보낸다
        threading.Thread(target=self._run, args=(cmd,), daemon=True).start()

    @staticmethod
    def _run(cmd):
        try:
            subprocess.run(cmd, timeout=5, check=True, capture_output=True)
        except Exception as e:
            print(f"[trap] 전송 실패: {e}")
