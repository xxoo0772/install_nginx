# 企业级 Nginx 源码编译部署脚本

单文件、无 env 依赖的一键 Nginx 编译部署脚本。

- 所有配置直接写在脚本顶部，编辑即可
- 组件版本、SHA256、commit pin 均为显式变量
- 默认交互安装；先询问基础域名，再输入主站子域名
- 证书路径支持模板，按基础域名自动替换，输入域名即可完成配置
- 单证书：不拷贝证书，所有站点统一引用
- 默认只启用 main 主站，其他场景提供模板
- stream SNI 监听 TCP `HTTPS_PORT`（默认 443）
- 支持 IPv4/IPv6 双栈监听
- 支持 HTTP/2、HTTP/3、WebDAV、反向代理、安全基线、systemd 沙箱
- 支持安装前备份、失败回滚、可审计卸载

## 目录

- [功能特性](#功能特性)
- [快速开始](#快速开始)
- [脚本配置](#脚本配置)
- [交互安装](#交互安装)
- [无交互安装](#无交互安装)
- [架构说明](#架构说明)
- [安装后目录](#安装后目录)
- [证书说明](#证书说明)
- [场景模板](#场景模板)
- [stream SNI 接入](#stream-sni-接入)
- [HTTP/3 与端口](#http3-与端口)
- [HTTP → HTTPS 跳转](#http--https-跳转)
- [IPv6](#ipv6)
- [验证](#验证)
- [卸载](#卸载)
- [项目结构](#项目结构)
- [相关文档](#相关文档)

## 功能特性

- **单文件**：不需要 env 文件、不需要额外目录。
- **显式版本变量**：组件版本与 SHA256 集中在脚本顶部。
- **源码编译**：Nginx + OpenSSL + jemalloc，自动多线程编译。
- **供应链校验**：HTTPS、SHA256、Git commit pin。
- **单证书**：安装时指定一次，所有站点和模板统一引用。
- **默认交互**：先询问基础域名，再输入主站子域名；证书路径按模板自动生成。
- **stream SNI**：监听 `HTTPS_PORT`，分流到 main 后端。
- **IPv6**：外部监听默认 IPv4/IPv6 双栈，可选内部 IPv6 回环。
- **HTTP 跳转**：支持 `main`、`base`、`list`、`all` 四种模式。
- **场景模板**：`ws`、`webdav`、`reverse-proxy`。
- **安全基线**：TLS 1.2/1.3、ECDHE、HSTS、CSP、OCSP 自动判断。
- **systemd 沙箱**：最小能力集、`ProtectSystem=strict` 等。
- **可运维**：备份、回滚、logrotate、journald 自动降级。
- **可卸载**：`--uninstall`、`--preserve-www`、`--yes`。

## 快速开始

### 方式一：下载后执行（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/<your-org>/<your-repo>/main/install_nginx.sh -o /tmp/install_nginx.sh && sudo bash /tmp/install_nginx.sh
```

> 把 `<your-org>/<your-repo>` 替换为你的 GitHub 组织/仓库。

### 方式二：直接管道执行

```bash
curl -fsSL https://raw.githubusercontent.com/<your-org>/<your-repo>/main/install_nginx.sh | sudo bash
```

脚本会优先从 `/dev/tty` 读取交互输入，因此管道方式也可以正常提示。

### 方式三：Git 克隆

```bash
git clone <repository-url> nginx-deploy
cd nginx-deploy
sudo ./install_nginx.sh
```

## 脚本配置

所有可修改项都在脚本顶部：

```bash
# ---------- 组件版本 ----------
NGINX_VER="1.31.8"
OPENSSL_VER="3.5.9"
JEMALLOC_VER="5.4.0"
FANCYINDEX_VER="0.6.0"
DAV_EXT_VER="3.0.0"
HEADERS_MORE_VER="0.41"
NGX_BROTLI_REF="v1.0.0rc"

# ---------- 组件校验值 ----------
NGINX_TARBALL_SHA256="..."
OPENSSL_TARBALL_SHA256="..."
JEMALLOC_TARBALL_SHA256="..."
FANCYINDEX_TARBALL_SHA256="..."
DAV_EXT_TARBALL_SHA256="..."
HEADERS_MORE_TARBALL_SHA256="..."
NGX_BROTLI_COMMIT="..."

# ---------- 部署参数 ----------
NON_INTERACTIVE="0"

# 基础域名 + 主站子域名（主站域名自动拼接为 main.abc.com）
BASE_DOMAIN=""
MAIN_SUBDOMAIN="main"
PRIMARY_DOMAIN=""

# 证书/私钥路径模板：__BASE_DOMAIN__ 会替换为基础域名
SSL_CERT_PATH_TPL="/etc/letsencrypt/__BASE_DOMAIN__/fullchain.cer"
SSL_KEY_PATH_TPL="/etc/letsencrypt/__BASE_DOMAIN__/__BASE_DOMAIN__.key"
# 也可直接填写固定绝对路径（填写后优先使用）
SSL_CERT_PATH=""
SSL_KEY_PATH=""

# 对外 HTTPS/TLS 端口与 HTTP 跳转源端口
HTTPS_PORT="443"
HTTP_REDIRECT_PORT="80"

# HTTP → HTTPS 跳转
HTTP_REDIRECT="1"
HTTP_REDIRECT_MODE="main"        # main / base / list / all
HTTP_REDIRECT_DOMAINS=""         # list 模式使用，空格分隔

# 内部回环地址与端口
MAIN_BACKEND_PORT="1111"
MAIN_BACKEND_ADDR="127.0.0.1"    # IPv6 使用 "[::1]"

# IPv6 双栈监听
IPV6_ENABLE="1"

# HTTP/3
HTTP3_ENABLE="0"
HTTP3_PORT="443"
OCSP_STAPLING="auto"
STRICT_SUPPLYCHAIN="1"
STRICT_CERT_SAN="1"
ROLLBACK_ON_ERROR="1"
CLEAN_BUILD_ARTIFACTS="1"
ENABLE_FAIL2BAN_TEMPLATE="1"
F2B_MAXRETRY="6"
F2B_FINDTIME="10m"
F2B_BANTIME="12h"
F2B_IGNOREIP="127.0.0.1/8 ::1"
```

版本号与对应 SHA256 / commit pin 集中维护。

## 交互安装

```bash
sudo ./install_nginx.sh
```

提示示例：

```text
[1/17] 检查系统兼容性
[成功] 系统兼容性检查通过
[2/17] 安装编译依赖
[3/17] 采集域名与证书参数
  请输入基础域名（例如 abc.com）: abc.com
  请输入主站子域名（例如 main，最终为 main.abc.com；输入 @ 使用 abc.com）: main
  请输入对外 HTTPS 端口 [443]: 443
  请输入证书路径（回车使用默认值）: /etc/letsencrypt/abc.com/fullchain.cer
  请输入私钥路径（回车使用默认值）: /etc/letsencrypt/abc.com/abc.com.key
  是否生成 HTTP → HTTPS 跳转？ [Y/n] y
  跳转模式 main/base/list/all [main]: main
  HTTP 跳转源端口 [80]: 80
[4/17] 校验证书
...
```

- 交互提示青色；成功绿色；警告黄色；错误红色。
- `NO_COLOR=1` 可关闭颜色。

## 无交互安装

直接编辑脚本顶部：

```bash
NON_INTERACTIVE="1"
BASE_DOMAIN="abc.com"
MAIN_SUBDOMAIN="main"
HTTPS_PORT="443"
HTTP_REDIRECT_MODE="main"
IPV6_ENABLE="1"
# 留空时按模板自动生成：
#   /etc/letsencrypt/abc.com/fullchain.cer
#   /etc/letsencrypt/abc.com/abc.com.key
SSL_CERT_PATH=""
SSL_KEY_PATH=""
```

如需手动指定证书路径，也可直接填写：

```bash
NON_INTERACTIVE="1"
BASE_DOMAIN="abc.com"
MAIN_SUBDOMAIN="main"
SSL_CERT_PATH="/etc/letsencrypt/live/abc.com/fullchain.pem"
SSL_KEY_PATH="/etc/letsencrypt/live/abc.com/privkey.pem"
```

然后：

```bash
sudo ./install_nginx.sh --non-interactive
```

## 架构说明

```text
                         ┌──────────────────────────────────────────────┐
                         │                   Nginx                      │
Client                   │                                              │
  │  TCP HTTPS_PORT ────►│  stream: ssl_preread + PROXY protocol        │
  │                      │      ├─ <主域名> ─► MAIN_BACKEND_ADDR:1111    │
  │                      │      └─ default  ─► MAIN_BACKEND_ADDR:1111    │
  │                      │                                              │
  │  UDP HTTP3_PORT ────►│  http/3 (QUIC) 直接终止 TLS（可关闭/改端口）  │
  │                      │      └─ main 主站                            │
  │  TCP HTTP_REDIRECT_PORT ► 301 → HTTPS（可关闭/多模式）               │
                         └──────────────────────────────────────────────┘
```

- 默认只有 `main` 主站生效。
- 其他场景通过模板复制并修改。
- 外部监听默认同时生成 IPv4 和 IPv6。
- 证书统一来自 `/etc/nginx/snippets/ssl.conf`。

## 安装后目录

```text
/etc/nginx/
├── conf/nginx.conf
├── conf.d/
│   ├── main.conf
│   ├── redirect-http.conf
│   ├── ws.conf.example
│   ├── webdav.conf.example
│   ├── reverse-proxy.conf.example
│   └── README.md
├── snippets/
│   ├── ssl.conf
│   ├── proxy-common.conf
│   └── websocket.conf
├── stream.conf.d/stream_sni.conf
└── ssl/dhparam.pem
```

日志：

```text
/var/log/nginx/main_access.log
/var/log/nginx/main_error.log
/var/log/nginx/access.log
/var/log/nginx/error.log
/var/log/nginx/stream_sni.log
```

网站目录：

```text
/var/www/html
/var/www/webdav
```

## 证书说明

- 安装时优先使用证书路径模板：`__BASE_DOMAIN__` 自动替换为基础域名。
- 默认路径：
  - `/etc/letsencrypt/abc.com/fullchain.cer`
  - `/etc/letsencrypt/abc.com/abc.com.key`
- 也可在脚本顶部直接填写固定的证书/私钥绝对路径。
- 证书不会拷贝到 `/etc/nginx`。
- 所有站点与模板统一引用：

```nginx
include /etc/nginx/snippets/ssl.conf;
```

- 校验证书可读、未过期、与私钥匹配、SAN 覆盖主站域名。
- 证书续期后：

```bash
nginx -t && systemctl reload nginx
```

- 证书没有 OCSP URL 时，`OCSP_STAPLING=auto` 会自动关闭 stapling。

## 场景模板

| 模板 | 场景 |
|---|---|
| `ws.conf.example` | WebSocket / 长连接反向代理 |
| `webdav.conf.example` | WebDAV |
| `reverse-proxy.conf.example` | 通用 HTTP 反向代理 |

使用：

```bash
cp /etc/nginx/conf.d/ws.conf.example /etc/nginx/conf.d/ws.conf
vim /etc/nginx/conf.d/ws.conf
```

修改：

1. `server_name`
2. `listen 127.0.0.1:<内部端口>`（内部 IPv6 改为 `[::1]`）
3. `proxy_pass` 或 `root`
4. 日志、超时、上传大小、缓冲区等

模板中的职责划分：

- `snippets/ssl.conf`：证书、私钥、信任链
- `snippets/proxy-common.conf`：HTTP/1.1、转发头、`proxy_redirect off`
- `snippets/websocket.conf`：Upgrade/Connection、关闭缓冲、上游长连接，需在 `proxy-common.conf` 之后 include
- 超时、缓冲区、请求体大小：在各站点模板中独立配置

## stream SNI 接入

复制模板后，在 `/etc/nginx/stream.conf.d/stream_sni.conf` 中增加：

```nginx
# map 内
ws.example.com ws_backend;

# upstream 区域
upstream ws_backend {
    server 127.0.0.1:12001;
    # 内部 IPv6 使用：
    # server [::1]:12001;
}
```

端口必须与模板中的 `listen` 一致。模板内部使用 `[::1]` 时，upstream 也要使用 `[::1]`。

```bash
nginx -t && systemctl reload nginx
```

## HTTP/3 与端口

```bash
HTTP3_ENABLE="0"
HTTP3_PORT="443"
```

- 默认 `HTTP3_ENABLE="0"`：不监听 UDP，避免与其他服务抢占 UDP 端口。
- `HTTP3_ENABLE="1"`：启用 QUIC，额外监听 UDP 端口。
- `HTTP3_PORT="8443"`：QUIC 改用 UDP 8443，`Alt-Svc` 自动跟随。
- 安装前检查目标 UDP 端口占用。
- 若其他 QUIC 应用占用目标 UDP 端口，可关闭 Nginx HTTP/3 或改用其他端口。

## HTTP → HTTPS 跳转

```bash
HTTPS_PORT="443"
HTTP_REDIRECT="1"
HTTP_REDIRECT_PORT="80"
HTTP_REDIRECT_MODE="main"
HTTP_REDIRECT_DOMAINS=""
```

模式：

| 模式 | 行为 |
|---|---|
| `main` | 仅主站域名跳转，其他 Host 返回 444 |
| `base` | 基础域名 + 主站域名跳转，其他 Host 返回 444 |
| `list` | `HTTP_REDIRECT_DOMAINS` 中的域名跳转，其他 Host 返回 444 |
| `all` | 所有 Host 跳转到同名 HTTPS |

- `HTTPS_PORT` 非 443 时，跳转目标自动追加端口，例如 `https://main.abc.com:8443/...`。
- `HTTP_REDIRECT="0"` 时不生成跳转文件。
- `main/base/list` 会生成 `default_server` 兜底并返回 444，避免误跳转。
- `all` 模式使用 `$host`，只在明确接管 HTTP 源端口时使用。

## IPv6

```bash
IPV6_ENABLE="1"
MAIN_BACKEND_ADDR="127.0.0.1"
```

- `IPV6_ENABLE="1"`：stream、HTTP 跳转、HTTP/3 同时监听 IPv4 和 IPv6。
- 所有 IPv6 监听显式使用 `ipv6only=on`。
- 外部 IPv6 客户端默认经 stream 转发到 `MAIN_BACKEND_ADDR` 指定的内部回环地址。
- 需要内部 IPv6 时，将 `MAIN_BACKEND_ADDR` 改为 `"[::1]"`。
- 模板中的内部监听可按注释改为 `[::1]`，并同步修改 `stream_sni.conf` 的 upstream。

## 验证

```bash
sudo /etc/nginx/sbin/nginx -t
sudo systemctl status nginx --no-pager
/etc/nginx/sbin/nginx -V 2>&1 | head -5
curl -kI https://main.abc.com:443/healthz
curl -kI --resolve main.abc.com:443:127.0.0.1 https://main.abc.com:443/healthz
curl -6 -kI --resolve main.abc.com:443:[::1] https://main.abc.com:443/healthz
curl -I http://main.abc.com/
curl --http3 -sI https://main.abc.com:443/healthz
sudo tail -n 100 /var/log/nginx/stream_sni.log
sudo ss -lntup | grep nginx
```

## 卸载

### 交互卸载

```bash
sudo ./install_nginx.sh --uninstall
```

需要输入：

```text
UNINSTALL NGINX
```

### 保留网站数据

```bash
sudo ./install_nginx.sh --uninstall --preserve-www
```

保留：

- `/var/www/html`
- `/var/www/webdav`

### 强制卸载

```bash
sudo ./install_nginx.sh --uninstall --yes
```

### curl 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/<your-org>/<your-repo>/main/install_nginx.sh -o /tmp/install_nginx.sh && sudo bash /tmp/install_nginx.sh --uninstall
```

或直接管道：

```bash
curl -fsSL https://raw.githubusercontent.com/<your-org>/<your-repo>/main/install_nginx.sh | sudo bash -s -- --uninstall
curl -fsSL https://raw.githubusercontent.com/<your-org>/<your-repo>/main/install_nginx.sh | sudo bash -s -- --uninstall --yes
```

### 卸载会删除

- `/etc/nginx`（配置、模板、二进制）
- `/etc/systemd/system/nginx.service`
- `/etc/logrotate.d/nginx`
- `/var/log/nginx`、`/var/lib/nginx`
- `/var/www/html`、`/var/www/webdav`（`--preserve-www` 时保留）
- `/usr/local/src` 下源码与压缩包
- jemalloc 安装产物
- Fail2Ban 模板/规则

### 卸载不会删除

- 证书与私钥
- 其他程序
- `/var/backups/nginx-install-*` 备份

> 如果脚本中 `NON_INTERACTIVE="1"`，交互卸载需要加 `--interactive`，或使用 `--yes`。

## 项目结构

```text
.
├── install_nginx.sh    # 单文件安装/卸载脚本（含全部配置与模板）
├── README.md
├── DEPLOYMENT.md
├── project.md
└── .gitignore
```

## 相关文档

- [部署与排障详解](./DEPLOYMENT.md)
- [设计目标与安全基线](./project.md)

---

生产使用建议：

1. 使用 fullchain 证书，并确保 SAN 覆盖主站域名；
2. 保持 `STRICT_SUPPLYCHAIN="1"`、`STRICT_CERT_SAN="1"`；
3. 在测试环境完成一次安装与卸载回归；
4. 按需启用 Fail2Ban 并接入日志采集。
