# Secure OPNsense Mihomo — Fail-Open 故障旁路与自愈机制规范 (Phase 6)

> 文档编号：FAIL-OPEN-001  
> 状态：核心完成  
> 核心模块：`watchdog.sh` / `service_manager.sh` / `setup_unbound.php` / `setup_firewall.php`  

---

## 一、 Fail-Open 核心哲学与网络韧性

在家庭核心主路由场景下，**代理服务是可选的增值服务，而直连上网（DIRECT）是绝对不可阻断的核心生命线**。

```
                    ┌────────────────────────────┐
                    │     Mihomo 正常运行        │
                    │   (RUNNING / PROXY 模式)   │
                    └─────────────┬──────────────┘
                                  │ 进程被杀 / API超时 / DNS故障 / 节点全死
                                  ▼
                    ┌────────────────────────────┐
                    │      Watchdog 异常捕获     │
                    │    (触发 Fail-Open 旁路)   │
                    └─────────────┬──────────────┘
                                  │ 1. 撤销 TUN 虚拟网卡
                                  │ 2. 刷新重置 PF 代理锚点
                                  │ 3. Unbound 撤销 1053 Forwarding 并重启
                                  ▼
                    ┌────────────────────────────┐
                    │    即刻恢复 WAN 直连       │
                    │   (FAILED / DIRECT 模式)   │
                    │    家庭全网 100% 正常上网  │
                    └────────────────────────────┘
```

---

## 二、 9 大故障场景与 Fail-Open 旁路响应机制

| 序号 | 故障注入场景 | 探测与响应机制 | 最终网络状态 |
| :--- | :--- | :--- | :--- |
| **1** | **正常手动停止服务** | `service_manager.sh stop` 销毁 TUN，恢复 DIRECT | **WAN 直连，零断网** |
| **2** | **Mihomo 进程被 SIGKILL (kill -9)** | `watchdog.sh` 巡检到 PID 死亡 -> 触发 Fail-Open | **自动撤销路由，切回直连** |
| **3** | **非法配置导致启动失败** | `atomic_config_updater.sh` / `service_manager.sh` `mihomo -t` 拦截 | **保持旧配置与直连** |
| **4** | **所有外部代理节点不可达** | 健康检查判定为 DEGRADED/FAILED，不阻塞直连流量 | **国内流量直连，故障回退** |
| **5** | **TUN 虚拟设备被误删** | `watchdog.sh` 检测到 `tun_mihomo` 消失，重置状态机 | **即刻回退 DIRECT** |
| **6** | **本地 API 无响应（默认 127.0.0.1:9090，地址/端口面板可配）** | v1.0.8 起解耦：不杀进程，告警 + `api_bind_manager.sh reconcile` 后重试 | **数据面存活则保持运行（DEGRADED），不触发 Fail-Open** |
| **7** | **Mihomo DNS 解析异常** | 立即触发 `setup_unbound.php uninstall` 撤销转发 | **Unbound 恢复原生直连解析** |
| **8** | **二进制文件损坏** | 启动预检直接阻断，状态标记为 `FAILED` | **保持直连模式** |
| **9** | **系统重启后 Mihomo 启动失败** | `+POST_INSTALL` / rc.d 捕获异常置为 `FAILED` | **默认直连，不阻塞开机** |

---

## 三、 自动化巡检守护进程：`watchdog.sh`

* **执行频率**：可由 cron 每分钟调度或后台循环轮询。
* **检查维度**：
  1. 检查 `/var/run/mihomo.pid` 及其子进程是否存活 (`kill -0`)；
  2. 探测 external-controller API 可达性（地址/端口解析自 config.yaml，默认 `127.0.0.1:9090`；超时 3 秒）——**v1.0.8 起探测失败仅告警并尝试 reconcile，不再触发 Fail-Open（见 §四）**；
  3. 校验虚拟接口 `tun_mihomo` 是否在接口列表中。
* **应急操作**：一旦异常，在 5 秒内依次执行：
  1. `service_manager.sh failopen "<Reason>"`；
  2. `pfctl -a "mihomo" -F all` 清空所有代理转发规则；
  3. `setup_unbound.php uninstall` 恢复系统原生 Unbound DNS；
  4. `configctl unbound restart` 刷新 DNS 缓存。

---

## 四、 控制面/数据面解耦（v1.0.8 新语义，对应 DESIGN-lan-api.md §2.6）

自 v1.0.8 起，API（控制面）故障与数据面故障分开裁决：

* **数据面（致命判据，原语义不变）**：进程死亡、socks 7891 / DNS 1053 探活失败仍按原 Fail-Open 流程处理（failopen → 清 anchor → Unbound 摘除转发），保障直连生命线。
* **控制面（不再致命）**：external-controller API 无响应**不再杀进程、不再触发 Fail-Open**——改为：写告警（状态消息/告警文件）+ 尝试 `api_bind_manager.sh reconcile`（把绑定收敛回面板配置/默认值）后重试探测；服务保持 RUNNING，或标记 DEGRADED（数据面 UP + API DOWN）。
* **理由**：API 只是观测/管理通道，其故障不应放大为全网断代理；且绑定地址可配后，"API 失败即杀进程"会误杀仅绑定地址写错的健康实例。
* 本文档 §二表格第 6 项与 §三已按此语义更新；文中 tun_mihomo/TUN 相关描述属 Phase 6 历史设计（mihomo TUN 在 FreeBSD 不可用），现行透明代理由 hev-socks5-tunnel（tun0）+ anchor `mihomo-transport` 承担。
