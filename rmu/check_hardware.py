"""
라즈베리파이 배선 점검 (1단계 실물 확인용).

  python check_hardware.py            센서 값 5번 읽고, 릴레이를 하나씩 2초간 켰다 끈다
  python check_hardware.py --no-relay 센서만 읽는다

서버(server.py)를 끈 상태에서 실행한다 (릴레이 핀을 같이 쓰면 충돌).
"""

import argparse
import time

from hardware import PI_SENSORS, Hardware

UNITS = {"humidity": "%", "hum_temp": "℃", "fire": "", "water_level": "%", "pi_temp": "℃"}


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
        for name in PI_SENSORS:
            if name not in values:
                line.append(f"{name}=없음")
            elif values[name] is None:
                line.append(f"{name}=읽기 실패")
            else:
                line.append(f"{name}={values[name]:.2f}{UNITS[name]}")
        print(f"{i + 1}: " + ", ".join(line))
        time.sleep(1)

    print("\n화재감지기: 평소 0, 시험 버튼(또는 연기)으로 1이 되는지 확인하세요.")
    print("수위감지기: 물이 있을 때와 없을 때 값이 바뀌는지 확인하세요 (hardware_config.json의 mode·active_low).")
    print("온도(temp1)·전원(acv1)은 RMU 실물에서 읽습니다: python rmu_check.py --host <RMU IP>")

    if args.no_relay:
        hw.close()
        return

    print("\n== 릴레이 점검 (하나씩 2초간 켬)")
    control = {"main_fan": 0, "backup_fan": 0, "cooling_fan": 0, "pump": 0}
    for device in control:
        input(f"{device} 를 켭니다. Enter...")
        hw.apply({**control, device: 1})
        time.sleep(2)
        hw.apply(control)
        print(f"  {device} 껐음")
    print("\n팬 회전 신호:", hw.fan_failures({"main_fan": 1, "backup_fan": 1}) or "설정 안 함")
    hw.close()
    print("점검 끝")


if __name__ == "__main__":
    main()
