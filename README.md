# 企业级 Nginx 源码编译部署脚本

一键从源码编译安装 Nginx，内置供应链校验、证书校验、HTTP/3、WebDAV、Stream SNI 分流、systemd 沙箱、日志轮转与安全卸载。

适用于 Debian 11+ / Debian 13（推荐），也可用于 Ubuntu 22.04+。

- 当前默认版本：Nginx `1.31.8`、OpenSSL `3.5.9`（LTS）、jemalloc `5.4.0`
- 安装前缀：`/etc/nginx`
- 默认站点示例：`main.abc.com` / `dav.abc.com` / `api.abc.com` / `tun.abc.com`

> 示例域名 `abc.com`、示例证书路径仅用于文档演示，部署前请替换为你的真实域名和证书路径。

## 目录

- [功能特性](#功能特性)
- [架构说明](#架构说明)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [环境变量说明](#环境变量说明)
- [安装与卸载](#安装与卸载)
- [部署后验证](#部署后验证)
- [证书要求](#证书要求)
- [WebDAV 使用](#webdav-使用)
- [日志、备份与回滚](#日志备份与回滚)
- [安全基线](#安全基线)
- [性能基线](#性能基线)
- [常见问题](#常见问题)
- [升级与校验](#升级与校验)
- [项目结构](#项目结构)
- [相关文档](#相关文档)

## 功能特性

- **源码编译**：Nginx + OpenSSL + jemalloc，支持 CPU 多线程并行编译。
- **供应链安全**：HTTPS 下载、SHA256 校验、Git commit pin；严格模式下缺值直接拒绝执行。
- **证书校验**：导入前校验证书可解析、未过期、证书与私钥匹配、SAN/CN 覆盖目标域名。
- **HTTP/2 + HTTP/3**：TCP 443 走 Stream SNI 分流，UDP 443 直连 QUIC，并下发 `Alt-Svc`。
- **Stream SNI 分流**：主站、TUN（Tunnel）、WebDAV/API 共用 443，按 SNI 转发。
- **真实客户端 IP**：Stream 向下游发送 PROXY protocol，HTTP 层 `real_ip` 还原真实 IP。
- **WebDAV 防滥用**：读写分层限速、并发限制、`auth_delay`、Fail2Ban 模板。
- **TLS 强化**：TLS 1.2/1.3、ECDHE、禁用会话票据、禁用 0-RTT、OCSP stapling。
- **安全响应头**：HSTS、CSP、X-Frame-Options、X-Content-Type-Options、Referrer-Policy、Permissions-Policy。
- **systemd 沙箱**：`ProtectSystem=strict`、`PrivateTmp`、`NoNewPrivileges`、最小能力集等。
- **可运维**：安装前备份、失败回滚、logrotate、journald 自动降级、安全卸载。
- **可卸载**：支持 `--uninstall` 和 `--uninstall --preserve-www`。

## 架构说明

```text
                         ┌─────────────────────────────────────────────┐
                         │                  Nginx                      │
Client                   │                                             │
  │                      │  stream (TCP 443/2096/2099/8443)           │
  │  TCP 443  ──────────►│    ssl_preread SNI + PROXY protocol         │
  │                      │      ├─ main.abc.com ─► 127.0.0.1:1111     │
  │                      │      ├─ tun.abc.com  ─► 127.0.0.1:9443     │
  │                      │      └─ dav/api      ─► 127.0.0.1:7443     │
  │                      │                                              │
  │  UDP 443  ──────────►│  http/3 (QUIC) 直接终止 TLS                 │
  │                      │      ├─ main.abc.com                        │
  │                      │      ├─ dav.abc.com                         │
  │                      │      ├─ api.abc.com                         │
  │                      │      └─ tun.abc.com                         │
                         └─────────────────────────────────────────────┘
```

- `web_mux`：WebDAV 与 API 共用本地 `127.0.0.1:7443`，由 `server_name` 做 L7 分流。
- TUN（Tunnel）：`tun.abc.com` 由 Stream 分流到 `127.0.0.1:9443`，提供 `/vless` 反代入口与 `/healthz`。
- 默认上游：主站 `/ws_endpoint/` → `127.0.0.1:1000`；TUN `/vless` → `VLESS_UPSTREAM`（默认 `http://127.0.0.1:10000`）。

## 环境要求

- Debian 11+ / Debian 13（优先）或 Ubuntu 22.04+
- root 权限
- 已解析的域名（主站、WebDAV、API、TUN）
- 可用的证书与私钥（建议全链证书）
- 防火墙放行：
  - TCP `443`、`2096`、`2099`、`8443`
  - UDP `443`（HTTP/3）

## 快速开始

### 1. 准备文件

将以下文件放到同一目录（示例：`/opt/nginx-deploy`）：

```text
/opt/nginx-deploy/
├── install_nginx.sh
├── nginx-build.env
├── project.md
└── DEPLOYMENT.md
```

### 2. 修改环境变量

编辑 `nginx-build.env`，至少修改：

```bash
STRICT_SUPPLYCHAIN=1
STRICT_CERT_SAN=1

MAIN_DOMAIN=main.abc.com
DAV_DOMAIN=dav.abc.com
API_DOMAIN=api.abc.com
TUN_DOMAIN=tun.abc.com

MAIN_CERT_SRC=/etc/letsencrypt/live/abc.com/fullchain.pem
MAIN_KEY_SRC=/etc/letsencrypt/live/abc.com/privkey.pem

NON_INTERACTIVE=1
```

> `DAV/API/TUN` 证书留空时，默认复用主站证书。请确认主站证书覆盖这些子域（或使用通配符证书），否则 `STRICT_CERT_SAN=1` 会拒绝安装。

### 3. 非交互安装

```bash
sudo bash -c '
  set -a
  source /opt/nginx-deploy/nginx-build.env
  set +a
  /opt/nginx-deploy/install_nginx.sh
'
```

### 4. 交互安装

```bash
sudo bash -c '
  set -a
  source /opt/nginx-deploy/nginx-build.env
  set +a
  NON_INTERACTIVE=0 /opt/nginx-deploy/install_nginx.sh
'
```

## 环境变量说明

完整模板见 [`nginx-build.env`](./nginx-build.env)。

### 供应链与证书

| 变量 | 默认值 | 说明 |
|---|---|---|
| `STRICT_SUPPLYCHAIN` | `1` | 严格供应链模式，缺少 SHA256/commit 即终止 |
| `STRICT_CERT_SAN` | `1` | 证书 SAN 未覆盖域名时终止；`0` 仅告警 |
| `NGINX_TARBALL_SHA256` | 已内置 | Nginx 源码包校验值 |
| `OPENSSL_TARBALL_SHA256` | 已内置 | OpenSSL 源码包校验值 |
| `JEMALLOC_TARBALL_SHA256` | 已内置 | jemalloc 源码包校验值 |
| `FANCYINDEX_TARBALL_SHA256` | 已内置 | ngx-fancyindex 校验值 |
| `DAV_EXT_TARBALL_SHA256` | 已内置 | nginx-dav-ext 校验值 |
| `HEADERS_MORE_TARBALL_SHA256` | 已内置 | headers-more 校验值 |
| `NGX_BROTLI_COMMIT` | 已内置 | ngx_brotli commit pin |

### 部署模式

| 变量 | 默认值 | 说明 |
|---|---|---|
| `NON_INTERACTIVE` | `1` | `1` 全程无交互；`0` 缺失参数时交互输入 |
| `ROLLBACK_ON_ERROR` | `1` | 安装失败自动回滚 |
| `CLEAN_BUILD_ARTIFACTS` | `1` | 安装成功后清理源码与压缩包 |

### 站点与证书

| 变量 | 示例值 | 说明 |
|---|---|---|
| `MAIN_DOMAIN` | `main.abc.com` | 主站域名 |
| `DAV_DOMAIN` | `dav.abc.com` | WebDAV 域名 |
| `API_DOMAIN` | `api.abc.com` | API 域名 |
| `TUN_DOMAIN` | `tun.abc.com` | TUN（Tunnel）域名 |
| `MAIN_CERT_SRC` | `/etc/letsencrypt/live/abc.com/fullchain.pem` | 主站证书 |
| `MAIN_KEY_SRC` | `/etc/letsencrypt/live/abc.com/privkey.pem` | 主站私钥 |
| `DAV_CERT_SRC` / `DAV_KEY_SRC` | 空 | WebDAV 证书（可复用主站） |
| `API_CERT_SRC` / `API_KEY_SRC` | 空 | API 证书（可复用主站） |
| `TUN_CERT_SRC` / `TUN_KEY_SRC` | 空 | TUN 证书（可复用主站） |
| `*_REUSE_MAIN_CERT` | `1` | 未显式提供时复用主站证书 |
| `VLESS_UPSTREAM` | `http://127.0.0.1:10000` | TUN `/vless` 上游地址 |

### Fail2Ban 模板

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ENABLE_FAIL2BAN_TEMPLATE` | `1` | 生成 Fail2Ban 模板（不自动安装） |
| `F2B_MAXRETRY` | `6` | 失败次数阈值 |
| `F2B_FINDTIME` | `10m` | 统计窗口 |
| `F2B_BANTIME` | `12h` | 封禁时长 |
| `F2B_IGNOREIP` | `127.0.0.1/8 ::1` | 白名单 |

### 卸载

| 变量 | 默认值 | 说明 |
|---|---|---|
| `FORCE_UNINSTALL` | `0` | `1` 跳过二次确认 |
| `PRESERVE_WWW` | `0` | `1` 卸载时保留 `/var/www` |

## 安装与卸载

### 安装

```bash
sudo bash -c 'set -a; source /opt/nginx-deploy/nginx-build.env; set +a; /opt/nginx-deploy/install_nginx.sh'
```

安装流程：

1. 系统兼容性检查
2. 安装编译依赖
3. 检查版本时效性
4. 采集域名与证书参数
5. 校验证书 SAN、有效期、私钥匹配
6. 备份已有 Nginx 配置
7. 下载并校验源码
8. 编译 jemalloc、OpenSSL、Nginx
9. 导入证书
10. 生成 Nginx、Fail2Ban、systemd、logrotate 配置
11. 配置测试并启动
12. 清理编译产物

### 卸载

```bash
# 交互式卸载（需输入确认短语 UNINSTALL NGINX）
sudo /opt/nginx-deploy/install_nginx.sh --uninstall

# 卸载但保留 /var/www 数据
sudo /opt/nginx-deploy/install_nginx.sh --uninstall --preserve-www

# 非交互强制卸载（谨慎）
sudo NON_INTERACTIVE=1 FORCE_UNINSTALL=1 /opt/nginx-deploy/install_nginx.sh --uninstall --yes
```

卸载会删除：

- `/etc/nginx`
- `/etc/systemd/system/nginx.service`
- `/etc/logrotate.d/nginx`
- `/var/log/nginx`、`/var/lib/nginx`
- `/var/www/html`、`/var/www/dav`（`--preserve-www` 时保留）
- `/usr/local/src` 下本脚本下载的源码与压缩包
- jemalloc 安装产物
- Fail2Ban 的 nginx-webdav 模板/规则

## 部署后验证

```bash
# 服务状态
sudo systemctl status nginx --no-pager

# 配置检查
sudo /etc/nginx/sbin/nginx -t -e /var/log/nginx/error.log -c /etc/nginx/conf/nginx.conf

# 版本与 TLS 库（应显示 1.31.8 + OpenSSL 3.5.9）
/etc/nginx/sbin/nginx -V 2>&1 | head -5

# 健康检查
curl -kI https://main.abc.com/healthz
curl -kI https://dav.abc.com/healthz
curl -kI https://api.abc.com/healthz
curl -kI https://tun.abc.com/healthz
curl -kI https://tun.abc.com/vless

# HTTP/3（需 curl 支持 --http3）
curl --http3 -sI https://main.abc.com/healthz

# OCSP stapling
echo | openssl s_client -connect main.abc.com:443 -servername main.abc.com -status 2>/dev/null | grep -A2 "OCSP response"

# SNI 分流命中
sudo tail -n 100 /var/log/nginx/stream_sni.log
```

`stream_sni.log` 中应能看到：

```text
sni="main.abc.com" backend="proxy_main"
sni="tun.abc.com"  backend="proxy_tun"
sni="dav.abc.com"  backend="proxy_web_mux"
sni="api.abc.com"  backend="proxy_web_mux"
```

## 证书要求

- 建议使用全链证书（含中间证书）。
- 证书必须未过期，且与私钥匹配。
- 证书 SAN/CN 必须覆盖对应域名，支持通配符（如 `*.abc.com`）。
- 私钥安装后权限为 `root:root 0600`，证书为 `root:root 0644`。
- 复用主站证书时，主站证书必须覆盖 `dav/api/tun` 子域。
- 严格模式由 `STRICT_CERT_SAN=1` 控制；不建议关闭。

## WebDAV 使用

初始化账号：

```bash
sudo htpasswd -B /etc/nginx/dav.pass.public your_user
```

默认防护策略：

| 项目 | 值 |
|---|---|
| 读请求限速 | `180r/m`，burst `90` |
| 写方法限速 | `30r/m`，burst `10` |
| 认证层限速 | `120r/m`，burst `40` |
| 单 IP 并发连接 | `6` |
| 认证延迟 | `1200ms` |
| 单请求体积 | `50G` |
| 认证文件 | `/etc/nginx/dav.pass.public` |

Fail2Ban 模板生成在：

```text
/etc/nginx/security/fail2ban/filter.d/nginx-webdav-auth.conf
/etc/nginx/security/fail2ban/jail.d/nginx-webdav-auth.local
```

启用方式（脚本不自动安装 Fail2Ban）：

```bash
sudo apt-get update && sudo apt-get install -y fail2ban
sudo cp /etc/nginx/security/fail2ban/filter.d/nginx-webdav-auth.conf /etc/fail2ban/filter.d/
sudo cp /etc/nginx/security/fail2ban/jail.d/nginx-webdav-auth.local /etc/fail2ban/jail.d/
sudo systemctl restart fail2ban
sudo fail2ban-client status nginx-webdav-auth
```

## 日志、备份与回滚

### 日志

| 日志 | 路径 |
|---|---|
| 主访问日志 | `/var/log/nginx/access.log` |
| 主错误日志 | `/var/log/nginx/error.log` |
| WebDAV 访问日志 | `/var/log/nginx/dav_access.log` |
| WebDAV 错误日志 | `/var/log/nginx/dav_error.log` |
| SNI 分流日志 | `/var/log/nginx/stream_sni.log` |

- 存在 `/dev/log` 时同时写入 journald；不存在时自动降级为仅文件日志。
- 已自动生成 `/etc/logrotate.d/nginx`：按天轮转、保留 14 天、`USR1` 重开。

### 备份

安装前若已存在 Nginx，会备份到：

```text
/var/backups/nginx-install-<YYYYmmdd-HHMMSS>/
├── etc-nginx/
├── nginx.service
└── logrotate-nginx
```

### 回滚

- 安装失败且此前存在 Nginx：从备份恢复 `/etc/nginx` 与 systemd 单元。
- 安装失败且此前不存在 Nginx：清理本次生成的产物。
- 需要保留现场排障时设置 `ROLLBACK_ON_ERROR=0`。

## 安全基线

- 供应链：HTTPS + SHA256 + commit pin，严格模式缺值即拒绝。
- 证书：有效期、私钥匹配、SAN/CN 覆盖校验。
- 传输：TLS 1.2/1.3、仅 ECDHE、禁用会话票据、禁用 0-RTT、OCSP stapling。
- 响应头：HSTS（不含 preload）、CSP（无 `unsafe-inline`）、X-Frame-Options、nosniff、Referrer-Policy、Permissions-Policy。
- 访问控制：WebDAV Basic Auth、分层限速、连接限制、`auth_delay`、Fail2Ban 模板。
- 真实 IP：Stream PROXY protocol + `real_ip_header proxy_protocol`。
- 进程：systemd 沙箱、最小能力集、pidfile 安全停止。
- 可审计：文件日志 + journald + logrotate。
- 变更安全：安装前备份、失败回滚、严格卸载确认。

## 性能基线

- `worker_processes auto` + `worker_rlimit_nofile 65535` + `reuseport`
- `sendfile` / `tcp_nopush` / `tcp_nodelay`
- `open_file_cache`（WebDAV 目录关闭以避免元数据过期）
- `aio threads`（大文件读写）
- HTTP/2 复用 + `ssl_session_cache`
- jemalloc 降低内存碎片
- Stream `proxy_timeout 1h`，避免切断 TUN/WebSocket 长连接
- WebDAV 读写分层限速，避免同步客户端被误伤

## 常见问题

### 1. 证书 SAN 校验失败

```text
证书 SAN 未覆盖域名 xxx
```

处理方式：

- 提供覆盖该域名的证书；
- 或使用通配符证书；
- 或在测试环境设置 `STRICT_CERT_SAN=0`（生产不推荐）。

### 2. 严格供应链校验失败

```text
严格供应链模式已启用，但未提供 xxx 的 SHA256
```

处理方式：补全 `nginx-build.env` 中的 SHA256 / commit pin，并与版本严格对应。

### 3. HTTP/3 不生效

- 确认防火墙放行 **UDP 443**；
- 确认客户端支持 HTTP/3（`curl --http3`）；
- 检查响应头是否包含 `Alt-Svc: h3=":443"`；
- 若在 CDN/LB 之后，需要该层支持并转发 QUIC。

### 4. WebDAV 频繁 429

调整 `nginx.conf` 中的 `webdav_read` / `webdav_write` / `webdav_auth_limit`，并检查是否多个用户共享同一出口 IP。

### 5. 没有 journald 日志

Debian 13 最小化系统可能没有 `/dev/log`，脚本会自动跳过 syslog 通道，仅保留文件日志。

### 6. SNI 分流不生效

检查 `/var/log/nginx/stream_sni.log` 中的 `sni` 是否为真实域名。如果始终是同一个域名，通常是上游 CDN/代理没有透传原始 SNI。

### 7. `api/dav` 全部落到主站

确认 Stream 配置已加载，并检查 `stream_sni.log` 中的 `backend` 字段是否为 `proxy_web_mux`。

## 升级与校验

### 升级版本

1. 修改 `nginx-build.env` 中的 `NGINX_VER` / `OPENSSL_VER` / `NGX_BROTLI_REF` 等；
2. 同步更新对应 SHA256 与 commit pin；
3. 在测试机重新安装并验证；
4. 确认 `nginx -V` 输出目标版本与 `built with OpenSSL 3.5.x`。

### 静态校验

```bash
bash -n install_nginx.sh
shellcheck -S warning install_nginx.sh
```

### 运行期校验

```bash
# 监听端口（TCP 443/2096/2099/8443 + UDP 443）
sudo ss -lntup | grep nginx

# 版本与编译参数
/etc/nginx/sbin/nginx -V

# 配置测试
sudo /etc/nginx/sbin/nginx -t -e /var/log/nginx/error.log -c /etc/nginx/conf/nginx.conf
```

> HTTP/3 在 Nginx 中仍属实验性功能，建议保持补丁更新，并在升级前做完整回归测试。

## 项目结构

| 文件 | 说明 |
|---|---|
| [`install_nginx.sh`](./install_nginx.sh) | 一键编译、配置、启动、回滚、卸载 |
| [`nginx-build.env`](./nginx-build.env) | 供应链校验、版本、域名、证书、限速等变量 |
| [`project.md`](./project.md) | 设计目标与安全基线 |
| [`DEPLOYMENT.md`](./DEPLOYMENT.md) | 完整部署、排障与升级手册 |
| `README.md` | 项目总览与快速使用 |

## 相关文档

- [部署与排障详解](./DEPLOYMENT.md)
- [设计目标与安全基线](./project.md)
- [环境变量模板](./nginx-build.env)

---

如用于生产环境，请务必：

1. 替换示例域名与证书路径；
2. 保持 `STRICT_SUPPLYCHAIN=1`、`STRICT_CERT_SAN=1`；
3. 在测试环境完成一次完整安装与卸载回归；
4. 按需启用 Fail2Ban 并接入日志采集。
