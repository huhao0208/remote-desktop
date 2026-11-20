#!/usr/bin/env bash
# NAS 部署引导：探测公网 IP / 内网网卡 / 生成密钥 / 写 .env
# 只做幂等的探测与写文件，不改系统配置、不动防火墙。
set -euo pipefail

cd "$(dirname "$0")"
ENV_FILE=".env"

say() { printf '\033[1;36m[nas]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. 公网 IP ----------
say "探测公网 IPv4…"
PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me || curl -4 -fsS --max-time 8 https://api.ipify.org || true)"
[[ -n "$PUBLIC_IP" ]] || die "拿不到公网 IP（检查 NAS 是否能出网）"
say "公网 IP = $PUBLIC_IP"

case "$PUBLIC_IP" in
  10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9]*|100.1[0-2]*)
    die "这不是公网 IP（$PUBLIC_IP 属于内网/CGNAT）。家宽若是 CGNAT，需要找运营商开通公网 IPv4，或改用 IPv6 方案。" ;;
esac

# ---------- 2. 内网网卡 IP（coturn 必须绑它，不能绑 docker0） ----------
detect_lan_ip() {
  # 默认路由对应的源地址，最可靠
  if command -v ip >/dev/null 2>&1; then
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
  elif command -v route >/dev/null 2>&1; then
    route -n get default 2>/dev/null | awk '/interface:/{print $2}' | while read -r ifc; do
      ipconfig getifaddr "$ifc" 2>/dev/null
    done | head -1
  fi
}
LAN_IP="$(detect_lan_ip || true)"
[[ -n "$LAN_IP" ]] || die "探测不到内网 IP，请手动指定 TURN_PRIVATE_IP"
say "内网 IP = $LAN_IP"

# ---------- 3. 域名 ----------
# 无自有域名时用 sslip.io：a-b-c-d.sslip.io 会解析到 a.b.c.d，可直接签证书
SSLIP="$(echo "$PUBLIC_IP" | tr '.' '-').sslip.io"
if [[ -f "$ENV_FILE" ]] && grep -q '^PUBLIC_HOST=' "$ENV_FILE"; then
  EXISTING="$(grep '^PUBLIC_HOST=' "$ENV_FILE" | cut -d= -f2-)"
  if [[ -n "$EXISTING" ]]; then
    say "沿用已有 PUBLIC_HOST = $EXISTING"
    PUBLIC_HOST="$EXISTING"
  fi
fi
PUBLIC_HOST="${PUBLIC_HOST:-$SSLIP}"
if [[ "$PUBLIC_HOST" == "$SSLIP" ]]; then
  warn "未指定自有域名，暂用 sslip.io：$PUBLIC_HOST"
  warn "注意：家宽公网 IP 是动态的（实测 10 分钟内就变过），长期请改用自有域名 + DDNS + DNS-01，见 README §4 方案 B"
fi

# ---------- 4. 密钥 ----------
gen_secret() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
  else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}
if [[ -f "$ENV_FILE" ]] && grep -q '^TURN_SECRET=' "$ENV_FILE"; then
  TURN_SECRET="$(grep '^TURN_SECRET=' "$ENV_FILE" | cut -d= -f2-)"
  say "沿用已有 TURN_SECRET（不重新生成，避免已连客户端掉线）"
else
  TURN_SECRET="$(gen_secret)"
  say "已生成新的 TURN_SECRET"
fi

API_PORT="$( [[ -f "$ENV_FILE" ]] && grep '^API_PORT=' "$ENV_FILE" | cut -d= -f2- || echo 8444 )"

# ---------- 5. 写 .env ----------
umask 077
cat > "$ENV_FILE" <<EOF
# 由 bootstrap.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
PUBLIC_HOST=$PUBLIC_HOST
TURN_SECRET=$TURN_SECRET
TURN_PRIVATE_IP=$LAN_IP
API_PORT=${API_PORT:-8444}
EOF
chmod 600 "$ENV_FILE"
say "已写入 $ENV_FILE"

# ---------- 6. 目录与证书检查 ----------
mkdir -p ../../srv2/certs
if [[ ! -f ../../srv2/certs/fullchain.pem ]]; then
  warn "还没有证书 → 服务会以明文 HTTP 起（手机/客户端连不上）。"
  warn "按 README §4 申请证书后放到 srv2/certs/{fullchain.pem,privkey.pem}，再 docker compose restart"
fi

cat <<EOF

下一步：
  1) docker compose up -d --build
  2) bash preflight.sh $PUBLIC_HOST ${API_PORT:-8444}
  3) 路由器放行并映射：${API_PORT:-8444}/tcp、3478/udp+tcp、49160-49200/udp
  4) 手机 4G 打开 https://$PUBLIC_HOST:${API_PORT:-8444}/control 验证

控制端内置地址要指向这台 NAS 时，打包时设置：
  RD_SERVER=https://$PUBLIC_HOST:${API_PORT:-8444}
EOF