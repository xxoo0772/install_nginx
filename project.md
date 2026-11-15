# 项目设计：企业级 Nginx 编译部署

## 1. 目标

提供一个**单文件**、可直接下载执行的 Nginx 源码编译安装脚本：

- 无 env 文件
- 配置、版本、SHA256、模板全部在脚本内
- 默认交互安装
- 单证书、不拷贝证书
- 默认只启用 main 主站
- 保留 stream SNI
- 支持 IPv4/IPv6 双栈
- 提供可审计卸载

## 2. 核心参数

脚本顶部集中定义：

- Nginx: `1.31.8`
- OpenSSL: `3.5.9`
- jemalloc: `5.4.0`
- ngx-fancyindex: `0.6.0`
- nginx-dav-ext-module: `3.0.0`
- headers-more-nginx-module: `0.41`
- ngx_brotli: `v1.0.0rc`（commit pin）

同时定义各组件的 SHA256 / commit pin。版本与校验值集中维护。

## 3. 架构

```text
客户端
  ├─ TCP HTTPS_PORT → stream（ssl_preread + PROXY protocol）
  │     ├─ 主域名 → MAIN_BACKEND_ADDR:1111（main）
  │     └─ default → MAIN_BACKEND_ADDR:1111（main）
  ├─ UDP HTTP3_PORT → HTTP/3（QUIC，可关闭或改端口）
  └─ TCP HTTP_REDIRECT_PORT → 301 到 HTTPS（可关闭）
```

- 默认只启用 `main` 主站。
- 其他场景通过 `/etc/nginx/conf.d/*.conf.example` 模板提供。
- 模板复制为 `.conf` 后，需要在 `stream_sni.conf` 中增加 map/upstream。
- 外部监听默认同时生成 IPv4 和 IPv6。
- 内部回环默认使用 `127.0.0.1`，可通过 `MAIN_BACKEND_ADDR` 改为 `[::1]`。

## 4. 证书模型

- 证书/私钥路径支持模板，按基础域名自动替换，安装时可回车采用默认值。
- 不拷贝证书，不修改证书权限。
- 生成 `/etc/nginx/snippets/ssl.conf`，所有站点和模板统一 include。
- 校验证书可读、未过期、与私钥匹配、SAN 覆盖主域名。
- `OCSP_STAPLING="auto"` 时按证书是否含 OCSP URL 自动启停 stapling。

## 5. 安装输入

默认交互：

1. 基础域名（例如 `abc.com`）
2. 主站子域名（例如 `main`，自动拼接为 `main.abc.com`；`@` 表示使用根域名）
3. 对外 HTTPS 端口
4. 证书路径（默认按模板自动生成，可直接回车）
5. 私钥路径（默认按模板自动生成，可直接回车）
6. 是否生成 HTTP → HTTPS 跳转
7. 跳转模式、源端口；`list` 模式继续询问域名列表

无交互：

- 编辑脚本顶部：
  - `NON_INTERACTIVE="1"`
  - `BASE_DOMAIN`
  - `MAIN_SUBDOMAIN`（默认 `main`）
  - `SSL_CERT_PATH_TPL` / `SSL_KEY_PATH_TPL`（按 `__BASE_DOMAIN__` 自动替换）
  - 或直接填写 `SSL_CERT_PATH` / `SSL_KEY_PATH`
  - 按需填写 `HTTPS_PORT`、`HTTP_REDIRECT_*`、`IPV6_ENABLE`

缺失时交互模式会提示；无交互模式直接报错。

## 6. 配置模板

脚本内嵌生成：

生效文件：

- `conf.d/main.conf`
- `conf.d/redirect-http.conf`（`HTTP_REDIRECT=1` 时）
- `stream.conf.d/stream_sni.conf`
- `snippets/ssl.conf`
- `snippets/proxy-common.conf`
- `snippets/websocket.conf`

场景模板：

- `conf.d/ws.conf.example`
- `conf.d/webdav.conf.example`
- `conf.d/reverse-proxy.conf.example`
- `conf.d/README.md`

原则：

- 模板按 nginx 常见配置场景命名。
- 不写具体业务名称。
- 带中文注释和常用选项。
- `.conf.example` 不会被自动加载。
- 统一引用 `snippets/ssl.conf`。
- 公共 snippet 只保留跨场景通用项。
- 超时、缓冲区、请求体大小在站点模板中独立配置。
- 同一上下文内同一指令只出现一次。

## 7. HTTP → HTTPS 跳转

配置项：

- `HTTPS_PORT`：对外 HTTPS/TLS 端口，也是跳转目标端口
- `HTTP_REDIRECT`：0 关闭，1 生成
- `HTTP_REDIRECT_MODE`：`main` / `base` / `list` / `all`
- `HTTP_REDIRECT_PORT`：跳转源端口
- `HTTP_REDIRECT_DOMAINS`：`list` 模式域名列表

行为：

- `main`：仅主站域名跳转，其他 Host 返回 444
- `base`：基础域名 + 主站域名跳转，其他 Host 返回 444
- `list`：列表内域名跳转，其他 Host 返回 444
- `all`：所有 Host 跳转到同名 HTTPS
- `HTTPS_PORT` 非 443 时，跳转目标自动追加端口

## 8. 安全基线

- 供应链：HTTPS + SHA256 + commit pin，严格模式缺值即拒绝。
- 证书：有效期、私钥匹配、SAN/CN 覆盖校验。
- 传输：TLS 1.2/1.3、仅 ECDHE、禁用会话票据、禁用 0-RTT。
- 响应头：HSTS、CSP（无 `unsafe-inline`）、X-Frame-Options、nosniff、Referrer-Policy、Permissions-Policy。
- 真实 IP：stream PROXY protocol + `real_ip_header proxy_protocol`，同时识别 IPv4/IPv6 回环。
- WebDAV 模板：Basic Auth、DAV/扩展方法、锁、限流、连接限制、`auth_delay`。
- systemd 沙箱：`ProtectSystem=strict`、`PrivateTmp`、`NoNewPrivileges`、最小能力集等。
- 可审计：文件日志 + journald（存在 `/dev/log` 时）+ logrotate。
- 操作安全：安装前备份、失败回滚、严格卸载确认。

## 9. 卸载

支持：

```bash
./install_nginx.sh --uninstall
./install_nginx.sh --uninstall --preserve-www
./install_nginx.sh --uninstall --yes
```

- 默认要求输入 `UNINSTALL NGINX`。
- `--preserve-www` 保留 `/var/www/html`、`/var/www/webdav`。
- 不删除证书和私钥。
- 不删除 `/var/backups/nginx-install-*` 备份。

## 10. 性能基线

- `worker_processes auto` + `worker_rlimit_nofile 65535`
- `sendfile` / `tcp_nopush` / `tcp_nodelay`
- `open_file_cache`
- `aio threads`
- HTTP/2 复用 + `ssl_session_cache`
- jemalloc 降低内存碎片
- stream `proxy_timeout 1h`
- WebDAV 模板读写分层限速

## 11. 产出文件

- `install_nginx.sh`（单文件，含配置、模板、卸载逻辑）
- `README.md`
- `DEPLOYMENT.md`
- `project.md`
- `.gitignore`
