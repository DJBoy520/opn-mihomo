# Secure OPNsense Mihomo — 架构基线文档 (Phase 0)

> 文档编号：ARCH-BL-001  
> 审计日期：2026-08-31  
> 状态：基线锁定  
>
> **v1.0.9 注**：mihomo 自带 TUN 在 FreeBSD 不可用（实测 `configure tun interface: invalid argument`），v1.0.5 起透明代理由 hev-socks5-tunnel（tun0）+ PF anchor `mihomo-transport`（route-to）承担；本文 TUN 拓扑保留作历史基线记录。

---

## 一、 系统现状拓扑与数据流图

```
+-------------------------------------------------------------------------------+
|                             OPNsense Firewall                                 |
|                                                                               |
|  [ LAN Clients ]                                                              |
|        │                                                                      |
|        │ 1. DNS Query (UDP/TCP:53)                                            |
|        ▼                                                                      |
|  [ Unbound DNS Service ] ──(2. Forward dots: *.1053)──► [ Mihomo DNS Engine ] |
|                                                                │              |
|                                                                │ 3. Fake-IP   |
|                                                                ▼ (198.18.0.0) |
|  [ LAN IP Traffic ] ──► [ PF Firewall Filter ]                                |
|                                │                                              |
|                                │ 4. Auto-route / Policy Routing               |
|                                ▼                                              |
|                       [ Virtual tun_mihomo ]                                  |
|                                │                                              |
|                                │ 5. Userspace TUN (gVisor Stack)              |
|                                ▼                                              |
|                       [ Mihomo Core Process ]                                 |
|                    (API: <bind>:<port> 默认 127.0.0.1:9090)                   |
|                                │                                              |
|                 ┌──────────────┴──────────────┐                               |
|                 ▼                             ▼                               |
|        [ Rule: MATCH Proxy ]         [ Rule: MATCH Direct ]                   |
|                 │                             │                               |
|                 ▼                             ▼                               |
|       [ Remote Proxy Nodes ]              [ WAN NIC ]                         |
|                 │                             │                               |
|                 └──────────────┬──────────────┘                               |
|                                ▼                                              |
|                           [ Internet ]                                        |
+-------------------------------------------------------------------------------+
```

---

## 二、 各模块职责与文件映射分析

| 组件分类 | 文件路径 | 职责与运行机制 | 存在的主要缺陷 |
| :--- | :--- | :--- | :--- |
| **服务守护进程** | `src/usr/local/etc/rc.d/mihomo` | 标准 FreeBSD rc 脚本，使用 `/usr/sbin/daemon` 启动/停止 Mihomo，负责预检配置 `mihomo -t` 及清理孤儿进程。 | 缺乏健康守护循环（Watchdog），无 Fail-Open 触发。 |
| **系统服务命令** | `src/usr/local/opnsense/service/conf/actions.d/actions_mihomo.conf` | 注册 configd 动作（`configctl mihomo <action>`）。 | `status` 动作使用 `;exit 0` 掩盖真实状态。 |
| **核心事件接入** | `src/usr/local/etc/inc/plugins.inc.d/mihomo.inc` | 注册 `mihomo_services()` 与 `newwanip` 重启钩子。 | 仅注册了基本钩子，未集成 OPNsense 原生 MVC 模块。 |
| **DNS 劫持集成** | `src/usr/local/opnsense/scripts/mihomo/setup_unbound.php` | 动态修改 Unbound 的 `dots` 转发规则和 `privateaddress`。 | 静态转发至 `127.0.0.1:1053`，服务停止时 Unbound 不回退，引发全网 DNS 瘫痪。 |
| **订阅与配置合成**| `src/usr/local/etc/mihomo/sub/sub.sh`<br>`src/usr/bin/mihomo_sub` | 下载订阅，提取节点，注入 `template_config.yaml`。 | 调用公网 `subconverters.com` 泄露用户 Token。 |
| **Web 交互界面** | `src/usr/local/www/mihomo*.php` | 4 个独立 PHP 页面，负责渲染表单、展示日志、执行 shell。 | 非 MVC 架构，日志接口未做鉴权（未授权访问）。 |
| **包安装/卸载** | `packaging/freebsd/+POST_INSTALL`<br>`+PRE_DEINSTALL` | 安装时注入 TUN 接口和放行规则；卸载时清理。 | 使用 `awk` 强行修改 `/conf/config.xml`。 |

---

## 三、 配置文件路径与权限现状

| 配置文件路径 | 用途 | 目标权限 | 现状风险评估 |
| :--- | :--- | :--- | :--- |
| `/usr/local/etc/mihomo/config.yaml` | Mihomo 运行时主配置文件 | `0644` | 包含 Web API Secret，权限过于开放。 |
| `/usr/local/etc/mihomo/sub/env` | 存储订阅 URL 及 Secret 变量 | `0600` | 存有敏感 Token，Web 前端明文回显。 |
| `/usr/local/etc/mihomo/sub/template_config.yaml` | 订阅合并基础模板 | `0600` | 正常。 |
| `/var/db/os-mihomo/unbound-state.json` | 备份 Unbound 修改前的状态 | `0600` | 正常。 |
| `/var/log/mihomo.log`、`/var/log/mihomo_sub.log` | 运行日志与订阅更新日志 | `0644` | 日志中打印包含 Token 的 URL 与 Secret。 |

---

## 四、 核心架构缺陷与重构目标

1. **架构模式缺陷**：当前未接入 OPNsense 标准 Phalcon MVC 体系，导致 ACL 权限、菜单体系、RESTful API 均处于割裂状态。
2. **路由与 DNS 单点风险**：完全缺失状态机驱动的 Fail-Open 保护，一旦 Mihomo 故障则整网中断。
3. **配置修改违规**：绕过系统 API 直接编辑 XML，存在并发覆盖风险。
