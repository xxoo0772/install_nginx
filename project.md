# 项目设计：企业级 Nginx 编译部署

## 1. 目标

提供一个**单文件**、可直接下载执行的 Nginx 源码编译安装脚本：

- 无 env 文件
- 配置、版本、SHA256、模板全部在脚本内
- 默认交互安装
- 单证书、不拷贝证书
- 默认只启用 main 主站
- 保留 stream SNI（仅 443）
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

同时定义各组件的 SHA256 / commit pin。
升级时直接编辑顶部变量即可。

## 3. 架构

```text
客户端
  ├─ TCP 443 → stream（ssl_preread + PROXY protocol）
  │     ├─ 主域名 → 127.0.0.1:1111（main）
  │     └─ default → 127.0.0.1:1111（main）
  ├─ UDP 443 → HTTP/3（QUIC，可关闭或改端口）
  └─ TCP 80  → 301 到 HTTPS（可关闭）
```

- 默认只启用 `main` 主站。
- 其他场景通过 `/etc/nginx/conf.d/*.conf.example` 模板提供。
- 模板复制为 `.conf` 后，需要在 `stream_sni.conf` 中增加 map/upstream。

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
3. 证书路径（默认按模板自动生成，可直接回车）
4. 私钥路径（默认按模板自动生成，可直接回车）
5. 是否生成 80 → 443 跳转

无交互：

- 编辑脚本顶部：
  - `NON_INTERACTIVE="1"`
  - `BASE_DOMAIN`
  - `MAIN_SUBDOMAIN`（默认 `main`）
  - `SSL_CERT_PATH_TPL` / `SSL_KEY_PATH_TPL`（按 `__BASE_DOMAIN__` 自动替换）
  - 或直接填写 `SSL_CERT_PATH` / `SSL_KEY_PATH`

缺失时交互模式会提示；无交互模式直接报错。

## 6. 配置模板

脚本内嵌生成：

生效文件：

- `conf.d/main.conf`
- `conf.d/redirect-http.conf`
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

## 7. 安全基线

- 供应链：HTTPS + SHA256 + commit pin，严格模式缺值即拒绝。
- 证书：有效期、私钥匹配、SAN/CN 覆盖校验。
- 传输：TLS 1.2/1.3、仅 ECDHE、禁用会话票据、禁用 0-RTT。
- 响应头：HSTS、CSP（无 `unsafe-inline`）、X-Frame-Options、nosniff、Referrer-Policy、Permissions-Policy。
- 真实 IP：stream PROXY protocol + `real_ip_header proxy_protocol`。
- WebDAV 模板：Basic Auth、DAV/扩展方法、锁、限流、连接限制、`auth_delay`。
- systemd 沙箱：`ProtectSystem=strict`、`PrivateTmp`、`NoNewPrivileges`、最小能力集等。
- 可审计：文件日志 + journald（存在 `/dev/log` 时）+ logrotate。
- 变更安全：安装前备份、失败回滚、严格卸载确认。

## 8. 卸载

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

## 9. 性能基线

- `worker_processes auto` + `worker_rlimit_nofile 65535`
- `sendfile` / `tcp_nopush` / `tcp_nodelay`
- `open_file_cache`
- `aio threads`
- HTTP/2 复用 + `ssl_session_cache`
- jemalloc 降低内存碎片
- stream `proxy_timeout 1h`
- WebDAV 模板读写分层限速

## 10. 产出文件

- `install_nginx.sh`（单文件，含配置、模板、卸载逻辑）
- `README.md`
- `DEPLOYMENT.md`
- `project.md`
- `.gitignore`

## 11. 变更记录

- 2026-11: 单文件重写。
  - 取消 env 文件，配置直接写在脚本顶部。
  - 组件版本与 SHA256 作为显式变量，便于升级。
  - 内嵌全部配置与场景模板，支持 curl 直接执行。
  - 主站统一命名 `main`。
  - 单证书、不拷贝证书。
  - 默认交互；彩色提示与步骤编号。
  - 模板去重：`ws`、`webdav`、`reverse-proxy`。
  - stream SNI 仅监听 443。
  - 保留并强化卸载功能。
