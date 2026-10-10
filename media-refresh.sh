#!/bin/sh
# 飞牛影视（trim.media）媒体库刷新触发器 —— busybox 零依赖版
# 依赖 busybox 自带：wget / md5sum / sha256sum / sed / tr / mktemp / date
#
# 流程：POST /v/api/v2/user/loginByPassword（密码 sha256）拿 token
#       → 带 Cookie Trim-MC-token + authx 签名 → POST /v/api/v1/mdb/scanall
#
# 环境变量：
#   MEDIA_URL       影视内部地址（容器网络内用 http://172.17.0.1:8005）
#   MEDIA_USERNAME  影视账号
#   MEDIA_PASSWORD  影视密码（明文传入，脚本内 sha256 后提交）
#   MEDIA_MODE      scanall（默认，刷新全部库）| refresh
#   LOG_LEVEL       debug 时打印详情
set -u

: "${MEDIA_URL:?MEDIA_URL 未设置}"
: "${MEDIA_USERNAME:?MEDIA_USERNAME 未设置}"
: "${MEDIA_PASSWORD:?MEDIA_PASSWORD 未设置}"
: "${MEDIA_MODE:=scanall}"
: "${MEDIA_STATE_FILE:=}"
: "${LOG_LEVEL:=info}"

# 飞牛影视 Web 客户端内置的应用级常量（authx 签名用）。
# 它们不是用户凭据，但同样不写进版本库：从挂载目录读取。
# keys.local 内容形如：
#   MEDIA_APP_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#   MEDIA_APP_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
: "${DATA_DIR:=/data}"
[ -f "$DATA_DIR/keys.local" ] && . "$DATA_DIR/keys.local"
: "${MEDIA_APP_SECRET:?MEDIA_APP_SECRET 未设置（请在 $DATA_DIR/keys.local 中提供，见 README）}"
: "${MEDIA_APP_KEY:?MEDIA_APP_KEY 未设置（请在 $DATA_DIR/keys.local 中提供，见 README）}"

BASE="${MEDIA_URL%/}"

log() { [ "$LOG_LEVEL" = "debug" ] && echo "[media $(date '+%F %T')] $*"; }
md5() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }

# authx = nonce=..&timestamp=..&sign=md5(SECRET_path_nonce_ts_bodyHash_apiKey)
mkauth() {
	# $1=path  $2=bodyHash
	_nonce=$(( (RANDOM * 32768 + RANDOM) % 900000 + 100000 ))
	_ts=$(( $(date +%s) * 1000 ))
	_raw="${MEDIA_APP_SECRET}_$1_${_nonce}_${_ts}_$2_${MEDIA_APP_KEY}"
	printf 'nonce=%s&timestamp=%s&sign=%s' "$_nonce" "$_ts" "$(md5 "$_raw")"
}

req() {
	# $1=METHOD  $2=path  $3=body("" 表示无)  $4=token("" 表示不带)
	_m="$1"; _p="$2"; _b="$3"; _tk="$4"
	_auth=$(mkauth "$_p" "$(md5 "$_b")")
	if [ "$_m" = "GET" ]; then
		if [ -n "$_tk" ]; then
			wget -q -O - -T 25 "$BASE$_p" \
				--header="authx: $_auth" \
				--header="Cookie: Trim-MC-token=$_tk" \
				--header="Referer: $BASE/v/"
		else
			wget -q -O - -T 25 "$BASE$_p" \
				--header="authx: $_auth" \
				--header="Referer: $BASE/v/"
		fi
	else
		_bf=$(mktemp)
		printf '%s' "$_b" > "$_bf"
		if [ -n "$_tk" ]; then
			wget -q -O - -T 25 "$BASE$_p" \
				--header="authx: $_auth" \
				--header='Content-Type: application/json' \
				--header="Cookie: Trim-MC-token=$_tk" \
				--header="Referer: $BASE/v/" \
				--post-file="$_bf"
		else
			wget -q -O - -T 25 "$BASE$_p" \
				--header="authx: $_auth" \
				--header='Content-Type: application/json' \
				--header="Referer: $BASE/v/" \
				--post-file="$_bf"
		fi
		rm -f "$_bf"
	fi
}

# 1. 登录（密码 sha256，无盐）
PWH=$(printf '%s' "$MEDIA_PASSWORD" | sha256sum | cut -d' ' -f1)
LOGIN=$(req POST "/v/api/v2/user/loginByPassword" \
	"{\"username\":\"$MEDIA_USERNAME\",\"password\":\"$PWH\",\"app_name\":\"trimemedia-web\"}" "")

TOKEN=$(printf '%s' "$LOGIN" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "$TOKEN" ]; then
	echo "[media] 登录失败：$(printf '%s' "$LOGIN" | head -c 200)"
	exit 1
fi
log "登录成功 token_len=${#TOKEN}"

# 2. 触发刷新
case "$MEDIA_MODE" in
	refresh) _p="/v/api/v1/mdb/refresh" ;;
	*)       _p="/v/api/v1/mdb/scanall" ;;
esac
R=$(req POST "$_p" "{}" "$TOKEN")
echo "[media] 触发刷新($MEDIA_MODE) → $(printf '%s' "$R" | head -c 200)"

# 3. 回报各库条目数（便于验证是否真的入库），并落盘供 Web UI 展示
SUM=$(req GET "/v/api/v1/mediadb/sum" "" "$TOKEN")
if [ -n "$SUM" ]; then
	echo "[media] 媒体库统计 → $(printf '%s' "$SUM" | head -c 500)"
	if [ -n "$MEDIA_STATE_FILE" ]; then
		printf '%s\n' "$SUM" > "$MEDIA_STATE_FILE" 2>/dev/null
	fi
fi

exit 0
