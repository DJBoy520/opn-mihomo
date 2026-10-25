# Secure OPNsense Mihomo — Unbound DNS 深度集成与无损回退规范 (Phase 8)

> 文档编号：DNS-INTEGRATION-001  
> 状态：正式完成 (Phase 8)  
> 核心实现：`setup_unbound.php` / `service_manager.sh` / `watchdog.sh`  

---

## 一、 DNS 架构与分流转发体系

在 Secure OPNsense Mihomo 插件中，采用 **方案 A：LAN -> OPNsense Unbound -> Mihomo DNS** 集成方案：

```
  [ LAN 客户端 DNS 请求 (Port 53) ]
                 │
                 ▼
  [ OPNsense 原生 Unbound DNS 服务 ]
                 │
      ┌──────────┴──────────┐
      │ (Mihomo 处于正常运行)│
      ▼                     │
  [ Forwarder: 127.0.0.1:1053 ]
      │ (Fake-IP / 域名分流)
      ▼
  [ Mihomo 内置 DNS 引擎 ] ──► [ 返回 Fake-IP (198.18.0.0/15) 或 远程安全解析 ]
```

---

## 二、 故障旁路与 100% 无损回退机制

```
      ┌─────────────────────────────────────────────────────────────┐
      │  Mihomo 异常 / 崩溃 / 手动停止 / 卸载插件                   │
      └──────────────────────────────┬──────────────────────────────┘
                                     │
                                     ▼
        [ 触发 setup_unbound.php bypass / uninstall 恢复机制 ]
                                     │
                                     ├─► 1. 移除 127.0.0.1:1053 forwarder 节点
                                     ├─► 2. 从 unbound-state.json 还原原始 forwarding 配置
                                     ├─► 3. 还原 privateaddress 排除网段
                                     └─► 4. 重新加载 Unbound 模板并安全重启
                                     │
                                     ▼
        [ Unbound 立即无损切回系统上游原生公网 DNS 解析 (100% 零死锁) ]
```

### 核心操作命令：
* `setup_unbound.php install`: 备份原始配置至 `/var/db/os-mihomo/unbound-state.json`，从 `privateaddress` 移除 Fake-IP 网段并添加 1053 端口 Forwarder。
* `setup_unbound.php bypass`: 紧急旁路模式，移除 1053 转发，使 Unbound 直接使用上游系统 DNS。
* `setup_unbound.php restore`: 恢复 1053 转发。
* `setup_unbound.php uninstall`: 彻底还原为安装前的原始状态并清理状态文件，保证 100% 无残留。
