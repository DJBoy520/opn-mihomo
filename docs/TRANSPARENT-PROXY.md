# Secure OPNsense Mihomo — TUN 模式与 PF 规则隔离设计 (Phase 7)

> 文档编号：TRANSPARENT-PROXY-001  
> 状态：正式完成 (Phase 7)  
> 核心实现：`setup_firewall.php` / `service_manager.sh`  
>
> **v1.0.9 注**：本文为 Phase 7 历史设计（mihomo 自带 TUN，FreeBSD 不可用已弃用）。现行透明代理 = hev-socks5-tunnel（tun0）+ anchor `mihomo-transport`（route-to）；API 监听默认 127.0.0.1:9090，绑定地址/端口面板可配（v1.0.8 起）。

---

## 一、 PF 规则独立 Anchor 隔离哲学

为了避免修改 OPNsense 主规则集造成系统级配置冲突或升级损坏，os-mihomo 所有的防火墙规则均被封装在独立的 **PF Anchor `mihomo`** 命名空间内：

```
                    OPNsense 主防火墙规则表 (/tmp/rules.debug)
                                    │
                                    ├─── rule: pass out ...
                                    ├─── anchor "mihomo" ────────┐
                                    └─── rule: default deny ...  │
                                                                 ▼
                                                ┌────────────────────────────────┐
                                                │   Anchor "mihomo" 独立规则集   │
                                                ├────────────────────────────────┤
                                                │ 1. table <rfc1918> (私网直连)  │
                                                │ 2. API <bind>:<port> 默认回环  │
                                                │ 3. tun_mihomo 双向流量放行     │
                                                └────────────────────────────────┘
```

---

## 二、 核心命令与状态联动

1. **`setup_firewall.php apply_rules`**：
   - 生成私网直连表 `<rfc1918>`；
   - API 监听默认 127.0.0.1:9090，绑定地址/端口面板可配（general.api_bind/api_port，非回环绑定强制有效 Secret）；插件不添加针对 API 端口的 PF 规则，可达性由绑定地址决定；
   - 放行 `tun_mihomo` 虚拟网卡双向转发流量；
   - 通过 `pfctl -a mihomo -f -` 载入规则。
2. **`setup_firewall.php flush_rules`**：
   - 执行 `pfctl -a mihomo -F all` 快速销毁清空所有 mihomo 转发与过滤规则；
   - 在服务停止或 Fail-Open 旁路触发时调用，即刻恢复 WAN 直连。
3. **`setup_firewall.php install / uninstall`**：
   - 使用 `DOMDocument` 及文件排他锁安全在 `/conf/config.xml` 中注册/清理 TUN 接口节点，杜绝 XML 损毁。
