#!/bin/sh
# 常驻入口：写入 crontab 并前台运行 crond
set -e

SCHEDULE="${CRON_SCHEDULE:-*/20 * * * *}"

# 生成 crontab：定时跑 rescan.sh，输出重定向到容器 stdout（通过 /proc/1/fd/1）
mkdir -p /etc/periodic
cat > /var/spool/cron/crontabs/root <<EOF
$SCHEDULE /usr/local/bin/rescan.sh >> /proc/1/fd/1 2>&1
EOF

echo "[entrypoint] cron schedule: $SCHEDULE"
echo "[entrypoint] starting crond in foreground..."

# 前台运行 crond（busybox crond -f），日志级别 2 输出启动信息
exec crond -f -l 2
