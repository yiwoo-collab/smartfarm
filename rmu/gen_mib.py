"""
oids.json → SMARTFARM-MIB.mib 생성.

OID가 바뀌면 oids.json만 고치고 이 스크립트를 다시 실행한다.
  python rmu/gen_mib.py            (프로젝트 폴더에 SMARTFARM-MIB.mib 생성)
  python rmu/gen_mib.py --check    (파일이 oids.json과 일치하는지만 확인)

MIB 이름은 이름(snake_case) 앞에 sf를 붙인 camelCase로 만든다. 예: main_fan → sfMainFan
"""

import argparse
import os
import sys
from datetime import datetime, timezone

import oids as oidlib

MIB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "SMARTFARM-MIB.mib")

GROUP_TITLES = {
    "status": "Current values (read-only)",
    "thresholds": "Thresholds (read-write)",
    "control": "Device control (read-write)",
    "settings": "Night mode settings (read-write)",
}


def mib_name(name):
    return "sf" + "".join(part.capitalize() for part in name.split("_"))


def parent_and_arc(rel_oid, nodes):
    """'.1.1.1.1.5' → ('sfCurrentValues', 5)"""
    parts = rel_oid.strip(".").split(".")
    parent = "." + ".".join(parts[:-1]) if len(parts) > 1 else ""
    return (nodes[parent] if parent else "smartfarm"), parts[-1]


def generate(oids, last_updated=None):
    nodes = oids["nodes"]
    stamp = last_updated or datetime.now(timezone.utc).strftime("%Y%m%d0000Z")
    base_arcs = oids["base"].strip(".").split(".")
    # .1.3.6.1.4.1 = enterprises
    if base_arcs[:6] != ["1", "3", "6", "1", "4", "1"]:
        raise SystemExit("base는 .1.3.6.1.4.1(enterprises) 아래여야 합니다")
    module_parent = " ".join(base_arcs[6:])

    out = []
    w = out.append
    w("SMARTFARM-MIB DEFINITIONS ::= BEGIN")
    w("")
    w("-- Generated from oids.json by rmu/gen_mib.py. Do not edit by hand.")
    w("-- Temporary enterprise number. Replace when the official OIDs are assigned.")
    w("")
    w("IMPORTS")
    w("    MODULE-IDENTITY, OBJECT-TYPE, NOTIFICATION-TYPE, Integer32, enterprises")
    w("        FROM SNMPv2-SMI")
    w("    DisplayString")
    w("        FROM SNMPv2-TC;")
    w("")
    w("smartfarm MODULE-IDENTITY")
    w(f'    LAST-UPDATED "{stamp}"')
    w('    ORGANIZATION "Smartfarm RMU Capstone Team"')
    w('    CONTACT-INFO "Smartfarm RMU Capstone Team"')
    w('    DESCRIPTION  "Smartfarm Remote Monitoring Unit (Raspberry Pi 4B) MIB.')
    w('                  Scalars are accessed with the .0 instance suffix."')
    w(f'    REVISION     "{stamp}"')
    w('    DESCRIPTION  "Generated from oids.json."')
    w(f"    ::= {{ enterprises {module_parent} }}")
    w("")

    # 중간 노드
    for rel, name in sorted(nodes.items(), key=lambda kv: oidlib.oid_key(kv[0])):
        parent, arc = parent_and_arc(rel, nodes)
        w(f"{name:<20} OBJECT IDENTIFIER ::= {{ {parent} {arc} }}")
    w("")

    # 값 객체
    for group in oidlib.OBJECT_GROUPS:
        w(f"-- {GROUP_TITLES[group]}")
        w("")
        access = "read-only" if group == "status" else "read-write"
        for name, info in oids[group].items():
            if name.startswith("_"):
                continue
            parent, arc = parent_and_arc(info["oid"], nodes)
            w(f"{mib_name(name)} OBJECT-TYPE")
            w("    SYNTAX      Integer32")
            unit = info.get("snmp_unit", "")
            if unit:
                w(f'    UNITS       "{unit}"')
            w(f"    MAX-ACCESS  {access}")
            w("    STATUS      current")
            w(f'    DESCRIPTION "{info.get("desc", name)}"')
            w(f"    ::= {{ {parent} {arc} }}")
            w("")

    # Trap에 실어 보내는 객체
    for name, info in oids["trap_objects"].items():
        parent, arc = parent_and_arc(info["oid"], nodes)
        w(f"{mib_name(name)} OBJECT-TYPE")
        w("    SYNTAX      DisplayString")
        w("    MAX-ACCESS  accessible-for-notify")
        w("    STATUS      current")
        w(f'    DESCRIPTION "{info["desc"]} (UTF-8)"')
        w(f"    ::= {{ {parent} {arc} }}")
        w("")

    # Notification (SNMPv2-Trap)
    level = mib_name("alarm_level")
    message = mib_name("alarm_message")
    for name, info in oids["notifications"].items():
        parent, arc = parent_and_arc(info["oid"], nodes)
        w(f"{name} NOTIFICATION-TYPE")
        w(f"    OBJECTS     {{ {level}, {message} }}")
        w("    STATUS      current")
        w(f'    DESCRIPTION "{info["desc"]}"')
        w(f"    ::= {{ {parent} {arc} }}")
        w("")

    w("END")
    return "\n".join(out) + "\n"


def without_dates(text):
    return "\n".join(l for l in text.splitlines() if "LAST-UPDATED" not in l and "REVISION" not in l)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="MIB 파일이 oids.json과 일치하는지만 확인")
    args = parser.parse_args()
    text = generate(oidlib.load())
    if args.check:
        if not os.path.exists(MIB_PATH):
            sys.exit("SMARTFARM-MIB.mib가 없습니다. python rmu/gen_mib.py 로 만드세요")
        with open(MIB_PATH, encoding="utf-8") as f:
            same = without_dates(f.read()) == without_dates(text)
        print("일치합니다" if same else "다릅니다. python rmu/gen_mib.py 로 다시 만드세요")
        sys.exit(0 if same else 1)
    with open(MIB_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"생성: {os.path.abspath(MIB_PATH)}")


if __name__ == "__main__":
    main()
