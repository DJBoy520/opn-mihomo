# os-mihomo 1.2.0 UI 与交互优化方案（草案 v0.4，用户决策后）

> 基线：`secure-mihomo` @ `3576923`（v1.1.0，工作区干净）。
> 本文只定义方案与契约，**不含实现**；审计通过后再拆包编码。
> 修订记录：
> - v0.1：初稿。
> - v0.2：并入 DeepSeek 审计（`docs/AUDIT-1.2.0-deepseek.md`）H1–H4/M1–M12。
> - v0.3：并入 Gemini 审计（`docs/AUDIT-1.2.0-gemini.md`）G1–G8：统一 `do_healthcheck()` 的所有 PROXY 写入点、取消主动测速 API/批量测速、策略组数据拆成轻量 `getGroups` + 按需 `getNodes` 分页、ACL 独立子节点、规则选择器保留 `change` 事件链与未知目标回显、轮询降为 10 秒。
> - v0.4：并入用户决策：① 截图弹窗确认来自测试 VM，根因是 `PHP_errors.log` 存在（核心 `CrashReporterStatus` 同时看该日志）；② `transport_mode` 默认值保持 `proxy` 不变；③ **新增 WebGUI 的 rule/global/direct 运行时切换**；④ 插件自有 UI 文案零 emoji；⑤ 清除个人路径/硬编码；⑥ 增加开源前脱敏包（工作区 + 历史 + 构建产物），历史重写需另行授权。
> 所有面向用户的文案使用简体中文；技术标识（DIRECT/REJECT/Selector/URLTest/rule/global/direct）保留英文原值。

---

## 0. 结论先行（TL;DR）

| # | 用户需求 | 结论 |
| --- | --- | --- |
| R1 | 状态页副标题“Mihomo 核心生命周期……”不要了 | 直接删除 `status.volt:91` 一行，无副作用 |
| R2 | 截图里的 System Status / Crash Reporter 弹窗 | 这是 OPNsense **核心**健康项（`CrashReporterStatus`），判定条件是 `/var/crash/textdump*|vmcore*` **或** `/var/lib/php/tmp/PHP_errors.log` 存在。测试 VM 的 `/var/crash` 已空，但该日志仍在（旧条目，最后写入 2026-10-20），所以弹窗是**旧日志触发**。先归档/确认无新错误，再用核心 UI 的 dismiss 清除，**不修改核心** |
| R3 | “面板与 API (9090)”写得太乱 | 重排为「访问地址 / 密钥管理 / 客户端接入」三段式，全部 id 与行为保留，端口动态渲染 |
| R4 | “允许的目标策略”做成 metacubexd `/proxies` 那样可实时选择 | 新增「策略组」页（实时读 `/proxies`，Selector 组可切换、展示最近延迟）+ 规则页目标策略改为同一数据源的实时选择器 |
| R5 | 把默认 `"mode": "PROXY"` 改成 `rule`，按分流规则做透明代理 | **这是显示语义 bug，不是路由 bug**：mihomo 内核实测已是 `mode: rule`；`"mode":"PROXY"` 是插件 `state.json` 的传输层状态，被 `service_manager.sh` 硬编码写死。修状态写入 + 分开展示「内核模式 / 接入方式」，并新增 **rule/global/direct 运行时切换**（不持久） |
| R6 | 界面少用表情符号 | 插件自有标签/按钮/提示/文档示例**零 emoji**，统一用 Font Awesome 图标；订阅带来的组名/节点名是数据，原样展示，不自行改写 |
| R7 | 尽量清除硬编码 | 清除个人绝对路径、视图里的端口/主机回退、硬编码版本号；生产值只来自模型/配置/模板；测试与文档改用占位符或 TEST-NET |
| R8 | 开源前不暴露个人敏感信息 | 新增开源脱敏包：内部交接文档移出公开树、源码个人路径清除、文档/测试占位化、敏感信息 lint 门禁；**Git 历史重写另行授权** |

---

## 1. 实测事实（2026-10-24，VM <TEST_VM_LAN_IP>）

| 事实 | 证据 |
| --- | --- |
| mihomo 内核运行在规则模式 | `/usr/local/etc/mihomo/config.yaml:7` → `mode: rule`；`GET /configs` → `"mode":"rule"` |
| 插件状态文件写的是 PROXY | `/var/db/os-mihomo/state.json` → `"mode": "PROXY"`，而 `/var/db/os-mihomo/transport-mode` → `transparent` |
| 硬编码位置 | `service_manager.sh:335`、`:338`、`:490`、`:494` 在 RUNNING/DEGRADED 时无条件写 `PROXY`，完全没读 transport-mode |
| 状态页副标题位置 | `status.volt:91` |
| 规则页目标策略现状 | `rules.volt:26-32` 静态列出允许值；`:293-309` 每行一个普通 `<select>`（`:347` 绑定 `change → updateCounter`），数据来自 `custom_rules_validate.php --targets`（读配置文件，不是实时 API） |
| 实时代理组已可用 | `GET /proxies`：15 个组（Selector/URLTest）、45 个节点，组名含 emoji/中文；mihomo v1.19.30；响应 31,429 字节 |
| Crash Reporter 机制 | 核心 `SystemStatus/CrashReporterStatus.php` 判定条件：`glob('/var/crash/textdump*')` / `glob('/var/crash/vmcore*')` **或** `file_exists('/var/lib/php/tmp/PHP_errors.log')`；dismiss 会删除 `/var/crash/*` 与该日志 |
| 历史 PHP 崩溃 | 测试 VM 的 `/var/crash` 仅 `minfree`；但 `PHP_errors.log` 仍存在（12,829 字节，mtime 2026-10-20），所以 Crash Reporter 仍显示。日志中插件条目是 10-18 的 `GeneralController::getNodes()`（v1.0.7 已修）；其余是调试期 `php -r` 用错 `/etc/inc/config.inc` 路径，非现行代码 |
| 现有状态 API 字段 | `system_status.py` 已输出 `transport_mode`/`tun_kind`/`api_status`；`StatusController` 只合并，不产出 `core_mode`，且 RUNNING 缺省回填 `PROXY`（`:151`），`pluginVersion` 硬编码 `1.0.9`（`:48`） |
| 个人/敏感信息扫描（只读） | 工作区命中：内部交接文档含测试/生产私网地址与 WebGUI 账号口令；`progress.md` 含私网地址；`transport_render.php:23` 含个人绝对路径；Git 历史有 9 个提交包含用户网段，作者邮箱 5 个；`output/`/`repo/` 二进制包可能内嵌构建路径。具体值不在本文件中记录 |
| 其它插件样例 | `src/os-easytier`、`os-sing-box`、`os-ddns-go`、`os-ddclient-opnwall` 存在私网地址/样例凭据，需逐项判断是否为上游示例；本方案只把 os-mihomo 列为必改，其它插件列入开源前复查清单 |

---

## 2. 需求 → 变更映射

| 需求 | 变更 | 是否改路由/配置 |
| --- | --- | --- |
| R1 删除副标题 | `status.volt` 删一行 | 否 |
| R2 崩溃弹窗 | 归档/确认 `PHP_errors.log` 无新错误 → 核心 UI dismiss → 复查 | 否 |
| R3 面板与 API 重排 | `index.volt` 结构 + `styles.volt` 新类 | 否 |
| R4 实时策略选择 | 新页 `proxies.volt` + 新 API + `rules.volt` 选择器 | 否（切换仅写 mihomo 运行时状态，不落配置） |
| R5 mode 语义 + 运行时切换 | `service_manager.sh` 写真实传输模式；`StatusController` 增 `core_mode`/`getMode`/`setMode`；状态页分开展示 + 运行时切换 | 运行时 `PATCH /configs`；不写 config.yaml、不持久 |
| R6 少用表情符号 | 插件自有文案零 emoji；订阅数据原样展示 | 否 |
| R7 清除硬编码 | 个人路径、视图端口/主机回退、版本号回退；测试/文档占位化 | 否 |
| R8 开源脱敏 | 内部文档移出公开树、敏感信息 lint、构建产物与历史复查 | 否（历史重写另行授权） |

