#!/bin/sh
# 容器入口：有证书就用 TLS 起 uvicorn（客户端要求 HTTPS/WSS），否则明文。
set -e
CERT=${UU_TLS_CERT:-/certs/fullchain.pem}
KEY=${UU_TLS_KEY:-/certs/privkey.pem}

if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  exec python -m uvicorn app:app --host 0.0.0.0 --port 8443 \
    --ssl-certfile "$CERT" --ssl-keyfile "$KEY" \
    --proxy-headers --forwarded-allow-ips '*' --log-level warning
else
  echo "[warn] 未找到证书 ($CERT)，以明文 HTTP 启动（官方客户端无法直连）" >&2
  exec python -m uvicorn app:app --host 0.0.0.0 --port 8443 \
    --proxy-headers --forwarded-allow-ips '*' --log-level warning
fi