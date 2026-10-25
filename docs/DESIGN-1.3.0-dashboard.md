# os-mihomo 1.3.0 常规页 Dashboard 化方案（v1.0，三审后修订）

> 原始提案：`docs/PROPOSAL-1.3.0-dashboard.md`（用户）。
> 审计：`docs/AUDIT-1.3.0-deepseek.md`（主控/DeepSeek）、`docs/AUDIT-1.3.0-gemini.md`（Gemini ×2：技术 + 视觉）。
> 三方一致结论：**方向正确、需修正后可行**。本文件是修正后的实施契约；与提案冲突处以本文为准。
> 范围：只重构 `/ui/mihomo`（常规设置页）为 4 Tab Dashboard；策略组/运行状态/规则/日志四个页面不动，但共享样式 token 升级会让它们同步受益。

---

## 0. 提案裁定表

| 提案内容 | 裁定 | 说明 |
| --- | --- | --- |
| 4 Tab 信息架构（概览/基本设置/订阅与策略/API与面板） | **采纳** | BS3 `nav-tabs`，无刷新切换，URL hash 双向绑定 |
| 状态卡片行（运行/模式/节点/策略组/规则数） | **采纳，改布局** | 2 张系统态卡 + 3 张资源指标卡的响应式 Grid（见 §3），min-height 84px，非固定 88px |
| 快捷操作按状态切主按钮 + loading + 确认 | **采纳** | 确认一律 BootstrapDialog（否决原生 confirm） |
| 「启用 Mihomo」开关放概览 | **改为只读徽章** | 同一模型字段双绑定会互相覆盖（DOM id 唯一性 + 表单序列化覆盖）；开关只在基本设置 |
| 订阅状态一行卡 + 立即更新 | **采纳** | 数据来自 `subscription/get.last_update`；更新走既有轮询逻辑 |
| 现代表单 label-on-top | **采纳（稳妥档）** | 保留 base_form，`.mihomo-modern-form` scoped CSS 扁平化；不手写表单 DOM |
| 策略来源 radio 大卡片 | **采纳** | 隐藏原生 `#sub_strategy` select（display:none 保 id），卡片点击同步其值 |
| 强调色换蓝 `#2563eb` | **待用户拍板** | Gemini 建议保留橙 + CSS tokens；若换蓝必须全站（一行变量）。两案实现成本相同 |
| 12px 圆角 | **改 8px** | 与宿主 4-6px 体系协调 |
| `row-cols-*` / Bootstrap 5 / 无 jQuery / fetch | **否决** | 实际是 BS3 + jQuery；必须 `ajaxGet/ajaxCall`（CSRF）；网格用 `row/col-*` 或已有 CSS Grid |
| 独立 `css/mihomo.css`、`js/mihomo.js` | **否决** | 丢 `lang._` 多语言、无缓存版本戳；样式并入 styles.volt，JS 留页内 |
| 轮询 `service/status` 拿全部指标 | **否决** | 真实返回 `{status,response}`；指标用 `subscription/get`，载入一次 + 更新后按需 |
| 「节点选择交给 ：9090/ui」 | **否决** | v1.2.0 已有策略组页；9090 默认回环 LAN 打不开；概览放跳转入口 |
| 流量图/连接数等 | **维持排除** | 与提案一致 |

---

## 1. 信息架构（Tab 映射与 id 契约）

BS3 结构：`ul.nav-tabs > li>a[data-toggle=tab]` + 4 个 `.tab-pane`。**全部既有 id 原样保留**，只是搬进对应 pane：

