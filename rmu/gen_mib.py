"""
oids.json → SMARTFARM-EXT-MIB.mib (우리 확장 {rmu 6}) 생성.

교수님 PELKOREA-RMU-MIB(RMU 실물)는 그대로 두고, 라즈베리파이가 제공하는 스마트팜 항목만
확장 MIB로 만든다. 번호는 임시이며 교수님 확인이 필요하다 (CLAUDE.md 5-2).
  python rmu/gen_mib.py            생성
  python rmu/gen_mib.py --check    oids.json과 일치하는지 확인
"""

import argparse
import os
import sys
from datetime import datetime, timezone

import oids as oidlib

MIB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "SMARTFARM-EXT-MIB.mib")
ENTERPRISES = "1.3.6.1.4.1"
GROUP_TITLES = {"status": "Current values (read-only)", "thresholds": "Thresholds (read-write)",
                "control": "Device control (read-write)", "settings": "Settings (read-write)"}


def mib_name(name):
    return "sf" + "".join(part.capitalize() for part in name.split("_"))


def generate(oids, last_updated=None):
    stamp = last_updated or datetime.now(timezone.utc).strftime("%Y%m%d0000Z")
    nodes = {k.strip("."): v for k, v in oids["ext_nodes"].items()}
    root = oids["ext_base"].strip(".")
    rel = root[len(ENTERPRISES) + 1:].replace(".", " ")
    nodes[root] = "smartfarmExt"  # 최상위 노드 = 모듈 이름

    def parent_arc(oid):
        oid = oid.strip(".")
        parent, arc = oid.rsplit(".", 1)
        return nodes.get(parent, "smartfarmExt" if parent == root else None), arc

    out = []
    w = out.append
    w("SMARTFARM-EXT-MIB DEFINITIONS ::= BEGIN")
    w("")
    w("-- Generated from oids.json by rmu/gen_mib.py. Do not edit by hand.")
    w("-- Smartfarm extension under the PELKOREA RMU tree ({ rmu 6 }). Numbers are temporary.")
    w("")
    w("IMPORTS")
    w("    MODULE-IDENTITY, OBJECT-TYPE, NOTIFICATION-TYPE, Integer32, enterprises")
    w("        FROM SNMPv2-SMI")
    w("    DisplayString")
    w("        FROM SNMPv2-TC;")
    w("")
    w("smartfarmExt MODULE-IDENTITY")
    w(f'    LAST-UPDATED "{stamp}"')
    w('    ORGANIZATION "Smartfarm Capstone Team"')
    w('    CONTACT-INFO "Smartfarm Capstone Team"')
    w('    DESCRIPTION  "Smartfarm items provided by the Raspberry Pi gateway.')
    w('                  Scalars are accessed with the .0 instance suffix."')
    w(f'    REVISION     "{stamp}"')
    w('    DESCRIPTION  "Generated from oids.json (v3.0)."')
    w(f"    ::= {{ enterprises {rel} }}")
    w("")
    for oid, name in sorted(nodes.items(), key=lambda kv: oidlib.oid_key(kv[0])):
        if oid == root:
            continue
        parent, arc = parent_arc(oid)
        w(f"{name:<20} OBJECT IDENTIFIER ::= {{ {parent} {arc} }}")
    w("")
    for group, title in GROUP_TITLES.items():
        w(f"-- {title}")
        w("")
        for obj in oidlib.objects(oids, source="pi", group=group):
            parent, arc = parent_arc(obj["oid"])
            access = "read-only" if group == "status" else "read-write"
            unit = obj.get("unit", "")
            scale = obj.get("scale", 1)
            note = f" (value x {round(1 / scale)})" if scale not in (1, 1.0) else ""
            avail = "" if obj.get("available", True) else " Not connected: no data."
            w(f"{mib_name(obj['name'])} OBJECT-TYPE")
            w("    SYNTAX      Integer32")
            if unit:
                w(f'    UNITS       "{unit}{note}"')
            w(f"    MAX-ACCESS  {access}")
            w("    STATUS      current")
            w(f'    DESCRIPTION "{obj["desc"].replace(chr(34), chr(39))}.{avail}"')
            w(f"    ::= {{ {parent} {arc} }}")
            w("")
    for name, info in oids["trap_objects"].items():
        parent, arc = parent_arc(info["oid"])
        w(f"{mib_name(name)} OBJECT-TYPE")
        w("    SYNTAX      DisplayString")
        w("    MAX-ACCESS  accessible-for-notify")
        w("    STATUS      current")
        w(f'    DESCRIPTION "{info["desc"]}"')
        w(f"    ::= {{ {parent} {arc} }}")
        w("")
    objs = ", ".join(mib_name(n) for n in ("alarm_level", "alarm_code", "alarm_message"))
    for name, info in oids["notifications"].items():
        parent, arc = parent_arc(info["oid"])
        w(f"{name} NOTIFICATION-TYPE")
        w(f"    OBJECTS     {{ {objs} }}")
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
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    text = generate(oidlib.load())
    if args.check:
        if not os.path.exists(MIB_PATH):
            sys.exit("SMARTFARM-EXT-MIB.mib가 없습니다. python rmu/gen_mib.py 로 만드세요")
        same = without_dates(open(MIB_PATH, encoding="utf-8").read()) == without_dates(text)
        print("일치합니다" if same else "다릅니다. python rmu/gen_mib.py 로 다시 만드세요")
        sys.exit(0 if same else 1)
    with open(MIB_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"생성: {os.path.abspath(MIB_PATH)}")


if __name__ == "__main__":
    main()
