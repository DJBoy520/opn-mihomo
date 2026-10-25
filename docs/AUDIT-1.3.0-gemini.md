# os-mihomo 1.3.0 Dashboard 提案 Gemini 审计报告

- 审计对象：`docs/PROPOSAL-1.3.0-dashboard.md`
- 审计者：Gemini 子 agent ×2（`new-provider-2/gemini-3.8-flash-tiered`，技术可行性 + 视觉交互，独立上下文）
- 方式：只读代码核对；每条发现给出 文件:行号 证据
- 日期：2026-10-24
- **裁决：需修正后可行（两份审计一致）**

---

## 一、技术可行性审计（P0/P1/P2）

| 编号 | 严重度 | 问题 | 证据 | 修正 |
| --- | --- | --- | --- | --- |
| G-01 | P0 | 提案假设 Bootstrap 5 + 弃用 jQuery；`row-cols-*` 在 BS3 不存在会布局塌陷；裸 `fetch` 丢 CSRF 自动注入 | `index.volt:172`（col-xs-*）、`:120`（data-toggle）、`:291`（BootstrapDialog）、`:286`（mapDataToFormUI）、`:408`（selectpicker） | 全部基于 BS3 + jQuery + `ajaxGet/ajaxCall`；网格用 `row/col-*` 或 styles.volt 已有 CSS Grid；Tab 用 BS3 `nav-tabs + data-toggle="tab"` |
| G-02 | P0 | 提案假设 `service/status` 返回 `{running,mode,nodes,groups,rules,...}`；真实返回 `{status,response}` | `ServiceController.php:76-85` | 数据源改为：`service/status`（5s 轮询，已有）+ `subscription/get` 的 `last_update.{nodes,groups,rules,time,result}`（载入一次 + 立即更新后按需轮询）。指标是订阅更新的静态产物，无需 5s 常驻轮询——零后端改动 |
| G-03 | P0 | 推倒重写会熔断测试契约（31~35 个 DOM id + 6 个样式类被字面量断言） | `tests/test_webgui_pages.sh:215-237, 240-256` | Tab 只是显隐容器，全部既有 id/类原样保留并挂到对应 Tab 内 |
| G-04 | P1 | 「启用 Mihomo」概览 + 设置双处绑定：DOM id 冲突 + 保存互相覆盖 + 与启停按钮心智混淆 | `forms/general.xml:2-7` | 概览只放只读徽章（自启：开/关）；开关只在基本设置 Tab |
| G-05 | P1 | 提案 §6「节点选择交给 :9090/ui」与 v1.2.0 已上线策略组页冲突；且 9090 默认回环，LAN 用户根本打不开 | `proxies.volt`、`DESIGN-1.2.0-ui-refresh.md` | 保留策略组页；概览放跳转入口 |
| G-06 | P2 | 独立 `css/mihomo.css`/`js/mihomo.js`：丢失 `lang._` 动态多语言、无缓存版本戳、破坏 5 页共享样式架构 | `styles.volt`、`index.volt:13` | 样式并入 styles.volt（或新增 dashboard partial）；JS 留在 index.volt 页内 |
| G-07 | P2 | 隐藏 Tab 内 `.selectpicker('refresh')` 宽度塌陷 | `index.volt:410` | `shown.bs.tab` 事件里补 `$('.selectpicker').selectpicker('refresh')` |

技术审计结论：按上表修正后可行；落地方案（零后端改动 + 三步走：样式先行 → Tab 结构重组 → 微交互收口）。

## 二、视觉与交互审计（更好的做法）

