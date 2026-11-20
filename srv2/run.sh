#!/usr/bin/env bash
# 本地（NAS）起服务端 + 改写代理，用于局域网真机联调
#   bash run.sh start|stop|status
set -uo pipefail
cd "$(dirname "$0")"

PY=/vol5/@appcenter/trim.hermes/runtime/python/bin/python3.11.real
MITM=../proxy/venv/bin/mitmdump
LOG=/tmp/uu
mkdir -p "$LOG"

start() {
  pkill -f "uvicorn server:app" 2>/dev/null
  pkill -f "mitmdump -p 8080" 2>/dev/null
  sleep 1

  UU_PUBLIC_BASE=https://api.nrd.nie.163.com \
  UU_WS_BASE=wss://api.nrd.nie.163.com \
  UU_STUN_URLS="stun:api.nrd.nie.163.com:3478" \
  UU_TURN_URLS="turn:api.nrd.nie.163.com:3478?transport=udp" \
  UU_TURN_SECRET="${UU_TURN_SECRET:-devsecret}" \
  UU_DATA_DIR="$PWD/data" \
  setsid "$PY" -m uvicorn server:app --host 0.0.0.0 --port 8443 \
    --ssl-keyfile certs/privkey.pem --ssl-certfile certs/fullchain.pem \
    --log-level warning > "$LOG/server.log" 2>&1 < /dev/null &

  sleep 2
  ( cd ../proxy && setsid ./venv/bin/mitmdump -p 8080 \
      --set confdir=confdir --set ssl_insecure=true \
      -s addon_uuyc.py --flow-detail 1 > "$LOG/proxy.log" 2>&1 < /dev/null & )
  sleep 2
  status
}

stop() {
  pkill -f "uvicorn server:app" 2>/dev/null
  pkill -f "mitmdump -p 8080" 2>/dev/null
  echo "stopped"
}

status() {
  ss -ltn 2>/dev/null | grep -E ":8443|:8080" || echo "未监听"
  echo "--- server: $LOG/server.log   proxy: $LOG/proxy.log"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) echo "用法: $0 [start|stop|status]"; exit 1 ;;
esac