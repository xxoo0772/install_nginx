# 角色要求
你是一位资深 Linux 运维工程师与安全专家，精通 Shell 脚本编写和 Nginx 企业级编译部署。

# 任务目标
编写并维护一个一键从源码编译安装 Nginx 的 Bash 脚本，满足企业级生产安全基线与可运维性要求。

# 核心参数与版本要求
- Nginx: `1.31.8`
- jemalloc: `5.4.0`
- ngx-fancyindex: `0.6.0`
- nginx-dav-ext-module: `3.0.0`
- headers-more-nginx-module: `0.41`
- TLS 库: OpenSSL `3.5.9`（官方 3.5 LTS，原生服务端 QUIC）
- 压缩模块: `ngx_brotli`（`v1.0.0rc`，commit pin）
- 源码目录: `/usr/local/src`
- 安装前缀: `--prefix=/etc/nginx`
- 说明：上述为脚本默认版本，可通过环境变量覆盖。旧版 `quictls/openssl` 已于 2025-04 归档，本项目改用官方 OpenSSL 3.5 LTS；如覆盖版本，必须同步更新 SHA256 / commit pin（脚本会输出时效性告警）。

# 系统兼容与执行条件
- Debian 11+/13（优先）
- 强制 Root 检查
- 自动创建/复用 `www-data`
- 自动识别 CPU 线程并 `make -j`

# 编译与脚本工程要求
- `./configure` 参数必须使用 Bash 数组：`./configure "${CONF_ARGS[@]}"`
- 必须启用：HTTP/2、HTTP/3、SSL、RealIP、Stub Status、WebDAV、Stream、Stream SSL、Stream SSL Preread
- 使用 `set -Eeuo pipefail`，统一错误处理与彩色状态输出
- 配置文件生成必须使用 `cat <<'EOF'` 防变量误展开

# 企业级安全基线（必须）
1. 供应链安全
- 下载必须使用 HTTPS
- Tarball 必须支持 SHA256 校验
- Git 仓库必须支持 commit pin
- 严格模式下（`STRICT_SUPPLYCHAIN=1`）缺失校验值必须拒绝执行

2. 真实客户端 IP 与防滥用
- stream 层启用 `proxy_protocol on`
- http/server 层启用 `real_ip_header proxy_protocol`
- 必须确保限速与审计使用真实来源 IP
- 混合架构要求：
- `MAIN/TUN（Tunnel）` 走 `stream` SNI 分流
- `API/WebDAV` 走 `web_mux`（同一内网端口）并由 `server_name` 做 L7 分流
- TUN（Tunnel）站点需提供 `location /vless` 反代入口与 `/healthz` 健康检查

3. WebDAV 防暴力破解
- Nginx 侧：`webdav_auth_limit(limit_req)` + `limit_conn` + `auth_delay`（不依赖 fail2ban 也要生效）
- 系统侧：输出 Fail2Ban 配置模板（不自动安装/启动），基于 `dav_access.log` 的 401 失败封禁

4. TLS 与安全头
- TLS 1.2/1.3，强化 cipher，禁用会话票据
- 禁用 TLS 1.3 0-RTT（与 `ssl_session_tickets off` 保持一致，规避重放风险）
- 开启 OCSP stapling（证书需含完整中间链）
- 开启 HSTS、CSP（禁止 `unsafe-inline`）、X-Frame-Options、X-Content-Type-Options、Referrer-Policy、Permissions-Policy
- 支持 HTTP/3：QUIC 直连 UDP 443 + `Alt-Svc`（与 stream TCP SNI 分流并存）

5. systemd 沙箱
- `ProtectSystem=strict`、`ProtectHome=true`、`PrivateTmp=true`、`NoNewPrivileges=true`
- 最小能力集 + 仅允许必要目录写入（日志、运行态、站点目录）
- 具备 `RestrictRealtime`、`SystemCallArchitectures=native`、`RemoveIPC` 等额外加固

