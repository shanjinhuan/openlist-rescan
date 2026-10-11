#!/bin/sh
# 常驻入口：启动 Web UI（busybox httpd）→ 写 crontab → 前台运行 crond
set -e

SCHEDULE="${CRON_SCHEDULE:-*/20 * * * *}"
WEB_PORT="${WEB_PORT:-8090}"
WEB_ROOT="${WEB_ROOT:-/www}"
DATA_DIR="${DATA_DIR:-/data}"

mkdir -p /var/spool/cron/crontabs "$DATA_DIR"

# 清理上一次被强杀（SIGKILL，trap 来不及执行）残留的单实例锁，
# 否则后续 startup / cron 扫描会被永久跳过（表现为"扫描再也不触发"）。
rm -rf "${LOCK_FILE:-/tmp/rescan.lock}" 2>/dev/null

# cron 里显式带上 TRIGGER=cron，便于 Web UI 区分触发来源
cat > /var/spool/cron/crontabs/root <<EOF
$SCHEDULE TRIGGER=cron /usr/local/bin/rescan.sh >> /proc/1/fd/1 2>&1
EOF

echo "[entrypoint] cron schedule: $SCHEDULE"

# Web UI（busybox httpd，自带 CGI；后台驻留）
if [ -d "$WEB_ROOT" ]; then
  busybox httpd -p "$WEB_PORT" -h "$WEB_ROOT" >> /proc/1/fd/1 2>&1
  echo "[entrypoint] web ui listening on :$WEB_PORT (root=$WEB_ROOT)"
else
  echo "[entrypoint] 未找到 $WEB_ROOT，跳过 Web UI"
fi

# 启动时立刻跑一次（放后台，避免阻塞 crond 启动）
( TRIGGER=startup /usr/local/bin/rescan.sh >> /proc/1/fd/1 2>&1 ) &

echo "[entrypoint] starting crond in foreground..."
exec crond -f -l 8
