# Secure OPNsense Mihomo — 安全基线审计报告 (Phase 0)

> 文档编号：SEC-BL-001  
> 审计日期：2026-08-31  
> 审计对象：`src/os-mihomo` (Opnwall upstream base)  
> 状态：审计完成，待重构加固  

---

## 一、 安全现状总览

通过对当前 `src/os-mihomo` 源码、打包逻辑、构建脚本、系统集成脚本的逐行静态代码审计，发现当前版本存在**极高安全隐患与设计缺陷**：

1. **供应链安全失控**：二进制直接来自第三方个人 GitHub 仓库，无静态哈希校验，无版本固定。
2. **凭据与隐私严重泄露**：订阅更新脚本将用户订阅完整链接（含机场 Token / 凭证）发送至公共第三方在线订阅转换服务器 `subconverters.com`。
3. **未授权访问与信息泄露**：日志查询接口未包含任何 Session 验证与 ACL 鉴权，任何人均可未授权读取路由系统日志。
4. **单点故障与无 Fail-Open 保护**：DNS 与路由强制劫持至本地端口，Mihomo 异常崩溃或停止时，全局断网且无自动旁路机制。
5. **系统配置完整性风险**：打包脚本通过 `awk` 文本匹配直接修改主防火墙配置 `/conf/config.xml`，绕过 OPNsense 原生 MVC 与 Config 引擎。

---

## 二、 12 项专项安全与架构审计结论

| 序号 | 审计问题 | 审计结论与事实依据 |
| :--- | :--- | :--- |
| **Q1** | **Mihomo 二进制来源与官方性** | **第三方个人仓库（高风险）**。<br>`src/os-mihomo/build.sh:15` 硬编码为 `https://github.com/Vincent-Loeng/clash-meta/releases/latest/download/$MIHOMO_ASSET`，且源码中携带预编译包 `src/usr/local/bin/clash-meta-freebsd-amd64.xz`。 |
| **Q2** | **构建时哈希校验与完整性** | **完全无校验**。<br>`build.sh:110-143` 仅测试 `xz -t` 与文件非空，无预期 SHA256 对比；`+MANIFEST` 中的哈希为现场构建时自算，无法防御上游供应链投毒。 |
| **Q3** | **WebGUI 架构与框架合规性** | **非 MVC 架构**。<br>全量采用 `src/usr/local/www/` 下的 4 个独立面向过程 PHP 文件（`mihomo.php`、`mihomo_logs.php`、`mihomo_sub.php`、`mihomo_sub_log.php`），未接入 Phalcon MVC 框架。 |
| **Q4** | **Web 接口未授权访问** | **存在严重未授权访问（CWE-306）**。<br>`mihomo_logs.php:1-100` 与 `mihomo_sub_log.php:1-99` 未引入 `guiconfig.inc`，无鉴权保护，外网/内网任意请求均可直接获取全部日志。 |
| **Q5** | **CSRF 机制与安全性** | **自定义实现，脱离系统框架**。<br>`mihomo.php:112-128` 自建 Session 变量做校验，未遵循 OPNsense 标准 CSRF / XSRF 保护框架。 |
| **Q6** | **命令注入与 Shell 安全** | **当前受控**。<br>后台执行使用了 `escapeshellarg()` 对参数进行转义，但大量依赖外部 shell 脚本和 PHP 直接 `exec()` 调用。 |
| **Q7** | **Secret 敏感凭据管理** | **明文暴露**。<br>`mihomo_sub.php:394` 在前端 `<input type="text">` 中明文显示 Secret；`sub.sh:398` 在执行完成时直接将 Secret 打印至 stdout 和日志文件。 |
| **Q8** | **配置文件篡改与残留** | **存在重大隐患**。<br>`+POST_INSTALL:59-106` 与 `+PRE_DEINSTALL:71-119` 使用 `awk` 文本匹配直接修改 `/conf/config.xml`，绕过系统 Config 机制，易破坏 XML 结构。 |
| **Q9** | **Fail-Open 故障旁路机制** | **完全缺失**。<br>系统无 Watchdog 监控；Mihomo 异常死亡后 TUN 路由和 DNS 转发不撤销，导致局域网设备全部断网（流量进入黑洞）。 |
| **Q10**| **Unbound DNS 联动与单点故障** | **严重单点故障**。<br>`setup_unbound.php:84-98` 将 Unbound 全局 Forwarding 强行指向 `127.0.0.1:1053`，一旦 Mihomo 挂掉，全网 DNS 立即瘫痪。 |
| **Q11**| **订阅处理与第三方数据传输** | **高危公网外传（CWE-200）**。<br>`src/usr/local/etc/mihomo/sub/sub.sh:12` 硬编码 `https://subconverters.com/sub`，在第 105-109 行将用户完整订阅 URL（含 Token）明文发送到第三方公网服务器。 |
| **Q12**| **订阅 URL 与 Token 日志泄露** | **存在泄露**。<br>`sub.sh` 脚本在多处打印包含完整 Token 的 URL，结合未鉴权的日志查看接口，导致节点凭证完全裸露。 |

