"""
라즈베리파이 배선 점검 (1단계 실물 확인용).

  python check_hardware.py            센서 값 5번 읽고, 릴레이를 하나씩 2초간 켰다 끈다
  python check_hardware.py --no-relay 센서만 읽는다

서버(server.py)를 끈 상태에서 실행한다 (릴레이 핀을 같이 쓰면 충돌).
"""

import argparse
import time

from hardware import REAL_SENSORS, Hardware

UNITS = {"temperature": "℃", "humidity": "%", "soil_moisture": "%",
         "supply_voltage": "V", "supply_current": "A", "rmu_temp": "℃"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-relay", action="store_true")
    args = parser.parse_args()

    hw = Hardware()
    print(hw.summary())
    print()

    print("== 센서 읽기 (1초 간격 5번)")
    for i in range(5):
        values = hw.read()
        line = []
        for name in REAL_SENSORS:
            if name not in values:
                line.append(f"{name}=없음")
            elif values[name] is None:
                line.append(f"{name}=읽기 실패")
            else:
                line.append(f"{name}={values[name]:.2f}{UNITS[name]}")
        print(f"{i + 1}: " + ", ".join(line))
        time.sleep(1)

    if "soil_moisture" in values and values["soil_moisture"] is not None:
        print("\n토양수분 보정: 센서를 공기 중에 두면 0% 근처, 물에 담그면 100% 근처여야 합니다.")
        print("다르면 hardware_config.json의 soil_dry_raw / soil_wet_raw를 고치세요.")

    if args.no_relay:
        hw.close()
        return

    print("\n== 릴레이 점검 (하나씩 2초간 켬)")
    control = {"main_fan": 0, "backup_fan": 0, "cooling_fan": 0, "pump": 0}
    for device in control:
        input(f"{device} 를 켭니다. Enter...")
        hw.apply({**control, device: 1})
        time.sleep(2)
        before = hw.read().get("supply_current")
        hw.apply(control)
        print(f"  {device} 껐음" + (f" (켜져 있을 때 공급 전류 {before:.2f}A)" if before is not None else ""))
    print("\n팬 회전 신호:", hw.fan_failures({"main_fan": 1, "backup_fan": 1}) or "설정 안 함")
    hw.close()
    print("점검 끝")


if __name__ == "__main__":
    main()
