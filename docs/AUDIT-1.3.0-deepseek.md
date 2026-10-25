# os-mihomo 1.3.0 Dashboard 提案 DeepSeek 审计报告

- 审计对象：`docs/PROPOSAL-1.3.0-dashboard.md`（用户提案，2026-10-24）
- 审计者：本会话主控（`new-provider/deepseek-flash`），对照仓库代码与测试 VM 实测
- 日期：2026-10-24
- **裁决：需修正后可行**。提案的信息架构与视觉方向是对的，但有 6 处与当前代码事实不符的假设必须修正，另有 3 处与既有交付冲突需要裁定。

---

## 1. 先说结论

这份提案的「4 Tab + 状态卡片 + 快捷操作 + 现代表单」方向正确，能明显改善当前“单页长表单、信息混杂”的问题。但它把宿主框架、数据源和工程约束都假设错了：OPNsense 26.7 前端是 **Bootstrap 3 + jQuery**，不是 Bootstrap 5 / 无 jQuery；`service/status` 端点返回的字段也撑不起概览卡片。照原文实现会在第一屏就翻车。修正后是可行且值得做的。

---

## 2. 必须修正的事实错误（High）

### H1 提案假设 Bootstrap 5 / 无 jQuery，实际是 Bootstrap 3.4 + jQuery（verified）

- 证据：`index.volt:172` 使用 `col-xs-12 col-sm-6`（BS3 网格命名，BS5 是 `col-*`）；`:120` 使用 `data-toggle="collapse"`；`:291` 起 `BootstrapDialog`；`:286` `mapDataToFormUI`、`formatTokenizersUI`、`selectpicker` 全套 jQuery 插件。
- 影响：提案的 `row-cols-1 row-cols-sm-2 row-cols-lg-4`（BS4+ 语法）不生效；“不引 jQuery、用 fetch”会失去 OPNsense 的 CSRF 处理（`ajaxGet/ajaxCall` 自动带 `X-CSRFToken`，裸 fetch 需要手工提取动态 token）。
- 修正：Tab 用 BS3 的 `nav-tabs + data-toggle="tab"`（同样无刷新）；卡片网格用 `col-xs-6 col-sm-4 col-md-3`；异步一律 `ajaxGet/ajaxCall`；确认框继续 `BootstrapDialog`。

### H2 `/api/mihomo/service/status` 返回 `{status, response}`，没有 mode/nodes/groups/rules（verified）

- 证据：`ServiceController.php:76-85` 只有 `status`（configd 输出 contains 'is running'）与原始 `response`。
- 概览卡片需要的数据真实来源：
  - 运行/模式/传输层：`/api/mihomo/status/getMihomoStatus`（`state`、`transport_mode`、`tun_status`、`api_status`，且已含 `core_mode`）
  - 节点/策略组/规则数、最近更新时间/结果：`/api/mihomo/subscription/get` 的 `last_update.{nodes,groups,rules,time,result}`
- 修正（三选一，推荐 A）：
  - **A. 新增轻量聚合端点** `Api/OverviewController.php::getAction`：服务端只读 `/var/run/mihomo_state.json`（或 `/var/db/os-mihomo/state.json`）+ `last-sub-update.json`，纯文件读取、无 curl，一次请求返回 `{state, transport_mode, core_mode, nodes, groups, rules, last_update_time, last_update_result, last_update_message}`。5 秒轮询代价最小。
  - B. 前端组合两个既有端点（getMihomoStatus 是 4s 轮询已在跑，再加 subscription/get）——多一次请求且 getMihomoStatus 里有 configd 调用，比 A 重。
  - C. 扩展 ServiceController::statusAction——会让“服务控制”端点职责变宽，不推荐。

### H3 文件清单路径与落地方式不符合插件结构（verified）

- 提案写 `src/OPNsense/Mihomo/...`、`css/mihomo.css`、`js/mihomo.js`；实际仓库是 `src/os-mihomo/src/usr/local/opnsense/mvc/app/...`。
- OPNsense 插件提供独立静态 css/js 的路径约束较绕（要落到 webgui 静态目录并保证打包/清理），而本仓库已有验证过的模式：**`styles.volt` 共享 partial + 页内 `<script>`**（五页在用，测试也在断言）。
- 修正：css 需求并入 `styles.volt`（或新增 `dashboard.volt` partial，由 index.volt 引入）；js 需求继续放 index.volt 页内脚本段。不新增独立静态文件。

