#!/bin/sh
# OpenList 定时扫描 + 扫描完成后自动刷新飞牛影视 + 运行记录落盘（busybox 零依赖版）
#
# 流程：登录 OpenList → 触发 /admin/scan/start
#       → 轮询 /admin/scan/progress 直到 is_done=true
#       → 调用 media-refresh.sh 刷新飞牛影视媒体库
#       → 把本次运行写入 /data/scan-history.jsonl（供 Web UI 展示）
#
# 只依赖 busybox 自带工具（wget / sed / tr / md5sum），无需 curl / python3。
#
# 环境变量（由容器注入，不落盘）：
#   OPENLIST_URL          OpenList 地址（容器网络内用 http://172.17.0.1:5245）
#   OPENLIST_USERNAME     管理员用户名
#   OPENLIST_PASSWORD     管理员密码
#   SCAN_PATH             扫描路径，默认 /strm
#   SCAN_LIMIT            限速，默认 3
#   SCAN_WAIT_MAX         等待扫描完成的最长秒数，默认 1500
#   MEDIA_REFRESH_ENABLE  1=扫描完成后自动刷新影视（默认 1）
#   TRIGGER               触发来源，仅记录用：cron | manual | startup
#   DATA_DIR              状态与历史目录，默认 /data
#   LOG_LEVEL             debug 时打印详情，否则静默

: "${OPENLIST_URL:?OPENLIST_URL 未设置}"
: "${OPENLIST_USERNAME:?OPENLIST_USERNAME 未设置}"
: "${OPENLIST_PASSWORD:?OPENLIST_PASSWORD 未设置}"
: "${SCAN_PATH:=/strm}"
: "${SCAN_LIMIT:=3}"
: "${SCAN_WAIT_MAX:=1500}"
: "${MEDIA_REFRESH_ENABLE:=1}"
: "${TRIGGER:=cron}"
: "${DATA_DIR:=/data}"
: "${LOG_LEVEL:=info}"

HISTORY_FILE="${HISTORY_FILE:-$DATA_DIR/scan-history.jsonl}"
CURRENT_FILE="${CURRENT_FILE:-$DATA_DIR/current-run.json}"
MEDIA_STATE_FILE="${MEDIA_STATE_FILE:-$DATA_DIR/last-media.json}"
DIRECTORY_STATE_FILE="${DIRECTORY_STATE_FILE:-$DATA_DIR/directory-state.json}"
LOCK="${LOCK_FILE:-/tmp/rescan.lock}"
MEDIA_SCRIPT="/usr/local/bin/media-refresh.sh"

BASE="${OPENLIST_URL%/}"

log() {
  [ "$LOG_LEVEL" = "debug" ] && echo "[$(date '+%F %T')] $*"
}

# 单实例锁：上一轮（可能还在等扫描）没结束就跳过本轮，避免重叠
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "[$(date '+%F %T')] 上一轮任务仍在运行，跳过本轮"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

START_TS=$(date +%s)
START_H=$(date '+%F %T')
SCAN_CODE=null
OBJ_COUNT=0
MEDIA_CODE=null
MEDIA_TOTAL=0

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

mkdir -p "$DATA_DIR" 2>/dev/null
printf '{"status":"running","trigger":"%s","start":"%s","start_ts":%s,"path":"%s","limit":%s}\n' \
  "$TRIGGER" "$START_H" "$START_TS" "$SCAN_PATH" "$SCAN_LIMIT" > "$CURRENT_FILE" 2>/dev/null
# OpenList 当前接口只保证全局进度；目录级字段若由服务端返回则原样保存，供 UI 展示。
printf '{"updated":"%s","source":"openlist-progress","path":"%s","current":null,"directories":[]}' \
  "$START_H" "$SCAN_PATH" > "$DIRECTORY_STATE_FILE" 2>/dev/null

finish() {
  # $1 = ok | timeout | login_fail | media_fail
  _end_ts=$(date +%s)
  _end_h=$(date '+%F %T')
  is_num "$OBJ_COUNT" || OBJ_COUNT=0
  is_num "$MEDIA_TOTAL" || MEDIA_TOTAL=0
  printf '{"start_ts":%s,"end_ts":%s,"start":"%s","end":"%s","trigger":"%s","duration_s":%s,"status":"%s","obj_count":%s,"scan_code":%s,"media_code":%s,"media_total":%s}\n' \
    "$START_TS" "$_end_ts" "$START_H" "$_end_h" "$TRIGGER" "$(( _end_ts - START_TS ))" \
    "$1" "$OBJ_COUNT" "$SCAN_CODE" "$MEDIA_CODE" "$MEDIA_TOTAL" >> "$HISTORY_FILE" 2>/dev/null
  rm -f "$CURRENT_FILE" 2>/dev/null
}

