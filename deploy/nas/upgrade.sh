#!/usr/bin/env bash
# 服务端升级：对比 GitHub 最新 tag 与本地部署版本，拉源码 → 重建镜像 → 重启。
#
# 为什么不是 `docker compose pull`：deploy/nas/docker-compose.yml 用的是
# `build: ../../srv2`（本项目不发布预构建镜像），所以「升级」= 换源码 + 重新 build。
# 如果你把镜像推到自己的 registry 了，把 APPLY 里的 build 换成 pull 即可。
#
# 用法：
#   ./upgrade.sh              # 只检查，不改动（默认行为，安全）
#   ./upgrade.sh --check      # 同上
#   ./upgrade.sh --yes        # 真的升级（会 git checkout 到最新 tag + 重建 + 重启）
#   ./upgrade.sh --rollback   # 回滚到上一次升级前的 tag
#
# 依赖：git、docker compose、curl；JSON 解析优先用 python3，没有就退回 grep。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REPO_SLUG="${UU_RELEASE_REPO:-huhao0208/remote-desktop}"
COMPOSE="docker compose -f $HERE/docker-compose.yml"
STATE="$HERE/.last-upgrade-tag"
HEALTH_URL="${UU_HEALTH_URL:-}"

CHECK_ONLY=1
ACTION="upgrade"

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --yes) CHECK_ONLY=0 ;;
    --rollback) ACTION="rollback"; CHECK_ONLY=0 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$arg（--help 看用法）" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 当前版本
current_version() {
  # 1) 优先问正在跑的服务端（最准；裸机/容器都适用）
  local host="${UU_HEALTH_URL:-http://127.0.0.1:${API_PORT:-8444}}"
  if [ -n "$HEALTH_URL" ]; then host="$HEALTH_URL"; fi
  if command -v curl >/dev/null 2>&1; then
    local body
    body="$(curl -fsS -m 5 "$host/healthz" 2>/dev/null || true)"
    if [ -n "$body" ]; then
      local v
      v="$(printf '%s' "$body" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)"
      if [ -z "$v" ]; then
        v="$(printf '%s' "$body" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      fi
      if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    fi
  fi
  # 2) 退回源码目录的 VERSION 文件
  if [ -f "$ROOT/VERSION" ]; then tr -d '[:space:]' < "$ROOT/VERSION"; return 0; fi
  printf 'unknown'
}

# ---------------------------------------------------------------- 最新版本
latest_version() {
  local json
  json="$(curl -fsS -m 15 "https://api.github.com/repos/$REPO_SLUG/releases/latest" \
    -H 'Accept: application/vnd.github+json' -H "User-Agent: uu-upgrade-script")" \
    || die "查 GitHub 失败（网络不通或被限流）"
  local tag
  tag="$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
  if [ -z "$tag" ]; then
    tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi
  [ -n "$tag" ] || die "GitHub 返回里没有 tag_name"
  printf '%s' "${tag#v}"
}

ver_gt() {  # ver_gt a b → a 比 b 新时为 0
  [ "$1" != "$2" ] || return 1
  local IFS=.
  local a1 a2 a3 b1 b2 b3
  set -- $1; a1=${1:-0}; a2=${2:-0}; a3=${3:-0}
  set -- $2; b1=${1:-0}; b2=${2:-0}; b3=${3:-0}
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
  [ "$a3" -gt "$b3" ]
}

# ---------------------------------------------------------------- 回滚
if [ "$ACTION" = "rollback" ]; then
  [ -f "$STATE" ] || die "没有找到 $STATE（还没用本脚本升级过）"
  target="$(cat "$STATE")"
  say "回滚到 v$target"
  git -C "$ROOT" fetch --tags --quiet || true
  git -C "$ROOT" checkout --quiet "$target" 2>/dev/null || git -C "$ROOT" checkout --quiet "v$target"
  ( cd "$HERE" && $COMPOSE up -d --build )
  rm -f "$STATE"
  say "已回滚。健康检查：$(current_version)"
  exit 0
fi

# ---------------------------------------------------------------- 主流程
cur="$(current_version)"
say "本地版本：v$cur"
lat="$(latest_version)"
say "最新版本：v$lat"

if ! ver_gt "$lat" "$cur"; then
  say "已是最新，无需升级。"
  exit 0
fi

say "有新版本：v$cur → v$lat"
say "更新说明：https://github.com/$REPO_SLUG/releases/tag/v$lat"

if [ "$CHECK_ONLY" = "1" ]; then
  say ""
  say "（当前是只检查模式）真正执行升级：./upgrade.sh --yes"
  exit 0
fi

# 工作区必须干净：升级会 checkout 到 tag，本地改动会被覆盖
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  die "$ROOT 有未提交改动，先处理干净再升级（避免覆盖你的修改）"
fi

printf '%s' "$cur" > "$STATE"
say "已记录回滚点：v$cur（./upgrade.sh --rollback 可回退）"

git -C "$ROOT" fetch --tags --quiet
if git -C "$ROOT" rev-parse --verify --quiet "refs/tags/v$lat" >/dev/null; then
  git -C "$ROOT" checkout --quiet "v$lat"
else
  die "远端没有 tag v$lat"
fi

say "重建镜像并重启（NAS 上通常 1-3 分钟）…"
( cd "$HERE" && $COMPOSE up -d --build )

say ""
say "等待服务起来…"
for i in $(seq 1 30); do
  sleep 2
  now="$(current_version)"
  if [ "$now" = "$lat" ]; then
    say "升级完成：v$now"
    exit 0
  fi
done
die "升级后健康检查仍是 v$(current_version)，请查看容器日志：$COMPOSE logs -f uu-api"