| Tab（hash） | 内容（既有 id） |
| --- | --- |
| 概览 `#overview`（默认） | `#service_status_badge`、`#btn_start/#btn_stop/#btn_restart/#btn_reload`、新增状态卡（`#ov_state_dot`、`#ov_state_text`、`#ov_transport`、`#ov_core_mode`、`#ov_autostart`、`#ov_pid`、`#ov_uptime`、`#ov_nodes`、`#ov_groups`、`#ov_rules`、`#ov_sub_time`、`#ov_sub_result`、`#ov_sub_msg`、`#ov_btn_sub_update`） |
| 基本设置 `#general` | `#frm_general_settings`（base_form 七字段）、`#btn_save`、`#btn_save_progress` |
| 订阅与策略 `#subscription` | `#sub_url`、`#sub_url_hint`、`#sub_url_masked`、`#sub_auto_update`、`#sub_interval`、`#sub_strategy`（隐藏 select + radio 卡）、`#btn_sub_save`、`#btn_sub_update`、`#btn_sub_update_icon`、`#sub_state`、`#sub_state_time/result/nodes/strategy/groups/rules/message` |
| 面板与 API `#api` | `#api_header_port`、`#api_bundled_link`、`#api_endpoint_display`、`#btn_copy_api_endpoint`、`#api_bind_badge`、`#api_wan_warn`、`#api_secret_masked`、`#btn_secret_reveal`、`#btn_secret_generate`、`#collapse_secret_custom`、`#api_secret_custom`、`#btn_secret_apply`、`#api_secret_help`、`#api_dashboard_guide`、`#api_guide_content` |

约束：`mihomo-card/mihomo-card-head/mihomo-card-body/mihomo-kv/mihomo-guide/mihomo-toolbar` 等既有类继续使用；`frm_general_settings` 的 `mapDataToFormUI`/`saveFormToEndpoint` 行为不变（隐藏 pane 内 serialize 正常取值）。

## 2. 数据源与轮询（零后端改动）

- **5s 轮询**（仅概览激活且页面可见时）：`/api/mihomo/service/status` → 指示灯、主按钮切换（运行中→主按钮=停止(红)；已停止→主按钮=启动(绿)）。
- **载入一次**：`/api/mihomo/subscription/get` → `last_update.{nodes,groups,rules,time,result,message}` 填充资源指标卡与订阅摘要行；`/api/mihomo/general/getGeneral` → 自启徽章（enabled）、面板数据（既有 loadSecretMasked）。
- **按需刷新**：点「立即同步」→ 既有 `startSubPolling` 逻辑（3s 间隔、20 分钟超时、baseline 对比）→ 完成后刷新概览卡与订阅 Tab。
- 防叠加：沿用 `inFlight/requestSeq` 模式；`document.hidden` 或切出概览 Tab 时暂停，切回时立即刷一次。
- 运行时长/PID：来自 `getMihomoStatus`？不——概览不新增该重端点；PID/uptime 显示在状态页已有，概览系统卡显示 state + transport + core_mode（core_mode 从 status/getMode，载入一次 + 状态变更后刷新）。**避免把 getMihomoStatus（含 configd）纳入 5s 轮询**。

## 3. 概览布局