# 1. 登录，取 token
LOGIN_BODY=$(mktemp)
printf '{"username":"%s","password":"%s"}' "$OPENLIST_USERNAME" "$OPENLIST_PASSWORD" > "$LOGIN_BODY"

LOGIN_JSON=$(wget -q -O - -T 20 "$BASE/api/auth/login" \
  --header='Content-Type: application/json' \
  --post-file="$LOGIN_BODY")
rm -f "$LOGIN_BODY"

TOKEN=$(printf '%s' "$LOGIN_JSON" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

if [ -z "$TOKEN" ]; then
  echo "[$(date '+%F %T')] 登录失败：$LOGIN_JSON"
  finish login_fail
  exit 1
fi

# 2. 触发扫描
SCAN_BODY=$(mktemp)
printf '{"path":"%s","limit":%s}' "$SCAN_PATH" "$SCAN_LIMIT" > "$SCAN_BODY"

RESULT=$(wget -q -O - -T 20 "$BASE/api/admin/scan/start" \
  --header="Authorization: $TOKEN" \
  --header='Content-Type: application/json' \
  --post-file="$SCAN_BODY")
rm -f "$SCAN_BODY"

CODE=$(printf '%s' "$RESULT" | sed -n 's/.*"code"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
is_num "$CODE" && SCAN_CODE=$CODE
log "扫描触发结果：code=${CODE:-?} resp=$RESULT"

# 3. 关闭自动刷新时到此结束
if [ "$MEDIA_REFRESH_ENABLE" != "1" ]; then
  log "影视自动刷新已关闭"
  finish ok
  exit 0
fi

# 4. 轮询扫描进度，等 is_done=true（先等 20s，避开上一轮 is_done 仍为 true 的竞态）
sleep 20
elapsed=20
done_flag=0
while [ "$elapsed" -le "$SCAN_WAIT_MAX" ]; do
  PROG=$(wget -q -O - -T 20 "$BASE/api/admin/scan/progress" --header="Authorization: $TOKEN")
  NORM=$(printf '%s' "$PROG" | tr -d ' \n\r')
  OC=$(printf '%s' "$NORM" | sed -n 's/.*"obj_count":\([0-9]*\).*/\1/p')
  is_num "$OC" && OBJ_COUNT=$OC
  # 不猜测目录状态：仅提取 OpenList 明确返回的 current/path 字段。
  CUR_DIR=$(printf '%s' "$NORM" | sed -n 's/.*"\(current_path\|current\|path\)":"\([^"]*\)".*/\2/p' | head -n1)
  if [ -n "$CUR_DIR" ]; then
    printf '{"updated":"%s","source":"openlist-progress","path":"%s","current":"%s","directories":[]}' \
      "$(date '+%F %T')" "$SCAN_PATH" "$CUR_DIR" > "$DIRECTORY_STATE_FILE" 2>/dev/null
  fi
  case "$NORM" in
    *'"is_done":true'*) done_flag=1; log "扫描完成（约 ${elapsed}s）：$PROG"; break ;;
  esac
  [ $(( elapsed % 60 )) -eq 0 ] && log "扫描中（${elapsed}s）：$PROG"
  sleep 10
  elapsed=$(( elapsed + 10 ))
done

if [ "$done_flag" != "1" ]; then
  echo "[$(date '+%F %T')] 等待扫描完成超时（${SCAN_WAIT_MAX}s），本轮不刷新影视（已扫描 $OBJ_COUNT 项）"
  finish timeout
  exit 0
fi

# 扫描完成时保留最后一次可观测目录；OpenList 未返回目录列表时由 UI 明确提示。
if [ -f "$DIRECTORY_STATE_FILE" ]; then
  sed 's/"current":"[^"]*"/"current":null/' "$DIRECTORY_STATE_FILE" > "$DIRECTORY_STATE_FILE.tmp" 2>/dev/null && mv "$DIRECTORY_STATE_FILE.tmp" "$DIRECTORY_STATE_FILE"
fi

# 5. 刷新飞牛影视媒体库
if [ -f "$MEDIA_SCRIPT" ]; then
  MEDIA_STATE_FILE="$MEDIA_STATE_FILE" LOG_LEVEL="$LOG_LEVEL" \
    sh "$MEDIA_SCRIPT" || echo "[$(date '+%F %T')] 影视刷新脚本执行失败"

  if [ -f "$MEDIA_STATE_FILE" ]; then
    MC=$(sed -n 's/.*"code"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$MEDIA_STATE_FILE" | head -n1)
    MT=$(sed -n 's/.*"total"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$MEDIA_STATE_FILE" | head -n1)
    is_num "$MC" && MEDIA_CODE=$MC
    is_num "$MT" && MEDIA_TOTAL=$MT
  fi
else
  echo "[$(date '+%F %T')] 未找到 $MEDIA_SCRIPT，跳过影视刷新"
fi

if [ "$MEDIA_CODE" = "null" ]; then
  finish media_fail
else
  finish ok
fi
exit 0
