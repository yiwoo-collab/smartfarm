"""
RMU 실물 점검: SNMP로 교수님 MIB 항목을 읽어 원시값과 변환값을 보여준다.

  python rmu_check.py --host 192.168.0.50                 모든 항목 읽기
  python rmu_check.py --host 192.168.0.50 --trap          addTrap 등록 후 30초 동안 Trap 기다리기
  python rmu_check.py --host 127.0.0.1 --port 1161        PC의 모의 RMU (mock_pelkorea_rmu.py)

값이 이상하면 oids.json의 scale/offset을 고친다 (코드는 고치지 않는다).
"""

import argparse
import time

import oids as oidlib
from rmu_client import TrapReceiver, local_ip_for, register_trap
from rmu_model import RmuModel
from snmp_lite import SnmpClient, SnmpError


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=161)
    p.add_argument("--community", default="public")
    p.add_argument("--write-community", default="private")
    p.add_argument("--trap", action="store_true", help="addTrap 등록 후 Trap 기다리기")
    p.add_argument("--trap-port", type=int, default=1162)
    args = p.parse_args()

    oids = oidlib.load()
    client = SnmpClient(args.host, args.port, args.community)
    print(f"== RMU {args.host}:{args.port} (커뮤니티 {args.community})")
    for obj in oidlib.objects(oids, source="rmu"):
        if obj.get("type") == "table":
            continue
        oid = obj["oid"].strip(".") + ".0"
        try:
            raw = client.get([oid])[oid]
        except SnmpError as e:
            print(f"  {obj['mib']:<12} {oid:<34} 실패: {e}")
            continue
        value = oidlib.to_value(raw, obj)
        print(f"  {obj['mib']:<12} {oid:<34} 원시값 {raw!s:<8} → {obj['name']} = {value} {obj.get('unit', '')}")

    if args.trap:
        model = RmuModel(mode="live")
        receiver = TrapReceiver(model, args.trap_port, on_trap=lambda code: print(f"  Trap 수신: 알람 코드 {code}"))
        receiver.start()
        my_ip = local_ip_for(args.host)
        error = register_trap(args.host, args.port, args.write_community, my_ip, receiver.port)
        print(f"== addTrap 등록 {my_ip}:{receiver.port}: {'성공' if error is None else '실패 ' + error}")
        print("30초 동안 RMU 알람(예: 도어 열기)을 기다립니다...")
        time.sleep(30)
        print(f"받은 Trap: {receiver.received}개, 현재 RMU 알람: {sorted(model.rmu_alarms)}")


if __name__ == "__main__":
    main()
