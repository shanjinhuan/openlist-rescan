# OpenList 扫描 + 影视刷新 自动化（含 Web 控制台）

一个 **单容器** 的小工具，用来自动化「115 网盘 → OpenList 落盘 strm → 飞牛影视入库」这条链路：

1. **定时触发** OpenList 扫描：`POST /api/admin/scan/start`
2. **轮询等待** 扫描完成：`GET /api/admin/scan/progress` 直到 `is_done=true`
3. **自动刷新飞牛影视**（trim.media）媒体库：`POST /api/v1/mdb/scanall`
4. **Web 控制台**：查看扫描进度、历史记录，并支持**手动触发**

整个镜像基于 `busybox:1.36`，**零额外依赖**——不装 curl / python3 / node。
Web 服务用的是 busybox 自带的 `httpd`（含 CGI），定时用的是 busybox 自带的 `crond`。

---

## 文件

```
rescan.sh            主流程：登录 OpenList → 触发扫描 → 轮询 → 调影视刷新 → 写历史
media-refresh.sh     飞牛影视刷新：逆出的 authx 签名 + 登录 + scanall
entrypoint.sh        容器入口：起 httpd（Web UI）→ 写 crontab → 前台跑 crond
web/index.html       Web 控制台前端（无框架、无外链）
web/cgi-bin/api      Web 后端（busybox shell CGI）
Dockerfile           busybox:1.36
docker-compose.yml   单容器部署
.env.example         凭据与参数模板
```

---

## Web 控制台

启动后访问 `http://<NAS IP>:8090/`。

- **当前扫描**：已扫描对象数、运行中/空闲、已用时、触发方式、扫描路径
- **历史扫描记录**：开始时间、触发方式、用时、对象数、影视刷新结果、媒体库条目数、状态
- **立即触发扫描**：按钮，后台异步执行，不影响页面响应

后端接口（CGI）：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/cgi-bin/api?action=status` | 当前进度 + 运行态 + 最近媒体库统计 |
| GET | `/cgi-bin/api?action=history&limit=50` | 历史扫描记录 |
| POST | `/cgi-bin/api?action=trigger` | 手动触发一次扫描 |

数据落盘在挂载的 `data/` 目录：

- `data/current-run.json` —— 当前运行中任务的标记（运行结束即删除）
- `data/scan-history.jsonl` —— 每行一条已完成记录
- `data/last-media.json` —— 最近一次影视媒体库统计
- `data/keys.local` —— 影视签名用的应用级常量（**不纳入版本控制**，见下）

### `data/keys.local`（必需）

`media-refresh.sh` 依赖飞牛影视 Web 客户端内置的两个常量来构造 `authx` 签名。
它们不是用户凭据，但也不适合放进版本库，因此改为从数据目录读取：

```sh
# data/keys.local
MEDIA_APP_SECRET=<32 位十六进制串>
MEDIA_APP_KEY=<UUID 形式>
```

获取方式：从飞牛影视 Web 端 bundle（`/v/assets/*.js`）里取——`SECRET` 是明文串，
`apiKey` 是被 XOR(169) 混淆的字节数组，解出来就是一个 UUID 形式的字符串。
如果你是从已部署好的环境搬过来的，直接拷 `data/keys.local` 即可。

---

## 部署

### 方式 A：docker compose（有 build 能力的机器）

```bash
cp .env.example .env && vi .env
docker compose up -d --build
```

### 方式 B：直接跑镜像（fnOS / 无 build 能力时）

```bash
docker run -d --name openlist-rescan --restart always \
  -p 8090:8090 \
  -e OPENLIST_URL=http://172.17.0.1:5245 \
  -e OPENLIST_USERNAME=admin -e OPENLIST_PASSWORD='...' \
  -e SCAN_PATH=/strm -e SCAN_LIMIT=3 \
  -e MEDIA_REFRESH_ENABLE=1 -e MEDIA_URL=http://172.17.0.1:8005 \
  -e MEDIA_USERNAME='...' -e MEDIA_PASSWORD='...' \
  -e TZ=CST-8 -e WEB_PORT=8090 -e LOG_LEVEL=debug \
  -v "$PWD/data:/data" \
  busybox:1.36 /bin/sh /usr/local/bin/entrypoint.sh
```

> `172.17.0.1` 是 Docker bridge 网关，指宿主机。容器内以此访问宿主机上的
> OpenList（5245）与飞牛影视（8005）。

### 接入反向代理（从外网访问）

容器监听 `8090`。若要从公网访问，在反代里加一条规则即可，例如：

```
rescan.你的域名  →  http://192.168.31.37:8090
```

**注意**：Web 控制台本身**没有鉴权**，只适合内网或加一层反代 Basic Auth 后再暴露公网。

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `OPENLIST_URL` | — | OpenList 地址，容器内用 `http://172.17.0.1:5245` |
| `OPENLIST_USERNAME` / `OPENLIST_PASSWORD` | — | OpenList 管理员凭据 |
| `SCAN_PATH` | `/strm` | 扫描路径 |
| `SCAN_LIMIT` | `3` | 扫描限速（越大越快，越吃 115 API 配额） |
| `SCAN_WAIT_MAX` | `1500` | 等扫描完成的最长秒数，超时则本轮不刷新影视 |
| `MEDIA_REFRESH_ENABLE` | `1` | 是否在扫描完成后自动刷新影视 |
| `MEDIA_URL` | — | 飞牛影视内部地址（宿主 `8005`） |
| `MEDIA_USERNAME` / `MEDIA_PASSWORD` | — | 飞牛影视账号（**与 fnOS 账号不同**，见下） |
| `MEDIA_MODE` | `scanall` | `scanall` 刷新全部库；`refresh` 走 `/mdb/refresh` |
| `CRON_SCHEDULE` | `*/20 * * * *` | 定时表达式 |
| `WEB_PORT` | `8090` | Web 控制台端口 |
| `DATA_DIR` | `/data` | 状态与历史目录 |
| `LOG_LEVEL` | `info` | `debug` 打印每次执行详情 |

---

## 实现要点（踩过的坑）

- **飞牛影视 API 需要 `authx` 签名**
  `authx = nonce=..&timestamp=..&sign=md5(SECRET_path_nonce_ts_md5(body)_apiKey)`
  `SECRET` / `apiKey` 从前端 bundle 里逆出（apiKey 是 XOR(169) 混淆的 UUID）。
  Web 页面里签的是 **v1** 路径，但登录端点实际打的是 **v2**：
  `POST /v/api/v2/user/loginByPassword`（用 v1 会返回 `Invalid Params`）。
- **登录密码是 `sha256(原文)`**，不是 md5，无盐。
- **全局刷新用 `/mdb/scanall`**（`/mdb/refresh` 需要指定单库参数，空 body 报参数错）。
- **`SaveStrmLocalPath` 末尾不能有换行符**。值里带了 `\n` 会导致 `mkdir /strm\n/xxx`
  在根目录操作、`permission denied`，strm 一条也落不下来。
- **媒体库目录必须和 strm 实际落盘路径一致**。strm 落在
  `/vol2/1000/strm/<分类>/`，若媒体库配成 `/vol2/1000/strm/videos/<分类>/`
  就会扫到不存在的目录、`root.bolt` 纹丝不动（扫描"成功"但一条不入库）。
- **`TZ=CST-8`**：busybox 没有 tzdata，但 musl 支持 POSIX TZ 字符串，
  这样 `date` 直接输出北京时间，日志与历史都是本地时间。
