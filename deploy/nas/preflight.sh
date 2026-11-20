#!/usr/bin/env bash
# 部署后自检：DNS / 端口 / healthz / TURN allocate
# 用法：bash preflight.sh [host] [port]
set -uo pipefail

HOST="${1:-}"
PORT="${2:-8444}"
[[ -n "$HOST" ]] || { echo "用法: bash preflight.sh <host> [port]"; exit 2; }

ok() { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
no() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=1; }
FAIL=0

echo "== 1. DNS 解析 =="
IPS="$( (getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1}'
          dscacheutil -q host -a name "$HOST" 2>/dev/null | awk '/^ip_address:/{print $2}'
          nslookup "$HOST" 2>/dev/null | awk '/^Address: /{print $2}') | grep -E '^[0-9]+\.' | sort -u )"
if [[ -n "$IPS" ]]; then ok "$HOST → $(echo "$IPS" | tr '\n' ' ')"; else no "$HOST 解析失败"; fi

echo "== 2. 控制面可达（HTTP 状态码） =="
CODE="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$HOST:$PORT/healthz" || echo 000)"
[[ "$CODE" == "200" ]] && ok "https://$HOST:$PORT/healthz → 200" || no "https://$HOST:$PORT/healthz → $CODE（检查端口映射/证书/容器）"

echo "== 3. 控制页 =="
# 注意：不要写成 `curl | grep -q`。pipefail + grep 提前退出会让 curl 收到 SIGPIPE，
# 管道整体判失败，表现为偶发误报。先落变量再判断。
PAGE="$(curl -k -s --max-time 8 "https://$HOST:$PORT/control" || true)"
case "$PAGE" in
  *'id="btnLogin"'*) ok "/control 可访问" ;;
  *) no "/control 取不到页面（长度 ${#PAGE}）" ;;
esac

echo "== 4. TURN 凭据与 allocate =="
BASE="https://$HOST:$PORT"
TOK="$(curl -k -s --max-time 8 -X POST "$BASE/api/v1/login/by_mobile" \
  -H 'Content-Type: application/json' -d '{"mobile":"18800000000"}' \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
if [[ -z "$TOK" ]]; then
  no "登录接口取不到 token"; FAIL=1
else
  ok "登录接口正常"
  JSON="$(curl -k -s --max-time 8 -X POST "$BASE/api/v1/device/pc/init" \
    -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
    -d '{"device_name":"preflight","uuid":"preflight-probe"}')"
  DEV="$(echo "$JSON" | sed -n 's/.*"device_id":"\([^"]*\)".*/\1/p')"
  if [[ -n "$DEV" ]]; then
    ICE="$(curl -k -s --max-time 8 -X POST "$BASE/api/v1/room/join/by_device/$DEV" \
      -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{}')"
    if echo "$ICE" | grep -q 'turn:'; then
      ok "服务端已下发 TURN 凭据"
    else
      no "room 配置里没有 turn（检查 UU_TURN_URLS / TURN_SECRET）"
    fi
    if echo "$ICE" | grep -q 'stun:'; then ok "服务端已下发 STUN"; else no "缺 STUN"; fi
  else
    no "设备注册失败：$JSON"
  fi
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[1;32m全部通过\033[0m：手机 4G 打开 https://%s:%s/control 应能看到设备列表\n' "$HOST" "$PORT"
else
  printf '\033[1;31m有失败项\033[0m：按 README §1/§7 逐项排查\n'
fi
exit "$FAIL"