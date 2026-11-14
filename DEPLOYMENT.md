# Nginx 企业级部署文档

## 1. 文件说明
- `/opt/nginx-deploy/install_nginx.sh`：一键编译部署脚本
- `/opt/nginx-deploy/nginx-build.env`：供应链校验与部署变量

> 以上路径为示例。如果你当前工程在其他目录，请替换为实际路径。

## 2. 推荐部署前准备
1. 准备域名与 DNS 解析（主站、WebDAV、API、TUN（Tunnel））
2. 准备证书与私钥（建议全链证书）
3. 确认证书 SAN/CN 覆盖全部目标域名（支持通配符），且证书与私钥匹配、未过期
4. 准备环境变量文件（哈希与 commit pin）
5. 防火墙放行：TCP `443/2096/2099/8443`、UDP `443`（HTTP/3）、以及 stream 分流所需的 TCP 端口

## 3. 环境变量文件示例
```bash
STRICT_SUPPLYCHAIN=1
# 证书 SAN 严格校验：SAN 未覆盖目标域名时拒绝执行
STRICT_CERT_SAN=1

# 可选：版本覆盖（升级后必须同步更新下方哈希/commit）
# NGINX_VER=1.31.8
# JEMALLOC_VER=5.4.0
# FANCYINDEX_VER=0.6.0
# DAV_EXT_VER=3.0.0
# HEADERS_MORE_VER=0.41
# OPENSSL_VER=3.5.9
# NGX_BROTLI_REF=v1.0.0rc

NGINX_TARBALL_SHA256=<fill>
OPENSSL_TARBALL_SHA256=<fill>
JEMALLOC_TARBALL_SHA256=<fill>
FANCYINDEX_TARBALL_SHA256=<fill>
DAV_EXT_TARBALL_SHA256=<fill>
HEADERS_MORE_TARBALL_SHA256=<fill>

NGX_BROTLI_COMMIT=<fill>

# 部署模式
NON_INTERACTIVE=1

# 域名
MAIN_DOMAIN=main.abc.com
DAV_DOMAIN=dav.abc.com
API_DOMAIN=api.abc.com
TUN_DOMAIN=tun.abc.com

# 主站证书（示例：Let's Encrypt 通配符证书目录）
MAIN_CERT_SRC=/etc/letsencrypt/live/abc.com/fullchain.pem
MAIN_KEY_SRC=/etc/letsencrypt/live/abc.com/privkey.pem

# 子站证书（可留空并启用复用）
DAV_CERT_SRC=
DAV_KEY_SRC=
API_CERT_SRC=
API_KEY_SRC=
TUN_CERT_SRC=
TUN_KEY_SRC=

# 复用主站证书策略
DAV_REUSE_MAIN_CERT=1
API_REUSE_MAIN_CERT=1
TUN_REUSE_MAIN_CERT=1

# TUN（Tunnel）/vless 反代上游地址
VLESS_UPSTREAM=http://127.0.0.1:10000

# 可选：fail2ban 防暴力破解参数
ENABLE_FAIL2BAN_TEMPLATE=1
F2B_MAXRETRY=6
F2B_FINDTIME=10m
F2B_BANTIME=12h
F2B_IGNOREIP="127.0.0.1/8 ::1"

# 安装失败回滚
ROLLBACK_ON_ERROR=1

# 安装成功后自动清理编译临时文件
CLEAN_BUILD_ARTIFACTS=1
```

## 4. 交互式部署（推荐首次）
```bash
# env 中默认 NON_INTERACTIVE=1；交互模式显式覆盖为 0
sudo bash -c 'set -a; source /opt/nginx-deploy/nginx-build.env; set +a; NON_INTERACTIVE=0 /opt/nginx-deploy/install_nginx.sh'
```
脚本会交互询问：
- 主站域名
- WebDAV 域名
- API 域名
- TUN（Tunnel）域名
- 四个站点的证书与私钥路径（可按提示复用）

## 5. 非交互部署（自动化/批量）
```bash
sudo bash -c 'set -a; source /opt/nginx-deploy/nginx-build.env; set +a; /opt/nginx-deploy/install_nginx.sh'
```
说明：
- 若 `DAV_REUSE_MAIN_CERT=1` 且 `DAV_CERT_SRC/DAV_KEY_SRC` 留空，将自动复用主站证书。
- 若 `API_REUSE_MAIN_CERT=1` 且 `API_CERT_SRC/API_KEY_SRC` 留空，将自动复用主站证书。
- 若关闭复用（设为 `0`），则必须显式提供对应证书路径。
- 导入前会校验证书可解析、未过期、与私钥匹配，以及 SAN/CN 是否覆盖目标域名；不满足时 `STRICT_CERT_SAN=1` 直接终止。
- 若系统已存在 Nginx，脚本会先备份 `/etc/nginx` 与 systemd 单元到 `/var/backups/nginx-install-<时间戳>/`。
- 版本过期（Nginx < 1.29 或 OpenSSL < 3.5）时脚本会输出时效性告警，请按“升级与校验”章节处理。
- 默认 TLS 库为官方 OpenSSL 3.5.9 LTS；旧 quictls 分支已归档，不再使用。