---

## 三、 漏洞与隐患分级清单 (P0 / P1 / P2)

### 🔴 P0 级（严重高危 / 必须立即阻断并重构）

#### 1. 第三方在线订阅转换导致凭据劫持与外泄
* **位置**：`src/os-mihomo/src/usr/local/etc/mihomo/sub/sub.sh` (行 12, 105-109)
* **代码**：
  ```sh
  API_BASE="https://subconverters.com/sub"
  ...
  API_URL="${API_BASE}?target=clash&url=${ENCODED_URL}&udp=true&clash.dns=true&list=false"
  curl -fL $CURL_TLS_ARGS -sS --retry 3 -m 15 -o "$TMP_RAW" "$API_URL"
  ```
* **危害**：将用户订阅 Token、节点密码与连接地址直接发送到公网第三方服务器，存在凭据盗用与中间人投毒风险。

#### 2. 日志端点未授权访问 (Unauthenticated Log Disclosure)
* **位置**：
  * `src/os-mihomo/src/usr/local/www/mihomo_logs.php` (行 1-100)
  * `src/os-mihomo/src/usr/local/www/mihomo_sub_log.php` (行 1-99)
* **代码**：直接读取 `/var/log/mihomo.log` 并 `echo`，顶部缺少 `require_once("guiconfig.inc");` 及认证校验。
* **危害**：攻击者无需登录 OPNsense 即可获取系统内部运行详情与日志。

#### 3. 缺乏 Fail-Open 与 DNS 单点瘫痪
* **位置**：`src/os-mihomo/src/usr/local/opnsense/scripts/mihomo/setup_unbound.php` (行 84-98)
* **代码**：无条件将 Unbound dot 转发设置到 `127.0.0.1:1053`，且无进程守护降级恢复机制。
* **危害**：Mihomo 异常退出或升级失败时，全网断网。

---

### 🟠 P1 级（高危风险 / 架构与供应链缺陷）

#### 1. 非官方二进制源与无静态 SHA256 锁定
* **位置**：`src/os-mihomo/build.sh` (行 14-15, 110-143)
* **危害**：依赖个人 GitHub 仓库并使用 `latest` 标签，极易引入恶意后门。

#### 2. 安装脚本 awk 直接篡改 `/conf/config.xml`
* **位置**：`src/os-mihomo/packaging/freebsd/+POST_INSTALL` (行 59-106)
* **危害**：易导致 XML 格式损坏或与 OPNsense 内存配置覆盖产生竞争冲突。

#### 3. 遗留过程式 Web 页面与非原生 CSRF
* **位置**：`src/os-mihomo/src/usr/local/www/mihomo.php`、`mihomo_sub.php`
* **危害**：不符合 OPNsense 26.7+ MVC 标准规范，无法融入系统统一 ACL 与审计。

---

### 🟡 P2 级（中低危缺陷 / 运维与编码不规范）

#### 1. API Secret 前端明文与日志明文打印
* **位置**：`src/os-mihomo/src/usr/local/www/mihomo_sub.php:394`、`sub.sh:398`
* **危害**：本地控制台或界面查看时容易泄露 API 访问控制凭证。

#### 2. configd 状态检测屏蔽真实 Exit Code
* **位置**：`src/os-mihomo/src/usr/local/opnsense/service/conf/actions.d/actions_mihomo.conf:21`
* **代码**：`command:sh /usr/local/etc/rc.d/mihomo status;exit 0`
* **危害**：状态查询永远返回成功，使前端或上层监控无法感知服务异常退出。

#### 3. 支持不安全的 TLS 降级参数
* **位置**：`src/os-mihomo/src/usr/local/etc/mihomo/sub/sub.sh:14`
* **危害**：允许 `INSECURE_TLS=1` 时开启 `curl -k`，增加中间人攻击隐患。

---

## 四、 修复与重构建议路线

1. **Phase 1 & 2**：重构构建链，移除非官方 binary，固定 MetaCubeX 官方发布版本与 SHA256。
2. **Phase 3 & 5**：将 Web 界面彻底迁移至 OPNsense Phalcon MVC 架构，移除面向过程 PHP，补齐鉴权与 CSRF。
3. **Phase 4 & 6**：建立 7 态服务状态机，引入 Fail-Open 旁路恢复机制。
4. **Phase 8 & 9**：重构 Unbound DNS 集成并实现完全可逆回滚，彻底删除第三方订阅转换。
