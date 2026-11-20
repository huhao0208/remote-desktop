#!/data/data/com.termux/files/usr/bin/bash
# Android Termux 一键起服务端（iOS 可用 a-Shell：pip install fastapi uvicorn 后
# 直接 python server.py，本脚本的 pkg 部分换成 a-Shell 对应命令即可）。
#
# 用法：bash run.sh [start|stop|status]
# 前置：Termux 里执行过  pkg install python  &&  pip install fastapi uvicorn
set -uo pipefail
cd "$(dirname "$0")"

PORT=${UU_PORT:-8443}
LOG=${TMPDIR:-/tmp}/uu-server.log

start() {
  mkdir -p data certs
  if [ ! -f certs/fullchain.pem ] || [ ! -f certs/privkey.pem ]; then
    echo "[!] 缺证书：把 fullchain.pem / privkey.pem 放到 ./certs/"
    echo "    无证书时以明文启动（仅供本机调试，官方客户端无法直连）"
    nohup python server.py > "$LOG" 2>&1 &
  else
    nohup python -m uvicorn server:app --host 0.0.0.0 --port "$PORT" \
      --ssl-certfile certs/fullchain.pem --ssl-keyfile certs/privkey.pem \
      --log-level warning > "$LOG" 2>&1 &
  fi
  sleep 2
  status
}

stop() {
  pkill -f "uvicorn server:app" 2>/dev/null
  pkill -f "python server.py" 2>/dev/null
  echo stopped
}

status() {
  if curl -sk "https://127.0.0.1:$PORT/healthz" 2>/dev/null || \
     curl -s "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
    echo " <- running (log: $LOG)"
  else
    echo "not running (log: $LOG)"
  fi
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) echo "用法: $0 [start|stop|status]"; exit 1 ;;
esac