```
┌ Tab: 概览 ────────────────────────────────────────────────────┐
│ ┌─ 系统状态（大卡，col-md-6）──────────┐ ┌─ 订阅资源（col-md-6）─┐ │
│ │ ● 运行中 · 透明代理 · 内核模式：规则分流 │ │  45      14     357,227 │ │
│ │ 自启：开   [查看运行状态 →]            │ │ 可用节点 策略组 生效规则 │ │
│ │ ─────────────────────────────────    │ │ ─────────────────────── │ │
│ │ [停止] [重启] [重载] （主按钮随态切换） │ │ <SUB>**** [成功] 2小时前 │ │
│ │                                       │ │ [立即同步] [策略组页 →]  │ │
│ └───────────────────────────────────────┘ └─────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

- ≥1200px：两卡各半，资源卡内 3 个数字等分；768-1199px 上下堆叠；<768px 单列。
- 指示灯 pulse、数字 26px/700/tabular-nums、骨架 shimmer 占位。
- 指标为空（订阅从未更新）显示 `-`。

## 4. 样式 token（styles.volt 顶部新增，全站生效）

```css
:root {
    --mh-brand: #d94f00;            /* 待拍板：换蓝改此一行 */
    --mh-brand-light: #fff7f2;
    --mh-brand-hover: #c44700;
    --mh-brand-ring: rgba(217, 79, 0, .15);
    --mh-success: #16a34a;  --mh-success-bg: #f0fdf4;
    --mh-danger: #dc2626;   --mh-danger-bg: #fef2f2;
    --mh-warning: #d97706;  --mh-warning-bg: #fffbeb;
    --mh-info: #0284c7;     --mh-info-bg: #f0f9ff;
    --mh-card-bg: #ffffff;  --mh-card-border: #e3e3e3;
    --mh-text: #1e293b;     --mh-muted: #64748b;
    --mh-radius: 8px;       --mh-radius-sm: 4px;
}
```

- 现有 `.mihomo-*` 类的硬编码色逐步改引变量（本版至少覆盖 brand/边框/圆角）；圆角 6px → 8px。
- 新增类：`.mihomo-tabs-bar`、`.mihomo-stat-card`（min-height:84px、hover 轻浮起）、`.mihomo-status-dot(.is-running/.is-stopped/.is-error)` + `@keyframes mh-dot-pulse`、`.mihomo-stat-num`、`.mihomo-skeleton` + shimmer、`.mihomo-modern-form`（base_form 扁平化）、`.mihomo-radio-cards`、`.mihomo-callout-warning`。
- 禁止 emoji；仅 Font Awesome。

## 5. 交互契约

1. Tab ↔ hash：`shown.bs.tab` 写 hash（`history.replaceState`）；载入按 hash 恢复（缺省 `#overview`）；`shown.bs.tab` 里补 `$('.selectpicker').selectpicker('refresh')`（隐藏 Tab 初始化宽度塌陷）。
2. 主按钮随状态切换；点击主按钮（停止/启动）→ BootstrapDialog TYPE_DANGER 确认 → 按钮 disabled+spinner → 完成后由 5s 轮询自然刷新。
3. 保存成功 → 页面内绿色 alert 横条（自动淡出）；失败 → 保留现有对话框与 messageLines。
4. 零 emoji；动态内容 `.text()`；无 `.html(`/`innerHTML`；无 `:9090` 字面量；不新增环境变量。

## 6. 测试（tests/test_webgui_pages.sh 增量）

- 保留全部既有断言（id/类不删）。
- 新增：nav-tabs 4 项与 `#overview/#general/#subscription/#api` pane；`.mihomo-status-dot`、`.mihomo-stat-card`、`.mihomo-radio-cards`、`.mihomo-modern-form`、`--mh-brand` token；hash 同步（`shown.bs.tab`/`replaceState`）；轮询守卫（`visibilitychange`）；概览数据源断言（`subscription/get` 载入一次、无 5s 轮询指标的代码特征）；零 emoji（已有测试覆盖）。
- `test_ui_no_emoji.sh` / `test_no_sensitive.sh` 继续通过。

## 7. 已拍板（用户 2026-10-24）

**强调色：方案 A——保留 OPNsense 橙 `#d94f00`**（`--mh-brand: #d94f00`），不换蓝；语义色（success/danger/warning/info）按 §4 token 引入。本文件其余内容即为实施契约。

## 8. 实施拆包（文件互斥）

| 包 | 文件 | 内容 |
| --- | --- | --- |
| P1 | `views/.../styles.volt` | token + 全部新类 + 圆角统一 8px |
| P2 | `views/.../index.volt` | Tab 结构重排（id 契约保留）、概览卡、radio 卡、modern-form 包裹、JS（Tab/hash/轮询守卫/主按钮切换/确认框） |
| P3 | `tests/test_webgui_pages.sh` | 增量断言 |
| P4 | `docs/WEBGUI.md`、`progress.md`（或 v1.3.0 记录）、版本号 1.2.0→1.3.0（Makefile/build.sh/version json/scripts 兜底） | 文档与版本 |

验收：全量本地测试 → 构建 → VM 部署 → Playwright 截图与功能验收（Tab 切换/主按钮切换/确认框/保存反馈/订阅更新联动）→ 提交推送。
