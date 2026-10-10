FROM busybox:1.36

# 纯 busybox 镜像：自带 httpd（Web UI + CGI）、crond、wget、md5sum / sha256sum
# 不装 curl / python3 / node —— 全部逻辑用 POSIX shell 实现

COPY rescan.sh         /usr/local/bin/rescan.sh
COPY media-refresh.sh  /usr/local/bin/media-refresh.sh
COPY entrypoint.sh     /usr/local/bin/entrypoint.sh
COPY web               /www

RUN chmod +x /usr/local/bin/rescan.sh \
             /usr/local/bin/entrypoint.sh \
             /www/cgi-bin/api

# 内置 cron：每 CRON_SCHEDULE 触发一次扫描
ENV CRON_SCHEDULE="*/20 * * * *" \
    WEB_PORT=8090 \
    DATA_DIR=/data

EXPOSE 8090

# 入口：起 Web UI → 写 crontab → 前台跑 crond（常驻）
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