---

## 3. 详细设计

### 3.1 R1：状态页副标题

- 删除 `status.volt:91` 的 `<p class="text-muted">…核心生命周期…</p>`。
- 其下 `<hr/>` 保留，卡片标题与表格不变。
- 不改 id、不改 JS、不改测试中的其它断言。

### 3.2 R5：模式语义修正（核心项）

#### 3.2.1 `service_manager.sh` 写真实传输模式

现状（共 **4 处** 硬编码，必须全部改）：

| 位置 | 现状 |
| --- | --- |
| `:335` | `set_state "RUNNING" "PROXY" ...`（start 路径，API OK） |
| `:336` | `echo "... mode PROXY ..."` |
| `:338` | `set_state "RUNNING" "PROXY" ...`（start 路径，API DOWN） |
| `:490` | `set_state "RUNNING" "PROXY" ...`（**do_healthcheck**，定时巡检） |
| `:494` | `set_state "DEGRADED" "PROXY" ...`（**do_healthcheck**，API DOWN） |
| `:6` | 注释 `# Modes: PROXY, DIRECT` |

只改 start 路径不够：`do_healthcheck` 由 `service_manager.sh healthcheck`（configd `mihomo healthcheck`）与 watchdog 调用，下一次巡检就会把 `state.json` 打回 `PROXY`，R5 会“改完又变回去”。

统一改为：

```sh
_tmode="$(transport_mode_now)"
[ "${_tmode}" = "transparent" ] || _tmode="proxy"
_mode="PROXY"
[ "${_tmode}" = "transparent" ] && _mode="TRANSPARENT"
```

- 上述 4 处 `set_state` 全部使用 `${_mode}`；`:336` 的 echo 同步。
- `do_healthcheck` 中 `DEGRADED` 且数据面 UP（`:494`）也应写 `${_mode}`；数据面 DOWN 的 `DEGRADED`/`FAILED` 保持 `DIRECT`。
- `STARTING/STOPPING/STOPPED/FAILED/DISABLED` 的 `DIRECT` 语义保持不变（表示数据面未接管）。
- 注释改为 `# Modes: PROXY, TRANSPARENT, DIRECT`。
- 不改变状态机、不改变 watchdog 判定、不改变退出码。

#### 3.2.2 `StatusController.php` 增加 `core_mode`

- 新增只读解析：从 `/usr/local/etc/mihomo/config.yaml` 读取列首 `^mode:[ \t]*(\S+)`，白名单 `rule|global|direct`，非法/缺失回退 `rule`（与模板一致）。
- **必须流式**：`fopen` + `fgets` 逐行读，命中 `^mode:` 立即 `break`；累计读取上限 256KB。**禁止** `file()` / `file_get_contents()`（VM 上该文件 17,180,901 字节 / 357,290 条规则，状态页每 4 秒轮询）。
- 输出新增字段 `core_mode`；`mode` 字段保留（兼容现有 UI/脚本），但 RUNNING 缺省回填从 `PROXY` 改为 `UNKNOWN`（`:151`），避免再次伪造事实。
- `core_mode` 语义是**配置的内核模式**，不是实时运行模式；若外部客户端通过 `PATCH /configs` 改了运行模式，本字段不会同步。UI 必须标注“（配置）”，服务非 RUNNING 时显示 `-`。
- 不新增 curl 请求、不读 secret、不输出 secret。

#### 3.2.3 `status.volt` 展示分层 + 运行时切换

- 服务状态卡：`#stat_state_desc`（运行中/启动中/…）保持不变；`#stat_mode` 改为**接入方式**徽章：
  - `transparent` → `接入：透明代理`（`label-info`）
  - `proxy` → `接入：仅代理`（`label-primary`）
  - 其余 → `接入：直连`（`label-default`）
- 第 2 张 KPI 卡「内核模式」：
  - `#stat_core_mode` 放在卡片容器上；内部是 `#core_mode_select`（`rule` 规则分流 / `global` 全局代理 / `direct` 直连）+ `#btn_core_mode_apply`（应用）+ `#core_mode_msg`（结果/不可达提示）
  - 下方小字 `#core_mode_config`：`配置默认：规则分流`（来自 `core_mode`，始终展示；服务未运行时运行时值显示 `-`）
  - 页面加载时调用 `getMode` 显示**运行时**模式；切换成功后刷新；失败显示服务端 `message`
- 其余 KPI（传输层/TUN/API/运行时长/内存/PID/版本）不变；总数 9 张，外层列改用 `col-md-4` 排成 3×3，避免 `col-md-3` 出现 4+4+1 的孤卡。
- `#stat_raw` 保留；修复后其中 `"mode"` 会显示 `TRANSPARENT`/`PROXY`，与接入方式一致。
- 所有动态内容继续 `.text()`/预置 HTML 图标，不引入 `.html(` 渲染用户数据。
- **插件自有文案零 emoji**：按钮/标签/提示只用文字 + Font Awesome；订阅组名/节点名中的表情原样展示（数据，不改写）。

#### 3.2.4 运行时内核模式切换（新 API）

`GET /api/mihomo/status/getMode`

- 从实时 `GET /configs` 读取 `mode`，白名单 `rule|global|direct`。
- 返回：`{status:'ok', reachable:true, mode:'rule', config_mode:'rule'}`；API 不可达：`{status:'ok', reachable:false, mode:null, config_mode:'rule', note:'mihomo API 不可达'}`。
- 只读；secret 通过 0600 curl 配置 `-K` 传入，禁止进 argv；`-m 3`。

`POST /api/mihomo/status/setMode`

- 参数：`mode`，只接受 `rule` / `global` / `direct`；其他值返回 `{status:'failed', message:'不支持的内核模式'}`。
- 执行：`PATCH /configs`，body `{"mode":"<已验证值>"}`；`-m 5`；`-w "\n%{http_code}"`；HTTP `200`/`204` 均成功（204 空体正常）。
- 方法选择依据：测试 VM 的 `OPTIONS /configs` 返回 `Allow: GET, PUT, PATCH`；`PUT` 是整份配置重载，`PATCH` 才是局部更新，因此运行时切 mode 用 `PATCH`，**不要用 `PUT`**。
- 成功：`{status:'ok', mode:'<mode>', message:'运行时模式已切换为 …（重启后恢复配置默认）'}`；失败：`{status:'failed', message:<截断输出>}`。
- **不写** `/usr/local/etc/mihomo/config.yaml`、不写模板、不触发 recompose、不持锁；仅 mihomo 运行时状态。
- 不改变 `service_manager.sh` 的状态机；`do_healthcheck` 只写 `state.json` 的接入方式，不碰 mihomo 的 `mode`。
- CSRF 走 `ajaxCall` POST；URL/端口从配置读取；不得出现 `:9090` 字面量。
- 失败/超时只影响本次切换，不杀进程、不改服务状态。

#### 3.2.5 明确不做的事

