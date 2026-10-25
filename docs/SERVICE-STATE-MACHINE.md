# Secure OPNsense Mihomo — 服务管理与 7 态状态机规范 (Phase 4)

> 文档编号：STATE-MACHINE-001  
> 适用版本：os-mihomo 1.0.2+  
> 核心实现：`service_manager.sh` / `rc.d/mihomo` / `StatusController.php`  

---

## 一、 7 态状态机模型定义

为了保障系统运行状态清晰、透明且故障时能够确定性回滚，插件定义并实现了明确的 7 态服务状态机模型：

```
                ┌───────────────────────────────────┐
                │             DISABLED              │
                │        (插件配置未启用)           │
                └─────────────────┬─────────────────┘
                                  │ 启用 (Enable)
                                  ▼
                ┌───────────────────────────────────┐
                │             STOPPED               │◄───────────────────┐
                │      (服务已停止 / DIRECT 模式)   │                    │
                └─────────────────┬─────────────────┘                    │
                                  │ start / restart                      │
                                  ▼                                      │
                ┌───────────────────────────────────┐                    │
                │             STARTING              │                    │
                │ (配置预检 / API 探测 / TUN 确认)  │                    │
                └───────┬───────────────────┬───────┘                    │
      成功 (Success)    │                   │ 失败/超时 (Failure)         │
                        ▼                   ▼                            │
        ┌─────────────────────────┐   ┌───────────────────────────┐      │
        │         RUNNING         │   │          FAILED           │      │
        │ (正常运行 / PROXY 模式) │   │ (启动失败 / 回滚 DIRECT)  │      │
        └───────────┬─────────────┘   └─────────────┬─────────────┘      │
     节点异常/降级  │                               │                    │
                    ▼                               │                    │
        ┌─────────────────────────┐                 │                    │
        │        DEGRADED         │                 │                    │
        │ (部分异常 / 保持运行)   │                 │                    │
        └───────────┬─────────────┘                 │                    │
                    │                               │                    │
                    │ stop / kill                   │ 再次 stop / restart│
                    ▼                               ▼                    │
                ┌───────────────────────────────────┐                    │
                │             STOPPING              │                    │
                │ (优雅终止 / 路由与 TUN 清理)      │────────────────────┘
                └───────────────────────────────────┘
```

### 1.1 状态详细释义

| 状态标识 | 说明 | 对应网络模式 | 转换触发条件 |
| :--- | :--- | :--- | :--- |
| **`DISABLED`** | 插件在 WebGUI 被禁用 | `DIRECT` (WAN 直连) | 用户关闭 Enabled 开关 |
| **`STOPPED`** | 服务处于停止状态 | `DIRECT` (WAN 直连) | 正常执行 stop 且已清理路由 |
| **`STARTING`** | 正在执行严格启动时序 | `DIRECT` (暂未切代理)| 执行 start 或 restart |
| **`RUNNING`** | 所有启动检查通过，健康运行 | `PROXY` (TUN 代理) | API 可达且 TUN 设备就绪 |
| **`DEGRADED`** | 核心运行但节点或部分链路异常 | `PROXY` (降级模式) | 节点探测不可达但服务存活 |
| **`STOPPING`** | 正在终止进程并清理资源 | `DIRECT` (回退直连) | 执行 stop 或收到停止信号 |
| **`FAILED`** | 启动检查失败或运行中崩溃 | `DIRECT` (回退直连) | 启动超时/校验失败/崩溃退出 |

---

## 二、 严格启动时序与故障回滚机制

### 2.1 启动流程 (Strict Startup Sequence)
1. **步骤 1：配置 Dry-run 验证**
   - 调用 `mihomo -t -d /usr/local/etc/mihomo -f /usr/local/etc/mihomo/config.yaml`。
   - 若语法或配置错误：状态直接置为 `FAILED`，清理路由，立即退出（退出码 1）。
2. **步骤 2：切换状态至 `STARTING`**
   - 写入状态文件 `/var/run/mihomo_state.json` 与 `/var/db/os-mihomo/state.json`。
3. **步骤 3：启动后台守护进程**
   - 使用 `/usr/sbin/daemon -c -f -p /var/run/mihomo.pid` 启动 Mihomo 进程。
4. **步骤 4：确认主进程存活**
   - 读取 `/var/run/mihomo.pid` 并通过 `kill -0 "$PID"` 确认进程存在。
5. **步骤 5：轮询外部控制 API**
   - 轮询 external-controller（地址/端口解析自 config.yaml，默认 `http://127.0.0.1:9090`），最长等待 30 秒；v1.0.8 起 API 就绪探测失败仅告警不回滚（控制面/数据面解耦，见 FAIL-OPEN.md §四）。
6. **步骤 6：确认虚拟网卡 TUN**
   - 检查 `tun_mihomo` 设备是否已由内核/gVisor 成功创建。
7. **步骤 7：状态晋升至 `RUNNING`**
   - 将模式标记为 `PROXY`，更新状态时间戳与 PID。

### 2.2 启动异常自动回滚 (Fail-Safe Rollback)
在上述任何一个步骤发生异常或超时时：
* 触发 `cleanup_and_fail` 回退机制；
* 强制终止残留的 Mihomo 孤儿子进程；
* 销毁残留的 `tun_mihomo` 虚拟接口；
* 撤销代理路由，确保网络恢复至 `DIRECT` (WAN 直连)；
* 状态文件记录详细的失败原因并标记为 `FAILED`。

---

## 三、 停止与资源清理时序

执行 `stop` 时的清理流程：
1. 状态置为 `STOPPING`；
2. 发送 `SIGTERM` 给主 PID 与所有由 daemon 派生的子进程；
3. 等待最长 10 秒；若未退出则升级发送 `SIGKILL`；
4. 销毁 `tun_mihomo` 设备；
5. 撤销 PF 代理重定向与路由；
6. 状态正式更新为 `STOPPED`，模式恢复为 `DIRECT`。

---

## 四、 状态持久化文件格式

文件路径：`/var/run/mihomo_state.json` 与 `/var/db/os-mihomo/state.json`

```json
{
  "state": "RUNNING",
  "mode": "PROXY",
  "pid": 12345,
  "timestamp": 1788184500,
  "last_change": "2026-08-31 22:35:00",
  "message": "Mihomo is running normally (API ready, TUN verified)"
}
```

---

## 五、 系统集成规范

* **FreeBSD rc.d 脚本**：`src/usr/local/etc/rc.d/mihomo` 全面委托给 `service_manager.sh`。
* **OPNsense configd**：`src/usr/local/opnsense/service/conf/actions.d/actions_mihomo.conf` 移除了旧代码中的 `;exit 0` 掩饰，真实反映退出码。
* **WebGUI 监控**：`StatusController.php` 与 `status.volt` 实时解析 JSON 状态持久化文件，准确展示 7 态运行状态与 PROXY/DIRECT 标识。
