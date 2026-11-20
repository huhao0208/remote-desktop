#!/usr/bin/env bash
# VPS 一键部署
#   本地推送并部署： bash deploy.sh root@1.2.3.4
#   已在 VPS 上执行： bash deploy.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REMOTE_DIR=${REMOTE_DIR:-/opt/uu-remote}
TARGET=${1:-}

if [ -n "$TARGET" ]; then
  echo "[*] 打包并推送到 $TARGET:$REMOTE_DIR"
  ssh "$TARGET" "mkdir -p $REMOTE_DIR"
  tar -C "$HERE" -cf - server.py Dockerfile entrypoint.sh docker-compose.yml certs .env \
    | ssh "$TARGET" "tar -C $REMOTE_DIR -xf -"
  ssh "$TARGET" "cd $REMOTE_DIR && bash -s" < "$HERE/deploy.sh"
  exit 0
fi

cd "$HERE"
command -v docker >/dev/null 2>&1 || { echo "[*] 安装 docker"; curl -fsSL https://get.docker.com | sh; }
docker compose version >/dev/null 2>&1 || { echo "[!] 需要 docker compose 插件"; exit 1; }
[ -f .env ] || { echo "[!] 缺少 .env：cp .env.example .env 后填写 PUBLIC_HOST 与 TURN_SECRET"; exit 1; }
[ -f certs/fullchain.pem ] || { echo "[!] 缺少 certs/fullchain.pem 与 certs/privkey.pem"; exit 1; }

docker compose up -d --build
sleep 4
docker compose ps
PH=$(grep -E '^PUBLIC_HOST=' .env | cut -d= -f2)
echo
echo "[+] API/信令 : https://$PH:8443"
echo "[+] STUN/TURN: 3478/udp+tcp, relay 49160-49200/udp"
echo "[*] 云安全组需放行以上端口；管理页 https://$PH:8443/admin"