- **不**把 `transport_mode` 模型默认值从 `proxy` 改成 `transparent`（用户已确认保持）。理由：默认透明代理会让新装机器强依赖 hev/PF，装错即断网。
- **不**把运行时 `mode` 持久化到 `config.yaml`/模板/模型；重启后恢复模板的 `rule`。UI 必须写明“仅运行时生效”。
- **不**在规则页/策略组页重复提供 mode 切换入口，避免两处状态不一致；只在状态页提供。
- **不**改 `state.json` 的键名（`mode` 保留），避免破坏现有消费方；只修正取值。

### 3.3 R3：常规页「面板与 API」重排

#### 3.3.1 目标布局

```text
┌ 面板与 API                                   [端口 <API_PORT>] ┐
├ 访问地址 ────────────────────────────────────────────────┤
│ 内置面板   http://<FIREWALL_HOST>:<API_PORT>/ui/  [打开] [复制] │
│ API 端点   http://<FIREWALL_HOST>:<API_PORT>      [复制]        │
│ 当前监听   <API_BIND>:<API_PORT>  [警告] 监听全部接口            │
│ 认证密钥   ••••••••  [查看密钥] [生成新密钥]                  │
├ 自定义密钥（折叠）───────────────────────────────────────┤
│ [输入框] [应用]  4-128 字符，允许 . _ ~ @ # % ^ + = : ; , ! ? * - │
├ 客户端接入 ──────────────────────────────────────────────┤
│ Metacubexd  服务器 http://…:<API_PORT>   密钥：点击[查看密钥]复制 │
│ 内置面板     http://…:<API_PORT>/ui/                          │
│ [警告] <API_BIND> 为通配地址时的警告（仅通配绑定时显示）          │
└──────────────────────────────────────────────────────────┘
```

#### 3.3.2 契约

- **保留全部现有 id**：`#api_secret_masked`、`#btn_secret_reveal`、`#btn_secret_generate`、`#api_secret_custom`、`#btn_secret_apply`、`.api_disp_host`、`.api_disp_port`、`#api_bundled_link`、`#api_wan_warn`、`#api_header_port`、`#api_dashboard_guide`、`#api_guide_content`、`#api_secret_help`。
- 新增（可选）：`#btn_copy_api_endpoint`、`#api_bind_badge`。
- **不提供**“复制密钥”按钮：密钥只经“查看密钥”对话框展示，避免剪贴板残留；只复制端点地址。
- 标题端口徽章由 JS 写入：`端口 <api_port>`；**不得**出现 `:9090` 字面量（沿用零硬编码守卫）。
- `updateApiDisplay(bind, port)` 逻辑保持，新增：
  - 填充 `#api_bind_badge`（`0.0.0.0:port` / `127.0.0.1:port` / `<lan-ip>:port`）
  - 绑定 `0.0.0.0` 时显示 `#api_wan_warn`，否则隐藏
  - 复制按钮用 `navigator.clipboard`，失败回退 `select()+document.execCommand('copy')`
- `loadSecretMasked()`、密钥三个按钮的行为、对话框文案保持。
- “自定义密钥”默认折叠（Bootstrap collapse），展开后输入与校验行为不变。
- 不用 `innerHTML` 写入主机/端口/密钥；只用 `.text()`/`.attr()`。

#### 3.3.3 样式（`styles.volt`，包 B 统一定义）

新增：`.mihomo-kv`（两列定义表）、`.mihomo-kv th`、`.mihomo-kv td`、`.mihomo-section`、`.mihomo-section-title`、`.mihomo-copy-btn`、`.mihomo-badge-warn`。
约束：白底、`#e3e3e3` 1px 边框、橙色 `#d94f00` 强调；响应式 767px 以下纵向排列。

### 3.4 R4-a：新增「策略组」实时页（metacubexd `/proxies` 风格）

#### 3.4.1 路由与文件

| 项 | 值 |
| --- | --- |
| 页面 | `/ui/mihomo/proxies` |
| 页面控制器 | `controllers/OPNsense/Mihomo/ProxiesController.php`（`extends \OPNsense\Base\IndexController`，`view->pick('OPNsense/Mihomo/proxies')`） |
| API 控制器 | `controllers/OPNsense/Mihomo/Api/ProxiesController.php` |
| 视图 | `views/OPNsense/Mihomo/proxies.volt` |
| 菜单 | `Menu.xml` 新增 `Proxies`，`order=30`；Status/Logs 顺延 40/50 |
| ACL | 新增独立节点 `<page-services-mihomo-proxies>`，patterns：`ui/mihomo/proxies*`、`api/mihomo/proxies/*`（不要只挂在根组，否则按最小权限分配的子模块角色会 403） |
| 测试 | `tests/test_proxies_page.sh`（新建） |

#### 3.4.2 API 契约

`GET /api/mihomo/proxies/getGroups`（**轻量**，不返回节点明细；可选参数 `include_global=1`）

```json
{
  "status": "ok",
  "reachable": true,
  "core_mode": "rule",
  "updated": 1761234567,
  "groups": [
    {
      "name": "组A",
      "type": "Selector",
      "now": "节点组B",
      "count": 2,
      "selectable": true
    }
  ],
  "note": ""
}
```

- `groups` 顺序沿用 `/proxies.proxies` 的插入顺序；默认跳过 `GLOBAL`（避免与 PROXY 组大量重复），但页面提供“显示 GLOBAL”开关，避免规则目标为 GLOBAL 时无 UI 可切。
- `selectable = (type === 'Selector')`；URLTest/Fallback/LoadBalance 只读展示。
- `count = count(group.all)`；**不下发 `all` 数组**。节点明细走 `getNodes`。
- 组数上限 200；超过则返回前 200 + `truncated:true`。
- **字段白名单（硬契约）**：只输出 `{name,type,now,count,selectable}`。**禁止**把 `/proxies` 原始对象或 `json_encode($raw)` 下发；不得返回 `extra`、`server`、`port`、`provider-name`、`dialer-proxy`、`interface`、`routing-mark` 等字段（VM 实测原始节点含这些键）。
- **读取方式（硬契约）**：解析 `/proxies` 的 JSON 可以整体 `json_decode`（31KB/45 节点，可控），但读取 `config.yaml` 的 `external-controller/secret/mode` **必须** `fopen`+`fgets` 提前退出，累计 ≤256KB，禁止 `file()`/`file_get_contents()`（VM 配置 17MB/357k 规则）。
- 原始响应 > 4 MiB 时直接返回 `reachable:false` + `note:'响应过大'`，不得截断成非法 JSON。
- API 不可达：`{status:'ok', reachable:false, groups:[], core_mode:'rule', note:'mihomo API 不可达'}`，HTTP 200，绝不抛异常。

`GET /api/mihomo/proxies/getNodes`（**按需、分页、服务端搜索**）

参数：`group`（必填）、`q`（可选，≤200 字符，去控制字符）、`offset`（≥0，默认 0）、`limit`（默认 100，1~500）。

```json
{
  "status": "ok",
  "reachable": true,
  "group": "组A",
  "type": "Selector",
  "now": "节点组B",
  "selectable": true,
  "nodes": [
    {"name": "节点组B", "type": "URLTest", "current": true, "delay": 0},
    {"name": "节点组C", "type": "Selector", "current": false, "delay": 0}
  ],
  "total": 2,
  "offset": 0,
  "limit": 100,
  "truncated": false,
  "query": ""
}
```

- 只对**指定组**的 `all` 做切片；`q` 按节点名做大小写不敏感子串过滤；`delay` 取 `/proxies.<node>.history` 最后一条的 `delay`（没有则 0），**不主动发起测速**。
- 字段白名单：`{name,type,current,delay}`；不返回 `history` 原始数组、`extra`、`server` 等。
- 组不存在 / 不是组 → `{status:'failed', message:'策略组不存在'}`；API 不可达 → `reachable:false`。
- 禁止一次性返回整组：`limit` 上限 500；前端翻页。

