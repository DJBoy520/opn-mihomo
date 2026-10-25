# os-mihomo 1.2.0 UI 方案 DeepSeek 审计报告

- 审计对象：`docs/DESIGN-1.2.0-ui-refresh.md`（v0.1 草案）
- 审计者：本会话主控（`new-provider-2/deepseek-flash`）
- 方法：逐节对照仓库代码 + VM <TEST_VM_LAN_IP> 只读实测
- 日期：2026-10-24
- **裁决：有条件通过**（High 4 项必须先写进方案并成为编码契约，否则可能造成 WebGUI OOM/卡顿、切换误报失败或敏感字段外泄）

---

## 1. 总体结论

方案方向正确，尤其 §3.2 关于 `mode: PROXY` 的定性是成立的：它是插件传输层状态，不是 mihomo 内核路由模式；内核实测为 `mode: rule`。但方案在“新增实时 `/proxies` API”这一块低估了 17MB 配置文件的读取成本、HTTP 204 空响应语义、以及响应字段白名单，这三项必须在编码前固化成契约。另有一处文件包/测试归属冲突会让并行编码必然红测。

---

## 2. 发现（按严重度排序）

### H1（High）`/proxies` 与 `core_mode` 若复用 `file()` 读取，会把 17MB 配置每 5 秒读一遍

- **证据**：`RulesController.php:493-570` 的 `readApiAddr()` 与 `readConfigSecret()` 使用 `@file(self::CONFIG_FILE, FILE_IGNORE_NEW_LINES)`，一次性载入整个 `config.yaml`。VM 实测该文件 **17,180,901 字节 / 357,290 条规则行**。
- **风险**：方案要求策略组页 5 秒轮询 `getGroups`，每次都会重新读 17MB 并生成 35 万个字符串；WebGUI PHP 进程内存与 CPU 会周期性飙升，极端情况下 OOM。
- **必须写进契约**：
  - 新 `Api/ProxiesController.php` **禁止** `file()` / `file_get_contents()` 读取 `config.yaml`。
  - 只用 `fopen` + `fgets`，找到 `^external-controller:` / `^secret:` / `^mode:` 后立即 `break`；并设最大读取 256KB 的硬上限。
  - `StatusController` 新增的 `core_mode` 解析同样必须流式、提前退出。
  - 测试增加负向断言：两个控制器不得出现 `file(` / `file_get_contents(`。

### H2（High）`PUT /proxies/{group}` 成功是 HTTP 204 且响应体为空，方案未定义成功判据

- **证据**：Clash/Mihomo 外部控制 API 语义（`PUT /proxies/:name` 成功返回 204 No Content）；仓库内暂无该调用可参考。
- **风险**：若按 `/version` 探测的写法要求“200 + 有 JSON 体”，真实成功会被判成失败，用户看到“切换失败”但实际已切换。
- **必须写进契约**：解析 `curl -w "\n%{http_code}"` 的最后一行，**200 与 204 都算成功**；响应体为空不报错；失败时才读取体并截断作为 `message`。
- **状态**：`unconfirmed`（未在 VM 上做真实 PUT；避免改动运行中的分流状态）。编码后必须在 VM 用“切换到当前同一节点”的幂等方式验证一次。

### H3（High）`/proxies` 原始响应不能直接下发浏览器，必须字段白名单

- **证据**：VM 实测 `/proxies` 单节点字段包含 `extra`、`provider-name`、`dialer-proxy`、`interface`、`routing-mark`、`smux`、`uot`、`xudp`；整包 31,429 字节（45 节点）。`extra` 的结构随代理类型变化，未来可能含服务端信息。
- **风险**：直接把原始 JSON 交给前端，会把订阅/供应商元数据、代理配置细节暴露到 WebGUI 响应；大订阅下响应体也会膨胀。
- **必须写进契约**：
  - 后端只输出 `{name, type, current}`（组级别再加 `type/now/selectable`）；**禁止 `json_encode($rawProxies)`**。
  - 不返回 `extra`、`server`、`port`、`provider-name`、`dialer-proxy` 等任何字段。
  - 响应体上限 4 MiB；超过则返回 `reachable:false` + `note`，不得截断成非法 JSON。

### H4（High）轮询无并发保护、无响应上限，慢请求会叠加

- **证据**：方案 §3.4.4 规定 5 秒自动刷新，但未定义“上一次未完成时怎么办”；mihomo API 在最坏情况下 `-m 5`。
- **风险**：每 5 秒发一个、每个最多 5 秒，请求会重叠；返回乱序时旧数据覆盖新数据，节点网格闪烁。
- **必须写进契约**：
  - 前端维护 `inFlight` 标志与递增 `requestSeq`，未完成不发下一次；只渲染 `seq === latestSeq` 的响应。
  - `document.hidden` 时暂停；恢复可见时先刷新一次。
  - 刷新后保留当前选中的组、搜索词与滚动位置（按组名恢复）。
  - 后端 `getGroups` 响应上限见 H3；前端对 `groups.length` 异常值做保护。

