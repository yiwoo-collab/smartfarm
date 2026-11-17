#!/bin/bash
# 라즈베리파이 코드를 GitHub 최신(main)으로 업데이트하고 서버를 다시 시작한다.
#
# 노트북에서 한 줄로 실행 (라즈베리파이 비밀번호·sudo 비밀번호를 물어보면 입력):
#   ssh -t smartfarmpi@192.168.0.10 "curl -fsSL https://raw.githubusercontent.com/yiwoo-collab/smartfarm/main/rmu/update_pi.sh -o /tmp/update_pi.sh && bash /tmp/update_pi.sh"
#
# - 서버에 필요한 oids.json, MIB, rmu/ 만 덮어쓴다 (APK·웹 앱은 라즈베리파이에 필요 없음).
# - rmu/data(기록 DB), rmu/admin.json(관리자 계정)은 GitHub에 없으므로 그대로 남는다.
# - 덮어쓰기 전에 지금 코드를 ~/smartfarm_backup_날짜.tar.gz 로 백업한다 (기록 DB 제외).
# - 자동 실행 서비스가 없으면 설치하고(처음 한 번), 있으면 다시 시작한다.
set -e

REPO="yiwoo-collab/smartfarm"
DIR="$HOME/smartfarm"
SERVICE="smartfarm-rmu"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "[1/5] GitHub에서 최신 코드 받기"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$TMP"
SRC="$TMP/smartfarm-main"
COMMIT=$(curl -fsL "https://api.github.com/repos/$REPO/commits/main" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4 | cut -c1-7 || true)
echo "      커밋 ${COMMIT:-알 수 없음}"

echo "[2/5] 지금 코드 백업"
if [ -d "$DIR" ]; then
    BACKUP="$HOME/smartfarm_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -C "$DIR" --exclude=./rmu/data -czf "$BACKUP" .
    echo "      $BACKUP"
else
    echo "      (처음 설치라 백업할 것 없음)"
fi

echo "[3/5] 코드 덮어쓰기"
mkdir -p "$DIR/rmu"
cp -a "$SRC/rmu/." "$DIR/rmu/"
cp -a "$SRC/oids.json" "$SRC"/*.mib "$SRC/CLAUDE.md" "$DIR/"
echo "${COMMIT:-unknown} $(date '+%Y-%m-%d %H:%M')" > "$DIR/VERSION"

echo "[4/5] 서버 다시 시작 (sudo 비밀번호를 물으면 입력)"
if [ -f "/etc/systemd/system/$SERVICE.service" ]; then
    sudo cp "$DIR/rmu/$SERVICE.service" /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl restart "$SERVICE"
else
    # 처음 한 번: nohup으로 손으로 켜 둔 서버를 끄고 자동 실행 서비스를 설치한다.
    # ([s] 는 pkill이 이 스크립트나 ssh 명령 자체를 끄지 않게 하는 요령)
    pkill -f "[s]erver.py" || true
    sudo cp "$DIR/rmu/$SERVICE.service" /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE"
fi

echo "[5/5] 확인"
sleep 5
systemctl is-active "$SERVICE" && echo "      서비스 동작 중" || { echo "      서비스가 안 켜짐 → journalctl -u $SERVICE -n 30"; exit 1; }
if curl -fsS -m 5 http://127.0.0.1:8080/api/status > /dev/null; then
    echo "      REST API 응답 OK (http://$(hostname -I | cut -d' ' -f1):8080/api/status)"
else
    echo "      REST API 응답 없음 → journalctl -u $SERVICE -n 30"
    exit 1
fi
echo "업데이트 완료: $(cat "$DIR/VERSION")"