`POST /api/mihomo/proxies/select`

- 参数：`group`（≤128 字符）、`name`（≤128 字符）。
- 校验：两者非空且为标量；从实时 `/proxies` 读取后精确匹配 `group`，要求 `type === 'Selector'` 且 `name ∈ group.all`；任一不满足返回 `{status:'failed', message:'…'}`（不拼 shell）。
- 执行：`PUT /proxies/{rawurlencode(group)}`，body `{"name":"<已验证 name>"}`；`-m 6`；用 `-w "\n%{http_code}"` 取最后一行状态码。
- **成功判据**：HTTP `200` 与 `204` 都算成功；204 响应体为空是正常行为，不得当失败。只有非 200/204 才读取响应体并截断作为 `message`。
- 成功：`{status:'ok', message:'已切换到 …'}`；失败：`{status:'failed', message: <截断后的 curl 输出>}`。
- **不写** `/usr/local/etc/mihomo/config.yaml`；不持久化到模型；重启后回到订阅默认（页面需提示）。

> **主动测速（`/delay`）不在 1.2.0 范围**。Gemini 审计指出：前端批量测速并发 4 × 后端 `curl -m 8` 会长期占用 PHP-FPM worker，可能拖垮整个 WebGUI。1.2.0 只读展示 `history` 里已有的最近延迟；需要主动测速时使用 metacubexd 或单节点外部工具。

#### 3.4.3 安全实现（沿用 v1.0.8/1.1.0 已验证模式）

- secret 只从 `config.yaml` 的 `^secret:` 读取；用 `tempnam()` + `chmod 0600` 的 curl 配置文件 `-K` 传入，**绝不进 argv**；用 `try { … } finally { @unlink($cfgFile); }` 保证异常路径也删除。
- 读取 `external-controller/secret/mode` 一律 `fopen`+`fgets` 提前退出（≤256KB），禁止 `file()`/`file_get_contents()`；这是本页 10 秒轮询的生命线（VM 配置 17MB/357k 规则）。
- `external-controller: 0.0.0.0:port` 归一化为 `127.0.0.1` 探测；端口取自配置，不写死。
- 所有 URL 路径段 `rawurlencode`；组名/节点名先对实时数据做白名单匹配，再拼 URL。
- 所有 `shell_exec` 参数 `escapeshellarg`；失败/超时一律返回结构化失败，不 500。
- 响应字段白名单：组只输出 `{name,type,now,count,selectable}`；节点只输出 `{name,type,current,delay}`；不返回原始 proxy 对象、`extra`、`server`、`port`、`provider-name`、`dialer-proxy`、`history` 等。
- CSRF：走 OPNsense `ajaxCall`（自动带 `X-CSRFToken`）；只有 `select` 是 POST。
- 不在响应里返回 secret；不在日志里打印 secret。
- 并发保护：前端同一时刻只允许一个 `select` 请求，按钮 pending 时禁用；**不提供主动测速**，因此没有批量阻塞调用。

#### 3.4.4 页面交互

- 顶部工具栏：搜索框、刷新、自动刷新开关（默认开，**10s**，`document.hidden` 时暂停）、内核模式徽章、API 状态徽章、“显示 GLOBAL”开关（默认关；打开时以 `include_global=1` 重新请求组列表）。
- 轮询只刷新**组列表**（轻量 `getGroups`），不刷新节点明细；节点明细在选中组、翻页、搜索、切换成功后按需 `getNodes`。轮询必须防叠加：维护 `inFlight` 与递增 `requestSeq`，上一次未完成不发下一次；只渲染 `seq === latestSeq` 的响应；恢复可见时先刷新一次；刷新后按组名恢复当前选中组、搜索词与滚动位置。
- 左栏（`col-md-4`）：组列表。每项显示：名称、类型徽章、当前选择、节点数；点击选中该组。
- 右栏（`col-md-8`）：
  - 组标题 + 类型 + 当前选择 + 节点搜索 + 分页（`#proxies_prev/#proxies_next/#proxies_page_info`，每页 100，最大 500）
  - 节点网格（卡片）：名称、类型、当前标记、最近延迟徽章（来自 `history`，不主动测速）
  - Selector 组点击节点 → 确认后 `select`；非 Selector 组节点置灰并提示“该组由内核自动选择”
- **不提供**“测试本组”/“单节点测速”按钮：避免 PHP-FPM 阻塞与批量连接；需要主动测速请用 metacubexd。
- 状态：
  - API 不可达 → 整页提示“mihomo API 不可达（服务未运行或密钥未生效）”+ 重试按钮，无 JS 异常
  - 切换成功 → 顶部 toast + 刷新组列表 + 当前组节点；失败 → 显示服务端 `message`
  - 空组/空节点 → `.mihomo-empty`
- XSS：全部 `.text()`；组名含 emoji/中文/引号也必须安全。
- 响应式：767px 以下左右栏堆叠。

### 3.5 R4-b：规则页「允许的目标策略」实时选择器

#### 3.5.1 顶部“允许的目标策略”卡片

- 数据源：优先 `/api/mihomo/proxies/getGroups`（实时）；不可达时回退**现有** `loadRules()` 已拿到的 `data.targets`（来自 `/api/mihomo/rules/get`，底层是 `custom_rules_validate.php --targets`），并显示“离线（配置文件）”徽章。不得新增/假设不存在的 targets 接口。
- 渲染为分组 chips：
  - 内置：`DIRECT`、`REJECT`、`REJECT-DROP`（固定最前）
  - 订阅组：按 `/proxies` 顺序，chip 显示组名 + 类型 + “当前选择：<节点名>（运行时）”
- 增加“打开策略组页面”链接（`/ui/mihomo/proxies`）。
- 保留 `#rules_targets` 容器 id；离线时保留“未上报可用目标策略”兜底。
- 说明文案改为：“规则的目标必须是内置动作或代理组名称；节点由策略组内部实时选择，规则不会锁定具体节点。”

#### 3.5.2 每行目标选择器

- 保留 `.rule-field-target` **class**（现有序列化逻辑 `$tr.find('.rule-field-target').val()` 不变），但元素由 `<select>` 改为：
  - `<input type="hidden" class="rule-field-target" value="…">`
  - 同格一个按钮 `.rule-target-picker`，显示当前目标的徽章 + 下拉箭头
- **必须补 `change` 事件链**：现有 `rules.volt:347` 对 `<select>` 绑定了 `.on('change', updateCounter)`；hidden input 用 `.val()` 赋值不会触发事件。picker 选中后必须显式 `$input.val(x).trigger('change')`（或直接调用 `updateCounter()`），否则行号重排、变更计数与 dirty 状态不同步。
- **必须保留未知/离线目标回显**：`buildTargetSelect()` 在目标不在允许列表时会前置一个自定义 option（`rules.volt:305-307`）；picker 也要在按钮上显示该未知目标（如 `custom-group`）并允许保持不变，源码模式 ↔ 表格模式互转不得丢值。
- **必须同时替换两个调用点**：`createTableRow()` 与 `parseTextToTable()` 都调用 `buildTargetSelect()`（`rules.volt:293-309`、`:346`、`:405-410`）；改为 `buildTargetPicker()` 后，源码模式切回表格模式也必须渲染选择器，不得残留普通 `<select>`。
- 点击按钮 → BootstrapDialog：
  - 搜索框（客户端过滤）
  - 列表分两段：内置动作 / 代理组；每项显示名称、类型、当前选择、节点数
  - 选中 → 写 hidden input + 更新按钮文本；关闭
  - Esc/取消不改值
