# os-mihomo 1.2.0 UI 方案 Gemini 审计报告

- 审计对象：`docs/DESIGN-1.2.0-ui-refresh.md`（v0.1 草案）
- 审计者：Gemini 子 agent（`new-provider/gemini-3.8-flash-tiered`，独立上下文）
- 方式：只读代码/测试核对；未连 VM、未执行 php -l
- 日期：2026-10-24
- **裁决：有条件通过**（2 项 High 必须先修设计）

---

## 1. 结论

方案不能直接进入编码。Gemini 抓到两项 DeepSeek 审计遗漏/低估的问题：

1. `service_manager.sh` 的 `do_healthcheck()` 仍在 `:490`、`:494` 硬编码写 `PROXY`；只改 `:335/:338` 会在下一次健康巡检时把状态打回 PROXY，R5 失效。
2. 策略组页的“批量延迟测试”（前端并发 4，每个后端 `curl -m 8`）会长期占用 OPNsense 的 PHP-FPM worker 池，可能拖垮整个 WebGUI。

其余为中危：状态页测试断言未同步、规则页 `<select>` 的 change 事件链断裂、ACL 未建独立子节点、5 秒轮询在大订阅下开销过大、未提供内核 mode 切换、failopen 测试是 mock 假通过。

---

## 2. 发现与主控核实

| # | 严重度 | 发现 | 证据 | 主控核实 |
| --- | --- | --- | --- | --- |
| G1 | High | 批量延迟测试并发 4 × 最长 8 秒会耗尽 PHP-FPM worker，造成 WebGUI 假死 | 方案 §3.4.2/§3.4.3；OPNsense PHP-FPM 默认 worker 数较少 | **成立**。采纳：取消批量与单点主动测速接口，改为只读展示 `/proxies` 的 `history` 最近延迟，彻底移除 `POST /delay` |
| G2 | High | `do_healthcheck` 仍写死 `PROXY`，健康巡检会把状态打回 | `service_manager.sh:490`（RUNNING）、`:494`（DEGRADED）、`:335/:338`（start 路径） | **成立**。采纳：所有 RUNNING/DEGRADED(PROXY) 写入点统一走 `transport_mode_now()` → `PROXY/TRANSPARENT`；并改 `:6` 注释 |
| G3 | Medium | 状态页文案改为“接入：*”会直接破坏 `test_status_display.sh:61-66` | 测试强断言 `模式：透明代理/代理/直连` | **成立**。已写入 v0.2 测试更新契约（§7.1），编码时同步改测试 |
| G4 | Medium | `<select class="rule-field-target">` 绑定 `change` → `updateCounter`；换成 hidden input 后 `.val()` 不触发事件 | `rules.volt:347`、`:293-309` | **成立**。采纳：picker 选中后显式 `trigger('change')` 或直接 `updateCounter()`；保留未知/离线目标回显 |
| G5 | Medium | ACL 未建独立 `page-services-mihomo-proxies` 子节点，受限角色会 403 | `ACL.xml` 现有 7 个细粒度节点 | **成立**。采纳：新增独立 ACL 子节点 + `ui/mihomo/proxies*`、`api/mihomo/proxies/*` |
| G6 | Medium | 5 秒轮询 + 大订阅（数百 KB JSON、数千节点）造成 CPU/内存抖动；上限 200 组 × 2000 节点仍可放 40 万节点 | 方案 §3.4.2/§3.4.4；VM 配置 17MB/357k 规则 | **成立**。采纳：拆成轻量 `getGroups`（不返回节点）+ 按需 `getNodes(group, q, offset, limit)`；默认 10 秒轮询、页面隐藏暂停、请求防叠加 |
| G7 | Low | 未提供 WebGUI 的 rule/global/direct 切换 | 方案 §3.2.4 明确不做 | **部分采纳**：不提供运行时切换（避免误操作、且不持久）；在状态页加“内核模式（配置）”与解释。若用户要求可单独立项 |
| G8 | Low | `test_failopen_logic.sh` 用 mock JSON，无法防状态机回归 | `test_failopen_logic.sh:16-31` | **成立**。采纳：增加静态断言 + VM 双模式实测（transparent→TRANSPARENT、proxy→PROXY） |

---

## 3. Gemini 未覆盖

- 未连 VM 实测 WebGUI、Crash Reporter、真实 mihomo API。
- 未执行 `php -l`（本机无 FreeBSD/PHP 环境）。
- 未检查 `/proxies` 实际字段（主控已只读实测：节点含 `extra/provider-name/dialer-proxy` 等，必须白名单）。
- 未核实 Clash `PUT /proxies` 的 204 空响应语义（主控标 unconfirmed）。

---

## 4. 结论

Gemini 的两项 High 已全部并入 v0.3 方案：取消主动测速 API、统一所有状态写入点。其余中危均已回写。建议 v0.3 再跑一次轻量复核（只审修订段落）后进入编码。

---

## 5. v0.4 决策与补充

- G7（未提供 mode 切换）：**用户明确要求做**。v0.4 已在状态页加入 `getMode`/`setMode`，走 `PATCH /configs`（不是 `PUT`；VM 的 `OPTIONS /configs` 返回 `Allow: GET, PUT, PATCH`），仅运行时、不持久、重启回 `rule`。
- G1（批量测速）：v0.3/v0.4 已彻底移除主动测速接口与按钮，只读展示 `history` 最近延迟。
- G2（do_healthcheck）：v0.4 覆盖 `:335/:338/:490/:494` 全部写入点。
- 新增用户约束：默认 `transport_mode` 不改；插件自有 UI 零 emoji；清除个人路径/硬编码；开源前脱敏（工作区 + 历史 + 构建产物）。