### M1（Medium）`tests/test_webgui_pages.sh` 归属冲突会让包 B 必然红测

- **证据**：方案 §4 把 `tests/test_webgui_pages.sh` 划给包 B 且声明“无依赖”；但 B 要新增的 Menu 5 项 / ACL 新 pattern 断言依赖包 C 的 `Menu.xml`、`ACL.xml`。
- **修正**：新页面相关的 Menu/ACL/页面控制器断言全部放进包 C 的 `tests/test_proxies_page.sh`；`test_webgui_pages.sh` 只由 B 做与 `index.volt` 相关的既有断言维护，保持无依赖。

### M2（Medium）规则页选择器漏了 `data.targets` 回退与 `parseTextToTable` 改造点

- **证据**：`rules.volt:531-549` 的 `loadRules()` 从 `/api/mihomo/rules/get` 的 `data.targets` 拿允许目标；`buildTargetSelect()`（`:293-309`）同时被 `createTableRow()` 与 `parseTextToTable()` 使用；`serializeTableToText()`（`:425-450`）依赖 `.rule-field-target` 的 `.val()`。
- **风险**：只改行内渲染、漏改源码模式转表格的路径，会导致切回表格模式后目标列变成普通 `<select>` 或空值。
- **修正**：在 §3.5 明确：
  - `data.targets` 保留为离线兜底；实时元数据来自 `getGroups`。
  - `buildTargetSelect()` 替换为 `buildTargetPicker()`，但必须同时替换 `createTableRow` 与 `parseTextToTable` 的所有调用点。
  - 保持 `.rule-field-target` class 在 hidden input 上，`serializeTableToText()` 不改。

### M3（Medium）`core_mode` 是“配置模式”，不是实时运行模式，展示要如实

- **证据**：`config.yaml:7` 为静态 `mode: rule`；若用户通过外部客户端 `PUT /configs` 改了运行模式，配置不会同步。
- **修正**：状态页标签写“内核模式（配置）”；服务未 RUNNING 时显示 `-`；不声称是实时值。若后续要实时，另立需求（需带 secret 的 `/configs` 轮询）。

### M4（Medium）Crash Reporter 清理必须先定位宿主并留证，生产机只读

- **证据**：测试 VM `/var/crash` 仅 `minfree`；`PHP_errors.log` 最后写入 2026-10-20；截图为 “3 days ago”，可能来自 <PROD_FIREWALL_LAN_IP> 或其它主机。
- **修正**：方案 §3.6 增加硬门禁：
  - 未确认宿主前不删除任何报告；
  - 生产机 <PROD_FIREWALL_LAN_IP> 在用户明确授权前只读；
  - 删除前把报告内容/文件名记录到会话或工单；
  - 清理后 24 小时复查，不以“弹窗消失”作为唯一证据。

### M5（Medium）延迟测试只对“节点”生效，组名可能返回 400

- **证据**：Clash API `/proxies/{name}/delay` 面向具体代理；对 Selector/URLTest 组名调用并非所有版本都支持。
- **修正**：前端只对 `type` 不属于组类型的节点显示“测速”；“测试本组”先解析该组 `now` 节点再测；后端对非节点名返回 `{status:'failed', message:'该目标不是可测速节点'}`，不把 400 当异常。

### M6（Medium）9 张 KPI 卡用 `col-md-3` 会排成 4+4+1

- **证据**：现有 8 张卡（`status.volt:10-85`）为 4×2；方案新增第 9 张后尾行只有 1 张。
- **修正**：改用 `col-md-4`（3×3），或把「内核模式」并入「服务状态」卡作为第三个徽章，保持 8 张。建议前者，信息层级更清楚。

### M7（Medium）临时 curl 配置必须在异常路径也删除

- **证据**：`RulesController.php:280-301` 在正常路径 `@unlink`，但没有 `finally`；新增控制器若中途抛错会残留含 secret 的 0600 临时文件。
- **修正**：`try { ... } finally { @unlink($cfgFile); }`；`tempnam` 后立即 `chmod 0600`；禁止用 `-H "Authorization: ..."` 作为回退。

### M8（Low）隐藏 `GLOBAL` 会让“规则目标为 GLOBAL”的用户无 UI 可切