- 表格模式/源码模式互转、`payload !== ''`、`attr('data-line', …)`、行号、校验与应用逻辑全部不变。
- 服务端校验仍是唯一权威：`custom_rules_validate.php` 的 targets 来源顺序（`MIHOMO_TARGETS_FILE` > 生效 config.yaml > 模板）不变；前端选择器只是输入辅助。
- 不引入 `.html(`/`innerHTML`；不使用 `:9090` 字面量。

#### 3.5.3 与策略组页的关系

- 规则页只选“组名”，不选具体节点；具体节点在策略组页实时切换。
- 两页共用同一 API 与同一套组/节点数据，行为一致。

### 3.6 R2：System Status / Crash Reporter 弹窗治理

#### 3.6.1 机制（已核实）

- 弹窗来自 OPNsense 核心 `SystemStatus` 的 `CrashReporterStatus`；判定条件不是 `/var/crash` 非空，而是：
  - `glob('/var/crash/textdump*')` 或 `glob('/var/crash/vmcore*')` 有命中，**或**
  - `/var/lib/php/tmp/PHP_errors.log` **存在**（不要求有内容/新内容）。
- 测试 VM 实测：`/var/crash` 仅 `minfree`，但 `PHP_errors.log` 仍存在（12,829 字节，mtime 2026-10-20）。因此弹窗是**旧 PHP 错误日志触发**，不是内核崩溃，也不是当前插件持续崩溃。
- 日志中的插件条目是 10-18 的 `GeneralController::getNodes()`（v1.0.7 已修）；其余是调试期 `php -r` 用错 `/etc/inc/config.inc` 路径。
- 核心的 `dismissStatus()` 会删除 `/var/crash/*` 并 `unlink('/var/lib/php/tmp/PHP_errors.log')`；这是唯一正确的清理入口。

#### 3.6.2 处置流程（已按测试 VM 定稿）

1. 先归档证据（不提交、不公开）：把 `PHP_errors.log` 复制到 `.private/`（已被 gitignore），记录文件大小/mtime；确认没有 2026-10-20 之后的新条目、没有当前插件的堆栈。
2. 用 WebGUI 的 System Status 弹窗点击 Crash Reporter 条目的“×”（或 `crash_reporter.php` 的 dismiss），清除日志与 `/var/crash/*`。
   - **2026-10-24 已执行**：日志已归档到 `.private/vm-php-errors-20261024.log`（gitignored），测试 VM 上的旧 `PHP_errors.log` 已删除；`/var/crash/minfree` 保留未动；`CrashReporterStatus` 条件已清除。刷新 WebGUI 后弹窗应消失。
3. 清理后验证：刷新页面确认弹窗消失；连续加载 5 个插件页面各 10 次；确认 `PHP_errors.log` 不被重新创建（或只有非插件错误）。
4. 如果清理后又出现：立即抓取 `ls -la /var/crash/`、`PHP_errors.log` 尾部、`configctl system status` 输出，再判断是否新崩溃；不要在未取证前反复清理。
5. **不修改核心文件**、不 patch OPNsense、不关闭全局崩溃报告；生产机不适用本流程（本次仅测试 VM）。

#### 3.6.3 防复发

- 新增页面/新增 API 必须：`php -l` 通过、API 不可达返回结构化错误、不抛未捕获异常、不产生 PHP warning。
- VM 验收把“加载新页 20 次后 `PHP_errors.log` 无新增插件条目”列为门禁。
- 不要为了“让弹窗消失”而清空日志掩盖新错误；先确认日志内容。

---

### 3.7 R6/R7：零 emoji 与硬编码清理

#### 3.7.1 零 emoji 规则

- 插件自有内容（`.volt`、`forms/*.xml`、`Menu.xml`、`ACL.xml`、PHP/JS 中的按钮/标签/提示/对话框）**不得新增 emoji**；统一用 `<i class="fa ...">`。
- 订阅带来的组名/节点名是数据，含 emoji/中文/引号时**原样展示**，不得剥离或改写（否则与 Windows/Clash 客户端、规则目标对不上）。若后续希望界面隐藏订阅表情，可另加“简洁显示”开关（仅影响显示、不改值）；1.2.0 不做，默认保持原始名称。
- 文档示例一律用占位符（`组A`、`节点组B`、`节点组C`），不复制真实订阅名称或表情。
- 新增 `tests/test_ui_no_emoji.sh`：扫描插件的视图/表单/菜单/ACL，命中 emoji 区段即失败；订阅数据不在扫描范围。

#### 3.7.2 硬编码清理清单（已核实）

| 位置 | 现状 | 处理 |
| --- | --- | --- |
| `transport_render.php:23` | `DEV_PF_TEMPLATE` 写死个人绝对路径 | 删除该常量；模板查找 = 运行期安装路径 + 可选 `--template <path>` CLI 参数（测试用）；**不新增环境变量**；既有 `MIHOMO_LAN_*` 只是兼容测试钩子，新代码不使用 |
| `Api/StatusController.php:48` | `pluginVersion = '1.0.9'` | 改为读取 `version/mihomo`；失败回退 `unknown`，不再写死版本 |
| `views/.../index.volt` JS | `currentApiPort = '9090'`、`bind || '127.0.0.1'`、`port || '9090'` | 只用 `getGeneral` 返回值；缺失时显示 `-` 并禁用链接；HTML 初始占位不写死 `:9090` |
| `Api/GeneralController.php` | 多处 `'9090'`/`'127.0.0.1'` 回退（`:237/:242/:274/:306/:385`） | 收敛为类常量 `DEFAULT_API_PORT`/`DEFAULT_API_BIND`（与模型默认值一致），不再散落字面量 |
| `packaging/freebsd/+POST_INSTALL` | 迁移逻辑内 `"9090"` 与 `_target_port="9090"` | 从 config.xml/配置读取；缺失时才用单一默认常量；遵守 +POST_INSTALL 禁 `%`/反斜杠续行约束 |
| `etc/mihomo/setup.sh:165` | `API_PORT=9090` | 从 `/usr/local/etc/mihomo/config.yaml` 读取；缺失时用单一默认常量；**不新增环境变量** |
| `sub/sub.sh:312`、`sub_lib.sh:686-687` | 解析失败回退 `127.0.0.1 9090` | 保留为“最后兜底”，但集中为常量并注释原因；不得覆盖已解析出的面板端口 |
| `tests/*.sh` | 使用 `192.168.50.2`/`192.168.1.10`/`10.9.9.9` 等私网地址 | 改为 TEST-NET（`192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`）；端口尽量动态 |
| `README.md`/`README.US.md` | 仍写“强制 `127.0.0.1:9090`”，与 v1.0.8 可配置不符 | 改为“默认回环 9090，可在面板配置绑定地址/端口”；保留不要暴露 WAN 的安全建议 |
| `docs/WEBGUI.md`/`docs/SUBSCRIPTION.md` | 可能含旧端口/地址表述 | 同步为默认值 + 可配置表述 |
| 其它插件样例 | `os-easytier`/`os-sing-box`/`os-ddns-go`/`os-ddclient-opnwall` 有私网/样例凭据 | 本包不修；列入开源前逐项复查（区分上游示例与真实值） |

原则：**生产值只来自模型/配置/模板**；默认值允许存在，但必须集中、可解释；**不新增环境变量**（既有测试钩子保持兼容，不扩散）；测试/文档不得出现真实环境值。

### 3.8 R8：开源前脱敏（P0，发布前必须完成）

