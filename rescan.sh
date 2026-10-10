#!/bin/sh
# OpenList 定时扫描触发器
# 每次运行：登录 OpenList → 取 token → 触发 /admin/scan/start
# 环境变量（由 compose 注入，不落盘）：
#   OPENLIST_URL       OpenList 地址（内网或反代域名均可）
#   OPENLIST_USERNAME  管理员用户名
#   OPENLIST_PASSWORD  管理员密码
#   SCAN_PATH          扫描路径，默认 /strm
#   SCAN_LIMIT         限速，默认 3
#   LOG_LEVEL          debug 时打印详情，否则静默

: "${OPENLIST_URL:?OPENLIST_URL 未设置}"
: "${OPENLIST_USERNAME:?OPENLIST_USERNAME 未设置}"
: "${OPENLIST_PASSWORD:?OPENLIST_PASSWORD 未设置}"
: "${SCAN_PATH:=/strm}"
: "${SCAN_LIMIT:=3}"
: "${LOG_LEVEL:=info}"

BASE="${OPENLIST_URL%/}"

log() {
  [ "$LOG_LEVEL" = "debug" ] && echo "[$(date '+%F %T')] $*"
}

# 1. 登录
LOGIN_JSON=$(curl -s -m 20 -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$OPENLIST_USERNAME\",\"password\":\"$OPENLIST_PASSWORD\"}")

TOKEN=$(printf '%s' "$LOGIN_JSON" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['data']['token'])" 2>/dev/null)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "None" ]; then
  log "登录失败：$LOGIN_JSON"
  exit 1
fi

# 2. 触发扫描
RESULT=$(curl -s -m 20 -X POST "$BASE/api/admin/scan/start" \
  -H "Authorization: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"path\":\"$SCAN_PATH\",\"limit\":$SCAN_LIMIT}")

CODE=$(printf '%s' "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('code','?'))" 2>/dev/null)

case "$CODE" in
  200) log "扫描已触发（path=$SCAN_PATH, limit=$SCAN_LIMIT）" ;;
  *)
    # 400 = 正在扫描中（幂等，不算失败），其余打印
    log "扫描触发结果：code=$CODE resp=$RESULT"
    ;;
esac

exit 0
