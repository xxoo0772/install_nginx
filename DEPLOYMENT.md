# Nginx 部署与运维手册

本脚本是**单文件、无 env 依赖**的安装器：

- 所有配置在脚本顶部
- 组件版本与 SHA256 为显式变量
- 默认交互先询问基础域名，再输入主站子域名；证书路径按模板自动生成
- 单证书、不拷贝证书
- 默认只启用 main 主站
- stream SNI 只监听 443
- 场景模板位于 `/etc/nginx/conf.d/*.conf.example`
- 提供可审计卸载

## 1. 文件说明

| 文件 | 说明 |
|---|---|
| `install_nginx.sh` | 安装、回滚、卸载入口；包含配置、模板与全部逻辑 |
| `README.md` | 快速使用 |
| `DEPLOYMENT.md` | 本部署手册 |
| `project.md` | 设计目标与安全基线 |

## 2. 获取脚本

### 方式一：下载后执行

```bash
curl -fsSL https://raw.githubusercontent.com/<your-org>/<your-repo>/main/install_nginx.sh -o /tmp/install_nginx.sh
sudo bash /tmp/install_nginx.sh
```

### 方式二：直接管道执行

```bash
curl -fsSL https://raw.githubusercontent.com/<your-org>/<your-repo>/main/install_nginx.sh | sudo bash
```

脚本会优先从 `/dev/tty` 读取交互输入，管道方式也能提示。

### 方式三：Git 克隆

```bash
git clone <repository-url> nginx-deploy
cd nginx-deploy
sudo ./install_nginx.sh
```

## 3. 脚本配置

编辑 `install_nginx.sh` 顶部配置块：

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

HTTP_REDIRECT="1"
MAIN_BACKEND_PORT="1111"
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

升级版本时，只改版本号和对应 SHA256 / commit pin。

## 4. 部署前准备

1. 基础域名已解析，例如 `abc.com`
2. 主站子域名已解析，例如 `main.abc.com`
3. 证书与私钥（建议 fullchain）
4. 证书 SAN 覆盖主站域名
5. 防火墙放行：
   - TCP `443`
   - TCP `80`（如启用 80 跳转）
   - UDP `443` 或 `HTTP3_PORT`（仅在启用 HTTP/3 时需要）
6. 确认端口未被其他非 Nginx 程序占用

## 5. 交互安装

```bash
sudo ./install_nginx.sh
```

提示：

```text
请输入基础域名（例如 abc.com）: abc.com
请输入主站子域名（例如 main，最终为 main.abc.com；输入 @ 使用 abc.com）: main
请输入证书路径（回车使用默认值）: /etc/letsencrypt/abc.com/fullchain.cer
请输入私钥路径（回车使用默认值）: /etc/letsencrypt/abc.com/abc.com.key
是否生成 80 → 443 跳转？ [Y/n]
```

- 先输入基础域名，再输入主站子域名，无需输入完整主站域名。
- 证书路径根据模板自动生成，直接回车即可。
- 交互提示青色，成功绿色，警告黄色，错误红色。
- `NO_COLOR=1` 可关闭颜色。

## 6. 无交互安装

编辑脚本顶部：

```bash
NON_INTERACTIVE="1"
BASE_DOMAIN="abc.com"
MAIN_SUBDOMAIN="main"
# 留空时按模板自动生成证书路径
SSL_CERT_PATH=""
SSL_KEY_PATH=""
```

或手动指定证书：

```bash
NON_INTERACTIVE="1"
BASE_DOMAIN="abc.com"
MAIN_SUBDOMAIN="main"
SSL_CERT_PATH="/etc/letsencrypt/live/abc.com/fullchain.pem"
SSL_KEY_PATH="/etc/letsencrypt/live/abc.com/privkey.pem"
```

执行：

```bash
sudo ./install_nginx.sh --non-interactive
```

## 7. 证书说明

安装时只使用一张证书，不拷贝证书。

证书路径支持模板替换：

- `__BASE_DOMAIN__`：基础域名，例如 `abc.com`
- `__PRIMARY_DOMAIN__`：主站完整域名，例如 `main.abc.com`

默认模板：

```bash
SSL_CERT_PATH_TPL="/etc/letsencrypt/__BASE_DOMAIN__/fullchain.cer"
SSL_KEY_PATH_TPL="/etc/letsencrypt/__BASE_DOMAIN__/__BASE_DOMAIN__.key"
```

生成：

```nginx
# /etc/nginx/snippets/ssl.conf
ssl_certificate         <SSL_CERT_PATH>;
ssl_certificate_key     <SSL_KEY_PATH>;
ssl_trusted_certificate <SSL_CERT_PATH>;
```

所有站点和模板统一：

```nginx
include /etc/nginx/snippets/ssl.conf;
```

校验：

- 证书可读
- 私钥可读
- 证书未过期
- 证书与私钥匹配
- SAN/CN 覆盖主站域名

续期后：

```bash
nginx -t && systemctl reload nginx
```

无 OCSP URL 时，`OCSP_STAPLING="auto"` 自动关闭 stapling。

## 8. 安装后目录

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

## 9. 场景模板

