# OpenList 定时扫描 — 部署说明

这个目录把「OpenList 手动扫描」做成了一个 Docker 镜像，用 `curl` 定时触发 `POST /api/admin/scan/start`（实测可用，接口幂等：扫描中再次触发会返回 400 而不会重复跑）。

## 文件

```
rescan.sh           核心脚本：登录 OpenList → 取 token → 触发扫描（token 不落盘）
Dockerfile          alpine + curl + python3
docker-compose.yml  一次性运行模式（run --rm）
.env.example        凭据模板，复制为 .env 后填入
```

## 部署步骤（NAS 上）

```bash
# 1. 上传整个目录到 NAS，例如 /vol1/1000/docker/openlist-rescan/
# 2. 进入目录，复制并填写凭据
cd /vol1/1000/docker/openlist-rescan
cp .env.example .env
vi .env   # 填 OPENLIST_URL / USERNAME / PASSWORD

# 3. 构建镜像
docker compose build

# 4. 手动试跑一次（应输出「扫描已触发」）
docker compose run --rm rescan
```

## 定时方式（二选一）

### 方式 A：fnOS 计划任务（推荐，最简单）

fnOS 系统 → 计划任务 → 新建，命令填：

```
cd /vol1/1000/docker/openlist-rescan && docker compose run --rm rescan
```

触发周期建议 `*/20 * * * *`（每 20 分钟）。执行时用 `LOG_LEVEL=info` 静默，不刷日志。

### 方式 B：把 cron 装进容器（容器自带定时，一劳永逸）

如果想「镜像内置定时、不依赖宿主机计划任务」，把 `docker-compose.yml` 换成下面的
`docker-compose.cron.yml`，并把 entrypoint 改成「cron 前台运行」。

## 关键参数

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `OPENLIST_URL` | — | OpenList 地址。内网用 `http://192.168.31.37:5245`，外网/DDNS 用反代域名 |
| `OPENLIST_USERNAME` | — | 管理员用户名 |
| `OPENLIST_PASSWORD` | — | 管理员密码 |
| `SCAN_PATH` | `/strm` | 扫描路径 |
| `SCAN_LIMIT` | `3` | 限速（越大越快，但更吃 115 API 配额） |
| `LOG_LEVEL` | `info` | `debug` 打印每次执行详情 |

## ⚠️ 两个注意点

1. **凭据明文**：`.env` 里是明文密码，放 NAS 私密目录、别外传。想更安全可改用
   「token 预置」方式（但 token 48h 过期，反而不如每次登录省心）。
2. **先解决落盘**：定时扫描只是「触发重扫」，如果 OpenList 的 strm 没真正落到宿主机
   `/vol2/1000/strm`，飞牛影视仍看不到。**上自动扫描前，先确认落盘正常**（见清单文档 §18）。

## 可选：内置 cron 的 compose（方式 B 用）

```yaml
services:
  rescan:
    build: .
    image: openlist-rescan:latest
    container_name: openlist-rescan
    restart: unless-stopped
    env_file: .env
    environment:
      - SCAN_PATH=/strm
      - SCAN_LIMIT=3
      - TZ=Asia/Shanghai
      # cron 表达式：每 20 分钟
      - CRON_SCHEDULE=*/20 * * * *
    # 需在 Dockerfile 里加 crond + 用 supercronic 或 busybox crond 前台运行
```