### H4 概览与设置两处放「启用 Mihomo」开关 = 同一模型字段双绑定（verified 风险）

- `mihomo.general.enabled` 由 `mapDataToFormUI` 绑定 `frm_general_settings`；再在概览放一个开关就是第二个绑定源，保存/轮询时序稍有不慎就会互相覆盖，且该字段语义是“启用（自启+生效）”，不是“立即启停”。
- 修正：概览不放开关，放**只读徽章**（`自启：开/关`，数据取 getGeneral 已有值）；开关只在基本设置 Tab。快捷操作区只放 启动/停止/重启/重载（进程控制），并按状态切主按钮——这个设计本身很好，保留。

### H5 提案第 6 节“节点选择交给 :9090/ui 面板”与 v1.2.0 刚交付的策略组页冲突（verified）

- v1.2.0（`2ae6517`）刚上线 `/ui/mihomo/proxies`（策略组实时切换），菜单第三项。
- 修正：本次重设计**只重构常规设置页**；概览的「策略组/节点」卡片做成可点击，跳转 `/ui/mihomo/proxies`；提案第 6 节该条作废。

### H6 测试契约：`test_webgui_pages.sh` 断言大量 id 与类（verified）

- 证据：`tests/test_webgui_pages.sh:216-244` 断言 `api_secret_masked/btn_secret_reveal/btn_secret_generate/frm_general_settings/btn_save/sub_strategy/btn_sub_save/btn_sub_update` 与 `mihomo-card/mihomo-card-head/mihomo-kv/mihomo-guide` 等类。
- 修正：Tab 化只是显隐容器，**全部既有 id 必须原样保留**（隐藏容器里 `mapDataToFormUI` 取值/赋值不受影响）；新增结构断言（nav-tabs、4 个 tab-pane、状态卡片 id）。`test_proxies_page.sh`/`test_status_display.sh` 不受影响。

---

## 3. 建议采纳的裁定（Medium）

### M1 配色：全站统一换色，不能只换常规页

`styles.volt` 是 5 页共享（General/Rules/Proxies/Status/Logs 都引 `{{ partial('OPNsense/Mihomo/styles') }}`）。只给常规页换蓝会让插件内部割裂。
- 建议落地：在 `styles.volt` 顶部定义 CSS 自定义属性（`--mh-accent:#2563eb` 或保持橙），全部 `.mihomo-*` 强调色改引变量；**全站一起换**。橙色与 OPNsense 顶栏一致、蓝色与提案一致——这是产品口味问题，默认按提案换蓝，但必须全站。
- 冲突注意：BS3 的 `label-info/label-primary`、`btn-primary` 语义色是蓝；自选蓝 `#2563eb` 与之接近，徽章/按钮层级要重新对齐（建议把 label-info 类的插件用法换成自定义 `.mihomo-badge-*`，避免语义色打架）。

### M2 卡片体系统一升级（好事，顺手做）

12px 圆角、统一阴影、`tabular-nums`、统一 badge 形状——应通过共享类 `.mihomo-card/.mihomo-stat` 全站生效，状态页 KPI、策略组页、规则页同步受益，而不是只做常规页。88px 固定高建议改为 min-height + padding（中文两行文案不会被裁）。

### M3 表单现代化：用稳妥档

`base_form` partial 渲染的是表格布局，label-on-top 需要 `display:block` 改造，风险中高（tokenizer/selectpicker 都挂在既有 DOM 上）。
- 推荐：**scoped CSS 覆盖**——在 `.mihomo-page` 内对 base_form 表格做样式化（label 列宽、去圆形 i 图标 `._icn` 隐藏、help 文案灰化、控件 max-width 360px、行距统一），不动 DOM 结构。
- 激进档（自定义渲染表单 + 手动 mapDataToFormUI 到自建控件）留作后续版本，本次不做。

### M4 轮询与可见性

