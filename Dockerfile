FROM alpine:3.20

# curl 请求用，python3 解析 JSON
RUN apk add --no-cache curl python3 busybox-suid

COPY rescan.sh /usr/local/bin/rescan.sh
RUN chmod +x /usr/local/bin/rescan.sh

# 内置 cron：每 CRON_SCHEDULE 跑一次 rescan.sh，日志输出到 stdout
# 默认每 20 分钟
ENV CRON_SCHEDULE="*/20 * * * *"

# 入口：写 crontab → 前台跑 crond（常驻）
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