6. 日志策略（企业生产）
- 持久化日志输出到 `/var/log/nginx/`
- 存在 `/dev/log` 时同时输出到 journald（syslog unix socket）；不存在时自动降级为仅文件日志
- 自动生成 `/etc/logrotate.d/nginx`（按天轮转、保留 14 天、`USR1` 触发重开日志）

7. 证书与变更安全
- 导入前校验证书可解析、未过期、证书与私钥匹配
- 校验证书 SAN/CN 覆盖目标域名（支持通配符）；`STRICT_CERT_SAN=1` 时不覆盖即拒绝执行
- 安装前若已存在 Nginx，自动备份 `/etc/nginx` 与 systemd 单元
- 安装失败回滚时：若此前已有安装则从备份恢复；否则清理本次产物
- 停止服务使用 pidfile 安全停止，禁止 `pkill -9 nginx` 误杀无关进程

8. 版本时效性
- 版本号支持环境变量覆盖（`NGINX_VER`、`OPENSSL_VER`、`NGX_BROTLI_REF` 等）
- 检测到 Nginx < 1.29 或 OpenSSL < 3.5 时输出告警，并提示同步更新 SHA256 / commit pin

# 产出文件要求
- 脚本: `install_nginx.sh`
- 项目说明: `project.md`
- 项目总览: `README.md`（GitHub 格式，包含使用方法与文档入口）
- 部署说明: `DEPLOYMENT.md`（必须包含完整命令示例、交互与非交互用法、常见故障排查）
- 卸载能力: 脚本必须提供可审计的 `--uninstall` 选项，默认二次确认并输出风险警告
- 数据保护卸载: 必须支持 `--uninstall --preserve-www`，仅卸载 Nginx 并保留 `/var/www` 数据
- 一致性保障: 安装流程中断时必须自动回滚（默认启用），避免残留导致重复安装冲突

# 架构与模块说明
- `install_nginx.sh`: 唯一执行体，负责前置校验 → 参数采集/证书校验 → 备份 → 依赖安装 → 源码校验/编译 → 配置生成 → 服务注册 → 启动 → 清理
- `nginx-build.env`: 供应链校验值、版本覆盖、域名、证书路径、限流/Fail2Ban 参数
- 运行链路: 客户端 → stream TCP SNI 分流（主站/TUN（Tunnel）/web_mux）→ 本地 TLS 终止；HTTP/3 走 UDP 443 直连终止
- 真实 IP: stream 向下游发送 PROXY protocol，http 层 `real_ip_header proxy_protocol` 还原
- 模块: `http_ssl/http_v2/http_v3`、`http_realip`、`http_stub_status`、`http_dav` + `dav-ext`、`stream/stream_ssl/stream_ssl_preread`、`ngx_brotli`、`headers-more`、`ngx-fancyindex`、`jemalloc`

# 性能基线
- `worker_processes auto` + `worker_rlimit_nofile 65535` + `reuseport`
- `open_file_cache`、`aio threads`、`sendfile/tcp_nopush/tcp_nodelay`
- WebDAV 读写分层限速（读 180r/m、写 30r/m、认证 120r/m），避免同步客户端被误伤
- stream `proxy_timeout 1h`，避免切断 TUN（Tunnel）/WebSocket 长连接
- `http2` 复用 + `ssl_session_cache` + jemalloc 降低内存碎片

# 变更记录
- 2026-11: 增加证书 SAN/有效期/密钥匹配校验；安装前备份与回滚恢复；HTTP/3 QUIC 监听 + Alt-Svc；移除失效的 0-RTT 配置；CSP 去 `unsafe-inline`；开启 OCSP stapling；WebDAV 限速分层；stream 长连接超时；logrotate；`/dev/log` 探测；systemd 额外加固；版本可覆盖与时效性告警。
- 2026-11: TLS 供应链迁移：quictls（已归档）→ 官方 OpenSSL 3.5.9 LTS；Nginx 升级到 1.31.8；jemalloc 5.4.0；fancyindex 0.6.0；headers-more 0.41；ngx_brotli 固定到 v1.0.0rc commit；新增 commit 精确抓取与回退逻辑。