1. **配色：不建议换蓝，保留 OPNsense 橙 + CSS Design Tokens**。
   - 理由：全站换蓝与 OPNsense 顶栏/导航高亮/面包屑割裂（"原生融入感"差）；BS3 的 `label-primary/btn-primary/info` 语义色本身就是蓝，自选 `#2563eb` 与之"近色冲突"；只换常规页则 1 页蓝 + 4 页橙更糟。
   - 落地：styles.volt 顶部定义 `--mihomo-brand / brand-light / brand-hover / brand-ring`、语义色（success/danger/warning/info）、表面色（card-bg/border/text-primary/text-muted）、圆角 token；5 页统一引用。若用户坚持蓝，改一行变量即可全站生效。
2. **卡片体系**：圆角收敛到 **8px**（12px 在宿主 4-6px 体系里过圆）；**min-height 84px 取代固定 88px**（防多语言折行溢出）；hover 轻浮起（translateY(-1px) + 阴影加深）。
3. **概览 5 卡布局**：否定 4+1 和生硬 5 等分，改为「2 系统态卡（大）+ 3 资源指标卡（小）」的响应式 CSS Grid：≥1200px 5 列流式；768-1199px 系统卡各占 1/2、资源卡各占 1/3；<768px 单列。
4. **指示灯呼吸光效**：`.mihomo-status-dot` + `::after` 环 + `mihomo-dot-pulse` keyframes（运行中绿色脉冲、停止灰、异常红）。
5. **数字排印**：26px/700、`font-variant-numeric: tabular-nums`、`letter-spacing:-0.02em`。
6. **骨架占位（Skeleton shimmer）**：ajax 返回前显示渐变扫光占位，避免数值跳变（CLS）。
7. **表单现代化走稳妥档**：保留 base_form，外包 `.mihomo-modern-form`，用 CSS 把 `table>tbody>tr>td` 扁平化为 block（label 置顶 13px/600、帮助图标淡化、控件 max-width 460px、focus 品牌色 ring）。零 DOM 改动，100% 继承 mapDataToFormUI/popover/未来字段。
8. **策略来源 radio 大卡片**：双卡片选择器 + 隐藏原生 `#sub_strategy`（display:none 保留 id，JS 存取零破坏）。
9. **统一警告条**：`.mihomo-callout-warning`（左 4px 琥珀边 + #fffbeb）。
10. **深色主题**：变量化铺路；`body[data-theme]`/`prefers-color-scheme` 回退留作后续。
11. **交互**：Tab ↔ URL hash 双向绑定（`shown.bs.tab` + `history.replaceState` + 落地恢复）；轮询双重守卫（概览激活 + document.visible）；确认框**一律 BootstrapDialog**（否决提案的"原生 confirm"——无法定制、阻塞、不专业）；停止服务确认文案要说明"将中断透明代理分流恢复直连"。
12. **概览布局升级**：核心系统态卡（指示灯+模式+PID+运行时长+主控按钮组）与订阅资源卡（3 个大数字+订阅摘要行）左右并置，比提案的上下堆叠更紧凑专业。

（完整 CSS/HTML 片段见工作流运行记录 dwfrun-33b74c22；实施时按上述 token 落地。）

## 三、与 DeepSeek 审计（docs/AUDIT-1.3.0-deepseek.md）的差异点

| 事项 | Gemini | DeepSeek | 采纳 |
| --- | --- | --- | --- |
| 概览数据源 | 前端组合（service/status 5s + subscription/get 载入一次 + 更新后按需） | 新增聚合端点 OverviewController | **采 Gemini**（指标是静态产物，无需新端点；零后端改动） |
| 配色 | 保留橙 + tokens | 默认换蓝、全站统一 | **交用户拍板**（两案都已把成本降到一行变量） |
| 圆角 | 8px | 12px（提案） | **采 Gemini 8px** |
| 原生 confirm | 否决，统一 BootstrapDialog | 未反对 | **否决原生 confirm** |

## 四、未覆盖

- 未实测隐藏 Tab 中 selectpicker/tokenizer 渲染（编码后浏览器验收确认）。
- 未实测深色主题现状表现。
- 未评估 OPNsense 插件级静态资源官方机制（已决定不依赖）。