| 模板 | 场景 |
|---|---|
| `ws.conf.example` | WebSocket / 长连接反向代理 |
| `webdav.conf.example` | WebDAV |
| `reverse-proxy.conf.example` | 通用 HTTP 反向代理 |

```bash
cp /etc/nginx/conf.d/ws.conf.example /etc/nginx/conf.d/ws.conf
vim /etc/nginx/conf.d/ws.conf
```

修改：

1. `server_name`
2. `listen 127.0.0.1:<端口>`
3. `proxy_pass` 或 `root`
4. 日志、超时、上传大小、限速等

`.conf.example` 不会被 `conf.d/*.conf` 自动加载。

## 10. 接入 stream SNI

在 `/etc/nginx/stream.conf.d/stream_sni.conf` 增加：

```nginx
# map 内
ws.example.com ws_backend;

# upstream 区域
upstream ws_backend {
    server 127.0.0.1:12001;
}
```

端口必须与模板中的 `listen` 一致。

```bash
nginx -t && systemctl reload nginx
tail -n 100 /var/log/nginx/stream_sni.log
```

## 11. HTTP/3

```bash
HTTP3_ENABLE="0"
HTTP3_PORT="443"
```

- 默认关闭，不监听 UDP，避免与其他服务抢占 UDP/443
- `HTTP3_ENABLE="1"`：启用 QUIC，额外监听 UDP
- `HTTP3_PORT="8443"`：QUIC 改用 UDP 8443，`Alt-Svc` 自动跟随
- 安装前检查 UDP 端口占用
- 其他 QUIC 应用占用 443/udp 时，可关闭 Nginx HTTP/3 或改端口

## 12. 80 → 443 跳转

默认生成：

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name <主域名>;
    return 301 https://$host$request_uri;
}
```

关闭：

```bash
HTTP_REDIRECT="0"
```

或删除 `/etc/nginx/conf.d/redirect-http.conf` 后 reload。

## 13. 验证

```bash
sudo /etc/nginx/sbin/nginx -t
sudo systemctl status nginx --no-pager
/etc/nginx/sbin/nginx -V 2>&1 | head -5
curl -kI https://main.abc.com/healthz
curl --http3 -sI https://main.abc.com/healthz
sudo ss -lntup | grep nginx
```

## 14. 卸载

### 交互卸载

```bash
sudo ./install_nginx.sh --uninstall
```

输入确认短语：

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

- `/etc/nginx`
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

## 15. 备份与回滚

安装前若已存在 Nginx：

```text
/var/backups/nginx-install-<YYYYmmdd-HHMMSS>/
├── etc-nginx/
├── nginx.service
└── logrotate-nginx
```

- 安装失败且此前存在 Nginx：从备份恢复。
- 安装失败且此前不存在：清理本次产物。
- 保留现场：`ROLLBACK_ON_ERROR="0"`。

## 16. 常见问题

### 16.1 证书 SAN 未覆盖主域名

处理：

- 使用覆盖该域名的证书；
- 或使用通配符证书；
- 测试环境可设置 `STRICT_CERT_SAN="0"`。

### 16.2 端口被占用

```bash
sudo ss -lntup | grep -E ':(80|443|1111|8443)\b'
```

处理：

- 释放端口；
- 或调整 `MAIN_BACKEND_PORT`；
- HTTP/3 可设置 `HTTP3_ENABLE="0"` 或 `HTTP3_PORT="8443"`。

### 16.3 `bind() to 127.0.0.1:1111 failed`

脚本会在启动前安全停止旧 Nginx，并再次检查端口。
如仍失败：

```bash
sudo ss -lntp 'sport = :1111'
```

### 16.4 `ssl_stapling ignored, no OCSP responder URL`

这是告警，不是启动失败原因。

- 默认 `OCSP_STAPLING="auto"` 会自动关闭；
- 也可设置 `"off"`。

### 16.5 模板没有被加载

`.conf.example` 不会加载，复制为 `.conf`：

```bash
cp /etc/nginx/conf.d/ws.conf.example /etc/nginx/conf.d/ws.conf
```

### 16.6 新增站点后 SNI 不生效

检查 `/etc/nginx/stream.conf.d/stream_sni.conf`：

- map 中是否有该域名
- upstream 端口是否与模板 `listen` 一致
- 是否执行 `nginx -t && systemctl reload nginx`

### 16.7 没有 journald 日志

Debian 13 最小化系统可能没有 `/dev/log`，脚本会自动跳过 syslog 通道，仅保留文件日志。

## 17. 升级与校验

### 17.1 升级版本

1. 编辑脚本顶部版本号；
2. 同步更新对应 SHA256 / commit pin；
3. 在测试环境重新安装验证；
4. 确认 `nginx -V` 输出目标版本与 `built with OpenSSL 3.5.x`。

### 17.2 静态校验

```bash
bash -n install_nginx.sh
shellcheck -S warning install_nginx.sh
```

### 17.3 运行期校验

```bash
sudo /etc/nginx/sbin/nginx -t
sudo ss -lntup | grep nginx
sudo tail -n 100 /var/log/nginx/error.log
```
