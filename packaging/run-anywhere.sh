#!/usr/bin/env bash
# 通用源码启动（任何 Python 3.10+ 环境：Linux / macOS / Windows-WSL /
# Android-Termux / iOS-a-Shell）。
#
# 用法：bash run-anywhere.sh
# 前置：pip install fastapi uvicorn
# 证书：./srv2/certs/fullchain.pem + privkey.pem（没有则明文启动，仅调试）
set -euo pipefail
cd "$(dirname "$0")/srv2"

PORT=${UU_PORT:-8443}
if [ -f certs/fullchain.pem ] && [ -f certs/privkey.pem ]; then
  exec python -m uvicorn server:app --host 0.0.0.0 --port "$PORT" \
    --ssl-certfile certs/fullchain.pem --ssl-keyfile certs/privkey.pem
else
  echo "[warn] 无证书，明文 HTTP 启动（官方客户端无法直连，仅供调试）" >&2
  exec python -m uvicorn server:app --host 0.0.0.0 --port "$PORT"
fi