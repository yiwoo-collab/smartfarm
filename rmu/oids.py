"""
oids.json 읽기와 SNMP 값 변환.

이름 ↔ OID 연결은 이 모듈을 거쳐서만 한다 (CLAUDE.md 10장).
REST는 사람이 읽는 단위(25.3℃), SNMP는 정수 단위(253 = 0.1℃)를 쓴다.
"""

import json
import os

OIDS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "oids.json")

# snmp_unit → REST 값에 곱할 배율 (SNMP 값 = REST 값 × 배율, 정수로 반올림)
UNIT_SCALE = {
    "0.1C": 10, "0.1%": 10, "%": 1, "mV": 1000, "mA": 1000, "mW": 1000,
    "ppm": 1, "0.01mS/cm": 100, "W": 1, "minutes": 1,
}

# SNMP로 값을 쓸 수 있는 그룹
WRITABLE_GROUPS = ("thresholds", "control", "settings")
OBJECT_GROUPS = ("status", "thresholds", "control", "settings")


def load(path=OIDS_PATH):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def objects(oids):
    """값 객체 목록: [(이름, 그룹, 전체 OID, snmp_unit, desc)]"""
    base = oids["base"]
    result = []
    for group in OBJECT_GROUPS:
        for name, info in oids[group].items():
            if name.startswith("_"):
                continue
            result.append((name, group, base + info["oid"], info.get("snmp_unit", ""), info.get("desc", "")))
    return result


def names(oids):
    return {name for name, *_ in objects(oids)}


def notification_oid(oids, trap_name):
    info = oids["notifications"].get(trap_name)
    return oids["base"] + info["oid"] if info else None


def trap_object_oid(oids, name):
    return oids["base"] + oids["trap_objects"][name]["oid"]


def to_snmp(value, unit):
    """REST 값 → SNMP 정수"""
    if isinstance(value, bool):
        return int(value)
    return int(round(float(value) * UNIT_SCALE.get(unit, 1)))


def from_snmp(value, unit):
    """SNMP 정수 → REST 값"""
    scale = UNIT_SCALE.get(unit, 1)
    return value if scale == 1 else value / scale


def oid_key(oid):
    """'.1.3.6.1' → (1, 3, 6, 1) : OID 크기 비교용"""
    return tuple(int(x) for x in oid.strip(".").split("."))