#### 3.8.1 工作区

- **内部交接文档**：内部交接文档（已从公开历史移除）含测试/生产防火墙私网地址、WebGUI 默认账号口令、SSH 登录方式、个人路径与工作流；`progress.md` 含私网地址。处理方式：移到 `.private/`（已 gitignore）或从公开树删除，**不在公开仓库保留**；本地保留用于交接。
- **源码个人路径**：`transport_render.php` 的 `DEV_PF_TEMPLATE` 必须清除（见 §3.7.2）。
- **文档示例**：`docs/DESIGN-panel-features-v2.md` 等含私网地址的示例改为占位符；本方案与两份审计报告已脱敏。
- **构建产物**：`output/*.pkg`、`repo/` 二进制包可能内嵌构建路径/作者邮箱；公开仓库默认排除，发布包单独分发。`output/build-info.json` 确认只含版本/commit/哈希，不含构建用户/路径。
- **作者身份**：`LICENSE`、`README`、`version/mihomo` 的 `product_email`、提交作者邮箱需统一为公开身份；公开前逐项确认。
- **其它插件**：`src/os-*` 下的样例 IP/凭据逐项复查；不确认是上游示例的一律替换。

#### 3.8.2 Git 历史（需要单独授权，不能悄悄做）

- 只读扫描已确认：历史中有 9 个提交包含用户网段；作者邮箱有 5 个。即使工作区清理干净，`git log -p` 仍能拿到。
- 公开前二选一：
  - **A. 干净历史**：用 `git filter-repo` 重写（需备份 + 强推协调；会改写所有 commit hash）。
  - **B. 干净快照**：导出当前工作区为全新 orphan 提交/新仓库，不带历史；最安全、最简单。
- **本方案不执行历史重写**；需要用户明确选择 A/B 并授权后再做。任何强推/重写前先做完整备份（`git bundle` + 目录快照）。

#### 3.8.3 防复发门禁

- 新增 `scripts/audit-sensitive.sh`：
  - 若存在 `.private/sensitive-patterns.txt`（gitignored），按其中真实网段/口令/路径扫描 tracked 文件；
  - 否则执行通用检查：`/home/<user>`、OPNsense 默认账号口令、`password=`/`secret=` 明文、邮箱、私网 IPv4（TEST-NET/RFC1918 示例需显式 allowlist）；
  - 命中即非 0，输出文件:行号（不打印命中值本身）。
- 新增 `tests/test_no_sensitive.sh` 包装上述脚本；CI/本地全量测试必须通过。
- 新增 `docs/OPENSOURCE-READINESS.md`：公开前检查清单（工作区、历史、产物、作者身份、依赖许可证、示例配置）。
- 可选 `scripts/export-public.sh`：复制 tracked 文件到 `dist/public/`，排除内部交接文档（已从公开历史移除）、`progress.md`、`work/`、`output/`、`repo/`、`.private/`，随后运行敏感信息扫描。

---

## 4. 文件包划分（严格互斥，供并行编码）

| 包 | 内容 | 允许修改/新建 | 依赖 |
| --- | --- | --- | --- |
| A | 状态语义 + 运行时模式切换 | `scripts/OPNsense/Mihomo/service_manager.sh`、`Api/StatusController.php`（含 `getMode`/`setMode`、去掉 `1.0.9` 硬编码）、`views/.../status.volt`、`tests/test_status_display.sh` | 无 |
| B | 常规页与共享样式 | `views/.../index.volt`（含去掉 9090/127.0.0.1 JS 回退）、`views/.../styles.volt`、`tests/test_webgui_pages.sh`（仅维护与 `index.volt` 相关的既有断言，**不新增** Menu/ACL 断言） | 无（styles 先定稿） |
| C | 策略组页 | `controllers/.../ProxiesController.php`、`Api/ProxiesController.php`、`views/.../proxies.volt`、`Menu/Menu.xml`、`ACL/ACL.xml`、`tests/test_proxies_page.sh`（含新页 Menu/ACL/控制器断言） | B 的样式类名 |
| D | 规则页选择器 | `views/.../rules.volt`、`tests/test_rules_page.sh` | B 的样式类名 + C 的 API 契约 |
| E | 版本与发布文档 | `version/mihomo`、`Makefile`、`build.sh`、`scripts/build.sh`、`docs/WEBGUI.md`、`output/SHA256SUMS`、`output/build-info.json` | A–D 完成后 |
| G | 硬编码清理 | `scripts/OPNsense/Mihomo/transport_render.php`（删个人路径）、`etc/mihomo/setup.sh`、`packaging/freebsd/+POST_INSTALL`、`Api/GeneralController.php`（收敛默认端口/绑定常量） | 无（文件与 A/B/C/D 不重叠） |
| F | 开源脱敏（P0） | `tests/test_ui_no_emoji.sh`、`tests/test_no_sensitive.sh`、`scripts/audit-sensitive.sh`、`scripts/export-public.sh`、`docs/OPENSOURCE-READINESS.md`、`.gitignore`、`README*.md`/`docs/DESIGN-panel-features*.md` 占位化、内部交接文档（已从公开历史移除）/`progress.md` 移入 `.private/` | G/A/B 完成后跑扫描 |

约束：

- `styles.volt` 只由 B 修改；C/D 只能使用 §5 已定义的类，不得新增/改名。
- `RulesController.php` **不修改**（规则校验逻辑不动）；D 只改视图。
- `Menu.xml`/`ACL.xml` 只由 C 修改。
- 任何包不得触碰 `config.yaml` 合成逻辑、`sub.sh`、`sub_lib.sh`、secret 管理、状态机。
- `sub.sh`/`sub_lib.sh` 的 `127.0.0.1 9090` 仅作为配置不可解析时的最后兜底，保留并注释，不在本版改造。
- 内部交接文档（已从公开历史移除）/`progress.md` 只移动/脱敏，不删除本地内容；Git 历史重写不在任何包内，需单独授权。

---

## 5. 共享样式类名（B 定义，C/D 只使用）

在现有 `styles.volt` 基础上新增：

```css
.mihomo-kv
.mihomo-kv th
.mihomo-kv td
.mihomo-section
.mihomo-section-title
.mihomo-copy-btn
.mihomo-badge-warn
.mihomo-proxy-layout
.mihomo-group-list
.mihomo-group-item
.mihomo-group-item.is-active
.mihomo-node-grid
.mihomo-node
.mihomo-node.is-current
.mihomo-node.is-disabled
.mihomo-delay
.mihomo-delay.is-good
.mihomo-delay.is-warn
.mihomo-delay.is-bad
.mihomo-picker-search
.mihomo-picker-list
.mihomo-picker-item
.mihomo-picker-item.is-active
```

视觉约束：白底、`#e3e3e3` 边框、4px 圆角、橙色 `#d94f00` 强调；禁止深色控制台配色；767px 以下纵向堆叠；sticky 表头沿用 `#f5f5f5`。

文案约束：插件自有标签/按钮/提示/对话框**零 emoji**，图标一律 Font Awesome；订阅组名/节点名按数据原样显示，不做表情剥离或改写。

---

## 6. 安全与红线