- **证据**：VM `/proxies` 中 `GLOBAL` 为 Selector，`all` 含 61 个目标。
- **修正**：默认隐藏（避免与 PROXY 重复），但提供“显示 GLOBAL”开关或至少文档说明；不要硬编码跳过且无出口。

### M9（Low）不要提供“复制密钥”按钮

- **证据**：方案 §3.3.2 的可选 `#btn_copy_api_secret_hint`。
- **修正**：删除该可选控件。密钥只通过“查看密钥”对话框展示，避免剪贴板残留；只复制端点地址。

### M10（Low）测试补强：状态写入与 204 语义

- **证据**：`tests/test_failopen_logic.sh` 的 PROXY 是注入 fixture，不跑 `set_state`，不会被本次修改影响；`test_status_display.sh` 只 grep `status.volt` 文案。
- **修正**：
  - 增加静态断言：`service_manager.sh` 不再出现 `set_state "RUNNING" "PROXY"`，且包含 `TRANSPARENT` 分支。
  - VM 验收增加：`state.json.mode` 在 transparent 下为 `TRANSPARENT`，proxy 下为 `PROXY`。
  - 增加 `PUT` 204 的 VM 幂等验证（切到当前同一节点）。

### M11（Low）版本包输出物遗漏

- **证据**：`output/SHA256SUMS`、`output/build-info.json` 由构建脚本生成；方案 §4 包 E 未列。
- **修正**：E 明确包含构建后重新生成 `output/SHA256SUMS` 与 `output/build-info.json`，并保留旧包到 `output/archive/`。

### M12（Low）规则页 chips 显示“当前节点”可能被误解为规则目标

- **证据**：规则目标是“组名”，`→ 节点` 是运行时选择，二者不同层级。
- **修正**：chip 文案写“当前选择：<节点>（运行时）”，并在说明里写明规则不会锁定节点。

---

## 3. 已核实事实

- `state.json.mode` 是插件传输层状态：`service_manager.sh:335/338` 硬编码 `PROXY`；`transport-mode` 文件为 `transparent`；mihomo `/configs` 返回 `"mode":"rule"`。
- 状态机消费方：`system_status.py:211` 读取 `state.mode`；watchdog 不读 `mode`；`test_failopen_logic.sh` 的 PROXY 是注入 fixture，不受 `set_state` 修改影响。
- 状态页副标题位于 `status.volt:91`；面板与 API 卡片位于 `index.volt:62-113`；规则目标选择器位于 `rules.volt:26-32`、`:293-309`、`:425-450`。
- `RulesController.php:493-570` 使用 `@file()` 全量读取 17MB 配置。
- 新页所需 Menu/ACL 结构、`ProxiesController` 路由模式与现有 `StatusController` 一致。
- VM `/proxies`：15 组 / 45 节点 / 31,429 字节；`config.yaml` 17,180,901 字节 / 357,290 条规则行。
- Crash Reporter 由核心 `SystemStatus/CrashReporterStatus.php` 扫描 `/var/crash/*`；测试 VM 当前为空。

## 4. 未覆盖

- 未做真实 `PUT /proxies`（避免改变运行中的分流状态），204 语义为 `unconfirmed`。
- 未做浏览器实际渲染与移动端布局验证。
- 未用非 admin ACL 组验证 403 行为。
- 未模拟超大订阅（数千节点）下的 `/proxies` 响应上限。
- 未检查生产机 <PROD_FIREWALL_LAN_IP> 的 Crash Reporter（未获授权，只读也未执行）。

---

## 5. 结论

方案可以进入编码，但必须先把 H1–H4 与 M1/M2 固化进 `docs/DESIGN-1.2.0-ui-refresh.md` 的契约与测试断言；否则并行编码会在性能、切换成功判据、响应泄露和测试归属上直接翻车。建议修订为 v0.2 后再交给 Gemini 复核同一批点。

---

## 6. v0.4 补充（主控复核）

- **运行时模式切换方法**：测试 VM 的 `OPTIONS /configs` 返回 `Allow: GET, PUT, PATCH`。`PUT` 是整份配置重载，`PATCH` 才能局部更新 `{"mode":"rule|global|direct"}`。v0.4 已把方案从 `PUT /configs` 改为 `PATCH /configs`；成功判据仍为 200/204。
- 用户已确认：`transport_mode` 默认值保持 `proxy`；截图弹窗来自测试 VM（根因是 `PHP_errors.log` 存在，不是内核崩溃）；需要 WebGUI 的运行时 mode 切换。
- 新增用户约束：插件自有 UI 零 emoji；清除个人路径/端口回退/版本号硬编码；开源前脱敏（工作区 + 历史 + 构建产物），历史重写需单独授权。
