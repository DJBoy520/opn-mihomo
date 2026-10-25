# Secure OPNsense Mihomo — P0/P1/P2 改造计划与技术路线图 (Phase 0)

> 文档编号：ROADMAP-001  
> 制定日期：2026-08-31  
> 状态：基线锁定，待 Phase 1 执行  

---

## 一、 缺陷与改造任务汇总表

| 级别 | 问题/任务项 | 风险与影响 | 归属修复阶段 |
| :--- | :--- | :--- | :--- |
| **P0** | **彻底剔除第三方订阅转换** | 用户 Token/凭据上传至公网 `subconverters.com`，存在凭据泄露和中间人劫持。 | **Phase 9** (订阅管理) |
| **P0** | **修复日志接口未授权访问** | `mihomo_logs.php` / `mihomo_sub_log.php` 未鉴权，任何人均可读取系统日志。 | **Phase 3 & 5** (WebGUI/安全加固) |
| **P0** | **Fail-Open 故障旁路与 DNS 联动** | Mihomo 进程崩溃或停止时，未撤销路由/DNS 转发，造成全网断网黑洞。 | **Phase 6 & 8** (Fail-Open/DNS) |
| **P1** | **Mihomo 官方供应链与强哈希锁定** | 当前从个人 GitHub 仓库下载 `latest` 二进制且无预设 SHA256 校验。 | **Phase 2** (官方供应链) |
| **P1** | **消除 awk 文本直改 config.xml** | 安装/卸载脚本直接修改主配置文件，易导致 XML 损毁或覆盖竞争。 | **Phase 5 & 7** (安全加固/TUN) |
| **P1** | **Web 界面重构至 Phalcon MVC** | 废弃面向过程 PHP 文件，接入 OPNsense 原生 MVC/Volt/Api 架构。 | **Phase 3** (WebGUI 基础) |
| **P1** | **Ubuntu 可重复跨平台构建环境** | 适配 Linux 与 FreeBSD 工具差异，实现一键构建标准 `.pkg` 包。 | **Phase 1** (构建环境) |
| **P2** | **API Secret 全链路脱敏与保护** | Secret 在前端表单明文显示并在脚本中输出至日志，需全链路脱敏。 | **Phase 5** (安全加固) |
| **P2** | **configd 动作 exit code 修正** | `status` 动作强制 `;exit 0` 导致无法感知服务真实故障状态。 | **Phase 4** (状态机管理) |
| **P2** | **移除不安全 TLS 参数 (curl -k)** | 脚本允许 `INSECURE_TLS=1` 降级，需强制实施标准 HTTPS 证书校验。 | **Phase 9** (订阅管理) |

---

## 二、 阶段推进与交付物规划 (Phase 1 ~ Phase 14)

```
[ Phase 0: 基线建立与全面审计 ] (已完成)
   │
   ▼
[ Phase 1: Ubuntu 可重复构建环境 ]
   └─ scripts/build.sh, scripts/verify-package.sh, docs/BUILD.md
   │
   ▼
[ Phase 2: Mihomo 官方供应链 ]
   └─ src/os-mihomo/build/mihomo-version.env, scripts/update-mihomo.sh, check-mihomo-release.sh
   │
   ▼
[ Phase 3: WebGUI 基础 (MVC/CSRF/ACL) ]
   └─ Model/View/Controller 结构重构, 修复未授权访问漏洞
   │
   ▼
[ Phase 4: 服务管理与 7 态状态机 ]
   └─ rc.d 守护脚本重构, service_manager.sh, 状态机监控
   │
   ▼
[ Phase 5: 安全加固 (API/Secret/配置原子化/脱敏) ]
   └─ CSPRNG Secret, 原子化 mktemp -> mihomo -t -> rename, 日志脱敏
   │
   ▼
[ Phase 6: Fail Open 核心机制 ]
   └─ 故障监测 (Watchdog), 9 大故障场景自动旁路切回直连
   │
   ▼
[ Phase 7: TUN 透明代理 ]
   └─ 独立 pf anchor, gVisor TUN, 单 LAN IPv4 稳定代理
   │
   ▼
[ Phase 8: DNS 集成与可恢复性 ]
   └─ Unbound Forward 联动, 故障/卸载时 100% 无残留无损回退
   │
   ▼
[ Phase 9: 订阅管理 (零第三方依赖) ]
   └─ 本地解析/自建 subconverter 接入, 订阅 URL 保密
   │
   ▼
[ Phase 10: 综合自动化测试套件 ]
   └─ 单元/集成/安全/故障/升级/回滚 6 大类测试
   │
   ▼
[ Phase 11: pkg repository 与签名体系 ]
   └─ 自建 repo 结构, pkg 签名, SBOM (CycloneDX/SPDX) 生成
   │
   ▼
[ Phase 12: OPNsense VM 仿真验证 ]
   └─ 完整 VM 拓扑演练, 9 大故障测试实测, 性能压测
   │
   ▼
[ Phase 13: 物理主路由正式部署 ]
   └─ Ryzen 4500U 生产部署, 24h 稳定性观察, 回滚预案
   │
   ▼
[ Phase 14: 长期维护与上游更新自动化 ]
   └─ GitHub Actions 自动检查上游 Release 并提 PR
```