1. **secret 不进 argv**：新增 API 全部使用 0600 临时 curl 配置（`-K`），`try/finally` 删除；禁止 `-H "Authorization: ..."` 回退；`ps auxww` 抽查不得出现 secret。
2. **CSRF**：所有写操作（`select`、`setMode`）走 `ajaxCall` POST；只读为 GET。
3. **输入白名单**：`group`/`name` 必须与实时 `/proxies` 精确匹配；`mode` 只接受 `rule|global|direct`；`rawurlencode` 路径段；长度上限 128；拒绝控制字符。
4. **SSRF**：1.2.0 不提供测速/外部 URL 输入；未来若新增测速，必须固定目标 URL，不接受用户传参。
5. **XSS**：动态文本一律 `.text()`；`rules.volt`/`proxies.volt` 禁止 `.html(`/`innerHTML`。
6. **响应白名单**：组只下发 `{name,type,now,count,selectable}`，节点只下发 `{name,type,current,delay}`；禁止原始 proxy 对象与 `extra/server/port/provider-name/dialer-proxy/history`。
7. **零硬编码**：视图/控制器不得出现 `:9090`；端口/绑定取自模型与配置；不得出现 `/home/<user>` 或个人路径。
8. **流式读配置**：`config.yaml` 的 `external-controller/secret/mode` 必须 `fopen`+`fgets` 提前退出（≤256KB）；禁止 `file()`/`file_get_contents()`（17MB/357k 规则）。
9. **HTTP 语义**：`PUT /proxies` 与 `PATCH /configs` 的 `200` 与 `204` 均为成功；204 空体不得判失败。
10. **不写配置**：策略组页只改 mihomo 运行时选择；状态页 mode 只改运行时；都不写 `config.yaml`、不触发 recompose、不持锁。
11. **控制面/数据面解耦**：API 不可达只影响页面可用性，不得杀进程、不得改服务状态。
12. **超时与上限**：`curl -m 3/5/6`；组 ≤200、节点分页 ≤500、响应 ≤4MiB；**不提供主动测速接口**（避免 PHP-FPM 阻塞）；前端轮询防叠加。
13. **配置优先**：不新增环境变量；生产值来自模型/`config.yaml`/模板；测试专用参数用 CLI 或测试配置文件。
14. **开源红线**：不得把真实私网地址、WebGUI 账号口令、SSH 私钥/口令、个人绝对路径、真实订阅链接/密钥、作者私人邮箱写入代码/测试/文档/提交信息；敏感信息 lint 必须通过。
15. **测试红线**：保留 v1.1.0 全部断言；新增页面必须覆盖 XSS、`:9090`、超时、不可达分支、204 分支、流式读取静态断言、零 emoji、敏感信息扫描。

---

## 7. 测试与验收

### 7.1 静态/单元

- 现有 19 个 `tests/test_*.sh` 全部通过。
- 新增 `tests/test_proxies_page.sh`：
  - 文件存在、`php -l`（在 VM 上跑）
  - 视图含 `mihomo-proxy-layout`、`mihomo-group-list`、`mihomo-node-grid`、`#btn_refresh_proxies`、搜索框、模式徽章、`inFlight`/`requestSeq` 防叠加逻辑、分页控件
  - 视图无 `.html(`、无 `:9090`；含 `.text(`
  - API 控制器含 `rawurlencode`、`-K`、`tempnam`、`chmod`、`unlink`/`finally`、`m 5`、`m 6`、`Selector` 校验、`204` 成功判据、`fopen`/`fgets`、`getNodes` 的 `offset/limit/q/total/truncated`
  - API 控制器**不得**含 `file(` / `file_get_contents(`；**不得**含 `delay?` / `/delay` / `gstatic`（主动测速已移出范围）
  - 响应字段白名单负向断言：控制器不得输出 `extra`/`server`/`provider-name`/`dialer-proxy`
  - Menu/ACL 含新页 pattern，且 ACL 有独立 `<page-services-mihomo-proxies>` 节点（新页断言全部放在本测试，不放 `test_webgui_pages.sh`）
- 扩展 `test_status_display.sh`：`接入：透明代理`/`接入：仅代理`/`接入：直连`、`内核模式`、`stat_core_mode`、`#core_mode_select`、`#btn_core_mode_apply`、`配置默认`；保留 `data.transport_mode === 'transparent'`、TUN 三态、SOCKS 无 `label-danger`。
- 状态页 API 断言：`StatusController` 含 `getModeAction`/`setModeAction`；`mode` 白名单 `rule|global|direct`；`PATCH /configs`；`200`/`204` 成功判据；`-K` + `tempnam` + `chmod` + `finally`；不得含 `file(`/`file_get_contents(`；不得含 `:9090`。
- 扩展 `test_webgui_pages.sh`：只维护与 `index.volt`/既有页面相关的断言（Menu 既有 4 项、既有 ACL 断言、`styles.volt` 新类、视图 id 保留）；不新增新页断言，避免与 C 的 Menu/ACL 变更形成先后依赖。
- 扩展 `test_rules_page.sh`：`rule-target-picker`、hidden `.rule-field-target`、`buildTargetPicker` 同时被 `createTableRow`/`parseTextToTable` 使用、picker 选中后 `trigger('change')`/`updateCounter`、未知目标回显、实时/离线徽章、无 `.html(`、无 `:9090`。
- 状态写入断言（可放 `test_status_display.sh`）：`service_manager.sh` 不得再出现 `set_state "RUNNING" "PROXY"`、`set_state "DEGRADED" "PROXY"`，且包含 `TRANSPARENT` 分支（覆盖 `:335/:338/:490/:494` 全部写入点）。
- 新增 `tests/test_ui_no_emoji.sh`：插件自有 `.volt`/`forms/*.xml`/`Menu.xml`/`ACL.xml` 无 emoji；订阅数据不在扫描范围。
- 新增 `tests/test_no_sensitive.sh`：调用 `scripts/audit-sensitive.sh`；工作区不得出现 `/home/<user>`、真实私网/凭据/邮箱；`.private/sensitive-patterns.txt` 存在时按真实模式扫描。
- 硬编码守卫：`transport_render.php` 无 `/home/`；`StatusController` 无 `'1.0.9'` 版本字面量；`index.volt` 无 `'9090'`/`'127.0.0.1'` 回退；新页/状态页视图无 `:9090`。

### 7.2 VM 实测（<TEST_VM_LAN_IP>）

1. 装包后健康门禁通过；5 个页面 HTTP 200。
2. 状态页：无副标题；`接入：透明代理` + `内核模式` 运行时值 `规则分流` + `配置默认：规则分流`；原始 JSON 的 `"mode"` 为 `TRANSPARENT`；服务停止时运行时值显示 `-`。
3. **运行时模式切换**：切到 `global`，`GET /configs` 返回 `"mode":"global"`；切回 `rule`，返回 `"mode":"rule"`；`config.yaml` 内容不变；重启 mihomo 后回到 `rule`；非法 `mode` 被服务端拒绝。
4. 常规页：三段式布局；端口徽章动态；复制端点可用、无复制密钥按钮；密钥三按钮行为不变；通配地址警告显示；JS 无 `9090`/`127.0.0.1` 回退。
5. 策略组页：加载 15 组/45 节点；**用“切换到当前同一节点”的幂等方式验证 `PUT` 返回 204 且 UI 判成功**；Selector 组切换节点并切回；URLTest 组节点只读；节点搜索/翻页正确；API 停止时显示不可达且不崩；连续轮询 2 分钟无请求叠加（Network 面板）；触发一次 `configctl mihomo healthcheck` 后 `state.json.mode` 仍为 `TRANSPARENT`（验证 `do_healthcheck` 已修）。
6. 规则页：选择器显示实时组；选择后 `updateCounter` 生效；源码模式切回表格模式后目标列仍是选择器且未知目标不丢；选中组名保存/应用成功；伪造非法目标被服务端拒绝；生效规则正确。
7. 安全：请求期间 `ps auxww | grep -c '<secret>'` 为 0；响应无 secret；响应不含 `extra`/`server`/`provider-name`；受限 ACL 角色访问策略组页按预期 200/403（不越权）。
8. UI 文案：插件自有页面/对话框无 emoji；订阅组名/节点名原样显示。
9. 崩溃：先归档 `PHP_errors.log`（确认无新插件条目）→ 核心 UI dismiss → System Status 弹窗消失；加载 5 个页面各 10 次后 `PHP_errors.log` 不出现插件条目。
10. 开源脱敏：`tests/test_no_sensitive.sh` 通过；`git grep` 不再命中真实私网/凭据/个人路径；内部交接文档（已从公开历史移除）/`progress.md` 不在公开树；`output/`/`repo/` 不随公开仓库分发。
11. 打包：`scripts/build.sh` + `verify-package.sh` 通过；版本 1.2.0；`output/SHA256SUMS`/`build-info.json` 重新生成。