## 5.1 干净卸载（高风险操作）
```bash
# 交互确认卸载（推荐）
sudo /opt/nginx-deploy/install_nginx.sh --uninstall

# 仅卸载 Nginx，保留网站数据目录 /var/www/*
sudo /opt/nginx-deploy/install_nginx.sh --uninstall --preserve-www

# 非交互强制卸载（谨慎）
sudo NON_INTERACTIVE=1 FORCE_UNINSTALL=1 /opt/nginx-deploy/install_nginx.sh --uninstall --yes
```

卸载会删除：
- `/etc/nginx`（配置与二进制）
- `/etc/systemd/system/nginx.service`
- `/etc/logrotate.d/nginx`
- `/var/log/nginx`、`/var/lib/nginx`
- `/var/www/html`、`/var/www/dav`
- `/usr/local/src` 下本脚本下载与解压的源码产物
- `jemalloc` 相关安装产物（`/usr/local/lib/libjemalloc*` 等）
- Fail2Ban 的 nginx-webdav 模板/规则文件（若存在）

如使用 `--preserve-www`，会保留：
- `/var/www/html`
- `/var/www/dav`

## 6. 部署成功后验证
```bash
# 服务状态
sudo systemctl status nginx --no-pager

# 配置检查
sudo /etc/nginx/sbin/nginx -t -e /var/log/nginx/error.log -c /etc/nginx/conf/nginx.conf

# 版本与 TLS 库核对（应显示 nginx/1.31.8 + OpenSSL 3.5.9）
/etc/nginx/sbin/nginx -V 2>&1 | head -5

# 健康检查（按你的实际域名）
curl -kI https://main.abc.com/healthz
curl -kI https://dav.abc.com/healthz
curl -kI https://api.abc.com/healthz
curl -kI https://tun.abc.com/healthz
curl -kI https://tun.abc.com/vless

# HTTP/3 验证（curl 需支持 --http3，且 UDP 443 已放行）
curl --http3 -sI https://main.abc.com/healthz

# 证书与私钥匹配 / SAN 检查
openssl x509 -in /etc/nginx/ssl/main.abc.com.crt -noout -subject -text | grep -A1 "Subject Alternative Name"
openssl x509 -in /etc/nginx/ssl/main.abc.com.crt -noout -pubkey | openssl pkey -pubin -outform PEM | openssl dgst -sha256
openssl pkey -in /etc/nginx/ssl/main.abc.com.key -pubout -outform PEM | openssl dgst -sha256

# OCSP stapling 检查（证书需含中间链）
echo | openssl s_client -connect main.abc.com:443 -servername main.abc.com -status 2>/dev/null | grep -A2 "OCSP response"

# 日志轮转策略
sudo logrotate -d /etc/logrotate.d/nginx

# journald 日志检查（Debian 13 推荐）
sudo journalctl -u nginx --since "10 min ago" --no-pager

# SNI 分流命中检查（关键）
sudo tail -n 100 /var/log/nginx/stream_sni.log
```

## 7. 日志与持久化
- Nginx 日志目录：`/var/log/nginx/`
- 关键日志：
  - `/var/log/nginx/error.log`
  - `/var/log/nginx/access.log`
  - `/var/log/nginx/dav_access.log`
  - `/var/log/nginx/dav_error.log`

可直接接入远端日志采集系统（rsyslog/filebeat/vector/fluent-bit）。

脚本默认开启双通道日志：
- 文件：`/var/log/nginx/*.log`
- journald：`/dev/log` 存在时启用；不存在时自动降级为仅文件日志（不会阻断启动）
- 轮转：`/etc/logrotate.d/nginx`（daily、保留 14 天、`compress`、`USR1` 重开日志）

## 8. 常见问题排查
1. `Permission denied`（日志或临时目录）
```bash
sudo systemctl cat nginx
sudo ls -ld /var/log/nginx /var/lib/nginx /var/lib/nginx/*
sudo namei -l /var/log/nginx/error.log
```

1.1 `api/dav` 未命中正确站点（都落到主站）
```bash
sudo tail -n 200 /var/log/nginx/stream_sni.log
```
检查日志里的：
- `sni="..."` 是否为你期望域名
- `backend="proxy_main|proxy_tun|proxy_web_mux"` 是否正确

如果 `sni` 始终是同一个主域名，说明上游链路（如 CDN/代理）没有把原始 SNI 传到源站，stream 按域名分流天然会失效。

2. `strict supply chain` 校验失败
- 检查 env 文件哈希值是否完整、是否与下载文件对应版本一致

