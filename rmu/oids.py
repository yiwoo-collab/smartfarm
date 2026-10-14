"""
oids.json 읽기와 값 변환 (CLAUDE.md 5-3).

이름 ↔ OID 연결과 값 변환은 이 모듈을 거쳐서만 한다.
  실제 값 = 원시값 × scale + offset      (예: temp1 = raw × 0.1 − 50)
  원시값 = (실제 값 − offset) ÷ scale
"""

import json
import os

OIDS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "oids.json")

# 우리 확장 MIB에서 SNMP로 쓸 수 있는 그룹
WRITABLE_GROUPS = ("thresholds", "control", "settings")


def load(path=OIDS_PATH):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def objects(oids, source=None, group=None):
    """항목 목록 (source: 'rmu' | 'pi', group: 'status' 등으로 거를 수 있다)"""
    return [o for o in oids["objects"]
            if (source is None or o["source"] == source) and (group is None or o["group"] == group)]


def by_name(oids):
    return {o["name"]: o for o in oids["objects"]}


def names(oids):
    return {o["name"] for o in oids["objects"]}


def unavailable(oids):
    """감지기가 없어 '정보없음'인 항목 이름"""
    return {o["name"] for o in oids["objects"] if not o.get("available", True)}


def to_value(raw, obj):
    """SNMP 원시값 → 실제 값"""
    if raw is None:
        return None
    if obj.get("type") in ("string", "table"):
        return raw
    return round(raw * obj.get("scale", 1) + obj.get("offset", 0), 4)


def to_raw(value, obj):
    """실제 값 → SNMP 원시값 (정수)"""
    if isinstance(value, bool):
        value = int(value)
    return int(round((float(value) - obj.get("offset", 0)) / obj.get("scale", 1)))


def notification_oid(oids, name):
    info = oids["notifications"].get(name)
    return info["oid"] if info else None


def trap_object_oid(oids, name):
    return oids["trap_objects"][name]["oid"]


def alarm_code_info(oids, code):
    """RMU/확장 알람 코드 → {'level', 'text'} 또는 None. 해제 코드(+100)는 원래 코드로 찾는다."""
    codes = oids["alarm_codes"]
    return codes.get(str(code)) or codes.get(str(code - 100))


def is_clear_code(oids, code):
    """해제 코드인가 (예: 101 = 1번 알람 해제, 303 = 203번 해제)"""
    codes = oids["alarm_codes"]
    return str(code) not in codes and str(code - 100) in codes


def oid_key(oid):
    """'.1.3.6.1' → (1, 3, 6, 1) : OID 크기 비교용"""
    return tuple(int(x) for x in oid.strip(".").split("."))