---

## 8. 风险与回滚

| 风险 | 缓解 |
| --- | --- |
| `state.json` 的 `mode` 取值变化影响未知消费方 | 已核对：仅 `system_status.py` 读取，watchdog 不读；保留键名只改值；测试覆盖 + VM 实测 |
| 新增页 ACL 漏配 → 403 | `tests/test_proxies_page.sh` 断言 pattern；VM 用非 admin 组验证 |
| `config.yaml` 17MB 被每 10 秒全量读取 → OOM/CPU 飙升 | 强制 `fopen`+`fgets` 提前退出（≤256KB）；静态断言禁止 `file()`；VM 压测 2 分钟 |
| `/proxies` 响应过大或含敏感字段 | 轻量 `getGroups` 不返回节点 + `getNodes` 分页（≤500）+ 字段白名单 + 4MiB 上限 |
| `PUT /proxies` 204 空体被误判失败 | 200/204 均成功；VM 幂等切换验证 |
| 轮询叠加导致旧数据覆盖新数据 | `inFlight` + `requestSeq`；10s；隐藏页暂停；VM Network 面板验证 |
| 批量/主动测速耗尽 PHP-FPM worker | **移出范围**：不提供 `/delay` 接口；只读展示 `history` 最近延迟 |
| `do_healthcheck` 漏改导致 mode 回弹 | 统一 `:335/:338/:490/:494` 四处写入；VM 触发 healthcheck 验证 |
| 运行时切换重启后丢失 | 页面明确提示“仅对当前运行生效”；不承诺持久化 |
| 误切 `global`/`direct` 导致分流失效 | 下拉框 + 应用按钮 + 结果提示；不提供一键快捷；状态卡同时显示“配置默认”；VM 切回 `rule` 验证 |
| 崩溃弹窗清理后复发 | 先归档日志取证；确认无新插件错误再 dismiss；加载 20 次验证；不靠反复清空掩盖 |
| 开源后历史仍含敏感信息 | 工作区清理 + 历史扫描；公开前选“干净历史”或“干净快照”；未授权前不强推/重写 |
| 个人路径/版本号/端口回退残留 | 硬编码清单逐项清除 + `test_no_sensitive.sh` + 静态守卫 |
| 视图改动破坏既有 id/测试 | 逐项保留 id 清单；测试先跑 |

回滚：`pkg add -f` 上一版本包；策略组切换为运行时状态，重启即回订阅默认；无持久化副作用。

---

## 9. 实施顺序与工作量估算

| 阶段 | 内容 | 估算 |
| --- | --- | --- |
| 0 | 方案审计 + 用户决策（已完成） | 0.2d |
| 1 | A（状态/模式切换）+ B（常规页/styles）+ G（硬编码清理）并行 | 0.7d |
| 2 | C（策略组页）与 D（规则页选择器）并行 | 1.5d |
| 3 | E（版本/发布文档）+ F（开源脱敏/门禁） | 0.5d |
| 4 | 主控逐文件审计 + 全量测试 | 0.3d |
| 5 | VM 部署与验收 | 0.5d |

模型分工沿用既有模式：主控设计/拆包/终审；编码子 agent 仅用 gemini / deepseek（按用户 2026-10-18 协作模式），禁止降级其它模型。

---

## 10. 已确认决策与仍需授权的事项

### 已确认（v0.4）

1. **Crash Reporter 来自测试 VM**：根因是 `PHP_errors.log` 存在（核心同时看该日志），不是内核崩溃。流程：归档日志 → 确认无新插件错误 → 核心 UI dismiss → 复查。生产机不适用。
2. **`transport_mode` 默认值保持 `proxy`**：不改模型默认值；运行时可在常规页切换透明代理。
3. **WebGUI 运行时 rule/global/direct 切换：要做**：放状态页，`getMode`/`setMode`，仅运行时、不持久、重启回 `rule`。
4. **策略组页不做选择持久化**：运行时切换 + 重启/订阅更新回默认，符合 Clash 语义。
5. **版本号 1.2.0**。
6. **GLOBAL 组默认隐藏 + 开关**：避免与 PROXY 重复，但保留入口。

### 仍需授权/确认

7. **Git 历史如何处理**：工作区脱敏不能清除历史中的 9 个提交（含用户网段）与 5 个作者邮箱。公开前二选一：
   - **A. 干净快照（推荐）**：导出当前工作区为全新 orphan 提交/新仓库，不带历史；最简单、最安全。
   - **B. 重写历史**：`git filter-repo` + 备份 + 强推协调；会改写所有 commit hash。
   两者都需要您明确授权；本方案不执行任何历史重写/强推。
8. **公开身份**：`LICENSE`、`README`、`version/mihomo` 的 `product_email`、提交作者邮箱是否统一换成项目公开身份（而非个人邮箱）？建议统一为项目中性身份，并在公开前用 `.mailmap` 或全新历史固化。
9. **公开仓库范围**：本 workspace 含 `os-mihomo` 与 `os-easytier`/`os-sing-box`/`os-ddns-go`/`os-ddclient-opnwall` 等其它插件源码、`repo/` 二进制包、`output/` 构建产物。建议公开仓库只含 os-mihomo 源码与文档，二进制包单独发布；其它插件逐项复审后再决定。

---

## 11. 给审计员的检查清单

1. R5 的判断是否成立：`state.json.mode` 与 mihomo `/configs.mode` 是否确实不是一回事？修 `service_manager.sh` 是否会影响状态机/watchdog/测试？
2. R4 新增 API 的 secret 处理、CSRF、输入白名单、SSRF、XSS 是否有遗漏？
3. `/proxies` 大订阅（数百组/数千节点）下的性能与响应上限是否足够？10s 轮询 + 节点分页是否合理？
4. 规则页把 `<select>` 换成 hidden input + 按钮，是否破坏现有序列化/源码模式/数据行号逻辑？
5. ACL/Menu 变更是否会导致 403 或顺序回归？
6. Crash Reporter 处置流程是否安全（先取证、不碰核心、测试 VM 专用）？
7. 文件包划分是否有隐性冲突（尤其 `styles.volt`、`Menu.xml`、`RulesController.php`、`GeneralController.php`）？
8. 是否遗漏 v1.1.0 既有红线（35 万规则分页、secret 门禁、控制面/数据面解耦）？
9. 运行时 `PATCH /configs` 的 200/204、超时、白名单、CSRF、secret 处理是否完整？是否真的不落盘？
10. 零 emoji 规则是否会误伤订阅数据展示？文档/示例是否还有真实组名或表情？
11. 硬编码清理是否引入新的默认值不一致（模型/模板/panel-state/config.yaml 五处）？
12. 开源脱敏是否覆盖工作区、Git 历史、`output/`/`repo/` 二进制、作者身份与其它插件样例？