概览 5s 轮询仅在该 Tab 激活时运行：`$('a[data-toggle="tab"]').on('shown.bs.tab')` 控制定时器启停；`document.hidden` 暂停；沿用 v1.2.0 的 `inFlight/requestSeq` 防叠加。切 Tab 不清空已渲染数据。

### M5 Tab 与 URL hash

`shown.bs.tab` 时写 `location.hash`，载入时按 hash 激活 Tab（缺省 `#/overview`）。便于从其它页/文档直达某 Tab。

### M6 保存成功反馈

现状是 BootstrapDialog 弹窗。提案要“顶部绿色 toast 不跳页”——改为页面内 `alert-success` 横条（自动淡出）更轻；但保存失败/校验错误仍需醒目展示（保留现有 messageLines 逻辑）。两可，倾向页面内横条 + 保留失败对话框。

---

## 4. 提案里直接可采纳的好点（Low，无需修改）

1. 快捷操作按状态切主按钮（运行中→停止红 / 已停止→启动绿），次按钮白底灰边。
2. 状态指示灯（绿/灰/红 + pulse）。
3. 数字 `tabular-nums`、等宽密钥/URL。
4. 密钥展示去粉底改白底点号掩码（现状 `index.volt` 密钥底色确实扎眼）。
5. 警告条统一“左 4px 琥珀边 + #fffbeb 底”（v1.2.0 已有 `.mihomo-badge-warn`，统一化即可）。
6. 策略来源 radio 大卡片化。
7. 「最近更新」两列 kv 网格。
8. 确认弹窗范围（停止、生成新密钥）——生成新密钥已有确认，停止需要补。
9. 登录落地页=概览 Tab（/ui/mihomo/ 本来就是默认页，成立）。

## 5. 提案遗漏、建议补充的点

1. **状态卡片数据为空时的空态**：订阅从未更新时 nodes/groups/rules 显示 `-` 而不是 0。
2. **概览与运行状态页的关系**：概览放“摘要 + 快捷操作 + 订阅摘要”，深度诊断（TUN/API/原始输出/诊断折叠）留在运行状态页，概览放“详情 →”链接，避免两个页面做成一样的。
3. **live-media 提示横幅与固定 footer**：v1.2.0 已加 `.mihomo-page padding-bottom:70px`，重设计保持。
4. **深色主题**：OPNsense 有 `opnsense-dark` 主题，现样式白底硬编码在暗色下会突兀。本次不强制适配，但 CSS 变量化（M1）为此铺路；至少保证边框/文字用变量而非写死。
5. **测试更新**：新增概览端点需 `tests/test_webgui_pages.sh`（或新 test_overview_api.sh）断言：纯文件读取（`fopen/fgets` 或 `json_decode(file_get_contents)`——注意：`/var/run/mihomo_state.json` 很小（<1KB），与 17MB 的 config.yaml 不同，这里可以放开 `file_get_contents` 限制，但必须写明豁免理由，避免守卫误伤）、`inFlight`、hash 同步、Tab 结构。
6. **版本号**：1.3.0。

## 6. 已核实事实清单

- BS3 网格与 jQuery 组件在用（index.volt:120,172,286-291）。
- ServiceController::statusAction 返回 `{status,response}`（:76-85）。
- getMihomoStatus 含 state/transport_mode/tun_status/api_status/core_mode（StatusController）。
- subscription/get 返回 last_update.{time,result,nodes,groups,rules,message}（SubscriptionController:84-87 与 index.volt renderLastUpdate）。
- forms/general.xml 七字段（enabled/log_level/transport_mode/lan_expose/lan_user/api_bind/api_port）。
- styles.volt 为 5 页共享，`#d94f00` 橙色强调散布多处。
- test_webgui_pages.sh:216-244 的 id/类契约。
- VM themes：opnsense / opnsense-auto / opnsense-dark。

## 7. 未覆盖

- 未实测 BS3 `nav-tabs` 在隐藏 pane 中 selectpicker/tokenizer 的渲染（理论上无碍，编码后浏览器验收确认）。
- 未实测深色主题下的现样式表现。
- 未评估 OPNsense 是否有插件级静态资源目录的官方机制（决定不依赖它）。