2.1 安装中断后的自动回滚
- 脚本默认开启安装失败自动回滚（`ROLLBACK_ON_ERROR=1`）
- 若安装前**已存在 Nginx**：回滚会从 `/var/backups/nginx-install-<时间戳>/` 恢复 `/etc/nginx` 与 systemd 单元
- 若安装前**不存在 Nginx**：回滚会清理本次生成产物，回到“未安装”状态
- 如需排错保留现场，可临时设置：`ROLLBACK_ON_ERROR=0`

3. 证书相关错误
- 确认路径与权限
- 私钥应为 `root:root 600`
- 证书应为 `root:root 644`
- 脚本会校验证书有效期、证书与私钥匹配、SAN/CN 是否覆盖目标域名
- 复用主站证书时，务必确认该证书覆盖 `dav/api/tun` 子域（或为通配符证书）；否则设置 `STRICT_CERT_SAN=0` 仅告警（不推荐）

3.1 HTTP/3 不生效
- 确认防火墙放行 **UDP 443**
- 确认客户端支持 HTTP/3（`curl --http3`）
- 检查响应头是否包含 `Alt-Svc: h3=":443"`
- 若位于 CDN/LB 之后，需由该层支持并转发 QUIC，或直连源站验证

3.2 WebDAV 同步客户端频繁 429
- 读请求限速为 180r/m、写方法 30r/m、认证层 120r/m；如仍不足，可调整 `nginx.conf` 中 `webdav_read/webdav_write/webdav_auth_limit`
- 检查是否为共享出口 IP 导致多用户共用一个限速键

3.3 无 journald 日志
- Debian 13 最小化系统可能没有 `/dev/log`；脚本会跳过 syslog 通道，仅保留文件日志
- 如需 journald，确认 `systemd-journald` 正常运行且 `/dev/log` socket 存在

4. Fail2Ban 模板启用（脚本不自动安装 fail2ban）
```bash
sudo apt-get update && sudo apt-get install -y fail2ban
sudo cp /etc/nginx/security/fail2ban/filter.d/nginx-webdav-auth.conf /etc/fail2ban/filter.d/
sudo cp /etc/nginx/security/fail2ban/jail.d/nginx-webdav-auth.local /etc/fail2ban/jail.d/
sudo systemctl restart fail2ban
sudo fail2ban-client status nginx-webdav-auth
```

## 9. 安全基线摘要
- 供应链校验（SHA256 + commit pin，严格模式缺值即拒绝）
- TLS 供应链：官方 OpenSSL 3.5.9 LTS（原生服务端 QUIC），不再依赖已归档的 quictls
- 证书 SAN/有效期/密钥匹配校验（`STRICT_CERT_SAN`）
- stream + proxy_protocol + real_ip；stream 长连接超时 1h
- HTTP/3：QUIC UDP 443 + `Alt-Svc`；禁用 0-RTT
- WebDAV 读写分层限速 + `limit_conn` + `auth_delay` + fail2ban 模板
- systemd 沙箱最小权限（含 `RestrictRealtime`、`SystemCallArchitectures=native`、`RemoveIPC`）
- TLS 强化、OCSP stapling、HSTS、CSP（无 `unsafe-inline`）、Permissions-Policy
- 安装前备份 + 失败回滚恢复；pidfile 安全停止
- 日志双通道（按 `/dev/log` 自动降级）+ logrotate

## 10. 升级与校验
### 10.1 升级版本
1. 修改 env 中 `NGINX_VER` / `OPENSSL_VER` / `NGX_BROTLI_REF`（及需要时的 jemalloc/模块版本）
2. **同步更新对应 SHA256 与 commit pin**，否则 `STRICT_SUPPLYCHAIN=1` 会拒绝执行
3. 重新执行安装；脚本会先备份现有 `/etc/nginx`
4. 启动后执行第 6 节验证

> 本项目已从已归档的 quictls 迁移到官方 OpenSSL 3.5 LTS（原生服务端 QUIC）。
> 默认版本：Nginx `1.31.8`、OpenSSL `3.5.9`、jemalloc `5.4.0`、fancyindex `0.6.0`、headers-more `0.41`、ngx_brotli `v1.0.0rc`。

### 10.2 本地静态校验
```bash
# Shell 语法
bash -n install_nginx.sh

# ShellCheck（建议安装：apt-get install shellcheck）
shellcheck -S warning install_nginx.sh

# Nginx 配置语法（在目标机执行）
sudo /etc/nginx/sbin/nginx -t -e /var/log/nginx/error.log -c /etc/nginx/conf/nginx.conf

# 版本、TLS 库与模块核对
/etc/nginx/sbin/nginx -V 2>&1 | grep -E "nginx version|built with OpenSSL|configure arguments"
```

### 10.3 运行期核对
```bash
# 监听端口（TCP 443/2096/2099/8443 + UDP 443）
sudo ss -lntup | grep nginx

# 限速命中
sudo tail -f /var/log/nginx/error.log | grep -E "limiting|429"

# OCSP 与 HTTP/3
echo | openssl s_client -connect main.abc.com:443 -servername main.abc.com -status 2>/dev/null | grep -A2 "OCSP response"
curl --http3 -sI https://main.abc.com/healthz
```
