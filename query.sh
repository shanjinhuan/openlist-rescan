#!/bin/sh
# 一次性查询 OpenList 状态（容器内网直连，绕过公网登录限流）
# 通过 env 传入 OPENLIST_URL / OPENLIST_USERNAME / OPENLIST_PASSWORD
BASE="${OPENLIST_URL%/}"

LB=$(mktemp)
printf '{"username":"%s","password":"%s"}' "$OPENLIST_USERNAME" "$OPENLIST_PASSWORD" > "$LB"
LOGIN_JSON=$(wget -q -O - -T 20 "$BASE/api/auth/login" \
  --header='Content-Type: application/json' --post-file="$LB")
rm -f "$LB"

TOKEN=$(printf '%s' "$LOGIN_JSON" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "$TOKEN" ]; then
  echo "LOGIN_FAIL=$(printf '%s' "$LOGIN_JSON" | head -c 200)"
  exit 1
fi
echo "LOGIN_OK token_len=${#TOKEN}"

echo "SCAN_PROGRESS=$(wget -q -O - -T 20 "$BASE/api/admin/scan/progress" --header="Authorization: $TOKEN")"
echo "INDEX_PROGRESS=$(wget -q -O - -T 20 "$BASE/api/admin/index/progress" --header="Authorization: $TOKEN")"
echo "STORAGE_LIST=$(wget -q -O - -T 25 "$BASE/api/admin/storage/list" --header="Authorization: $TOKEN" | head -c 3000)"
