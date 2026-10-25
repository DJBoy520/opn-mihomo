# os-mihomo 1.2.0 并行编码任务书

> 必须先读 `docs/DESIGN-1.2.0-ui-refresh.md`（v0.4）。本文件只补充实现细则与文件边界。
> 基线：`secure-mihomo` @ `3576923`。禁止 git commit / push / 改版本号；禁止修改本包之外的任何文件。
> 目标：界面更清爽、信息分组、少 emoji、无新增环境变量、配置/模型优先。

---

## 0. 全局规则

1. **语言**：所有用户可见文案用简体中文；技术标识（DIRECT/REJECT/Selector/URLTest/rule/global/direct）保留英文。
2. **零 emoji**：插件自有标签/按钮/提示/对话框不得出现 emoji；图标只用 `<i class="fa ...">`。订阅组名/节点名是数据，原样显示。
3. **配置优先**：不新增环境变量。生产值来自模型/`config.yaml`/模板；测试专用参数用 CLI 参数或测试配置文件。既有 `MIHOMO_LAN_*` 测试钩子保持兼容，不扩散。
4. **零硬编码**：视图/控制器不得出现 `:9090` 字面量；不得出现个人绝对路径（`/home/...`）；端口/绑定/版本从配置或版本文件读取。
5. **安全**：secret 只能通过 0600 临时 curl 配置文件 `-K` 传入，`try/finally` 删除；禁止进 argv；CSRF 走 `ajaxCall`；动态文本只用 `.text()`；禁止 `.html(`/`innerHTML`。
6. **不写配置**：策略组选择、运行时 mode 只改 mihomo 运行时状态，不写 `config.yaml`/模板/模型。
7. **性能**：读 `config.yaml` 必须 `fopen`+`fgets` 提前退出（≤256KB），禁止 `file()`/`file_get_contents()`；`/proxies` 只输出白名单字段；组 ≤200、节点分页 ≤500、响应 ≤4MiB。
8. **测试**：每个包完成后至少跑 `sh -n`（shell）或 Python XML 解析（XML）；视图改动要同步更新本包测试；不要留下失败断言。

---

## 1. 包 A：状态页 + 运行时 mode 切换

### 文件（只改这些）
- `src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/service_manager.sh`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/StatusController.php`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/status.volt`
- `tests/test_status_display.sh`

### service_manager.sh
- 把所有 RUNNING/DEGRADED 的 `"PROXY"` 写入改为按 `transport_mode_now()` 计算：`PROXY` / `TRANSPARENT`；覆盖 `:335`、`:338`、`:490`、`:494` 与 `:336` echo；注释 `# Modes:` 更新。
- 不改变状态机/退出码/watchdog 行为；POSIX sh。

### StatusController.php
- `core_mode`：流式读 `config.yaml` 的 `^mode:`，白名单 `rule|global|direct`，回退 `rule`。
- `pluginVersion`：读 `version/mihomo`，失败 `unknown`；删除 `'1.0.9'`。
- 新增 `getModeAction`：流式读 API 地址/secret；`GET /configs`（`-m 3`），返回 `{status:'ok',reachable:bool,mode:?string,config_mode:string}`；secret 用 `-K` 0600 临时文件，`finally` 删除。
- 新增 `setModeAction`：POST `mode` 白名单；`PATCH /configs` body `{"mode":"..."}`（不是 PUT）；`-m 5`；`-w "\n%{http_code}"`；200/204 成功；返回 `{status:'ok'|'failed',mode,message}`；不写配置文件。
- 不改变 `getMihomoStatusAction` 现有返回字段（可增加 `core_mode`）；RUNNING 缺省 mode 从 `PROXY` 改 `UNKNOWN`。

### status.volt（重排，减少混杂）
```
.mihomo-page
  .mihomo-card 服务概览
    .mihomo-card-head: 标题「服务概览」+ 右侧 #btn_refresh_status
    .mihomo-stat-grid (3 列)
      .mihomo-stat: 服务状态 -> #stat_state_desc；下方 #stat_tun + #stat_api 小徽章
      .mihomo-stat: 接入方式 -> #stat_mode；下方 #stat_transport 小字
      .mihomo-stat: 内核模式 -> #core_mode_select + #btn_core_mode_apply
                     下方 #core_mode_config（配置默认：…）+ #core_mode_msg
  .mihomo-card 运行指标
    .mihomo-metric-grid (4 列): #stat_uptime / #stat_memory / #stat_pid / 版本
  .mihomo-card 诊断详情（默认折叠）
    按钮/链接切换；表格保留 #stat_commit/#stat_message/#stat_last_change/#stat_raw
```
- 删除副标题 `status.volt:91`。
- 保留全部既有 id；新增 `#core_mode_select`、`#btn_core_mode_apply`、`#core_mode_msg`、`#core_mode_config`。
- JS：`loadRuntimeMode()` 调 `getMode`；select 选项 `rule/global/direct`（规则分流/全局代理/直连）；应用按钮 POST `setMode`，成功后提示并刷新，失败显示 message；无 emoji；不覆盖 4 秒状态轮询。
- 文案：`接入：透明代理/仅代理/直连`；TUN `正常/断开/SOCKS`；API `正常/不可用`。

### tests/test_status_display.sh
- 更新 `模式：*` 断言为 `接入：*`；增加 `#core_mode_select`、`#btn_core_mode_apply`、`配置默认`、`getMode`/`setMode`、`PATCH /configs`、200/204、`-K` 等静态断言；保留 TUN/SOCKS/轮询断言。
- 断言 `service_manager.sh` 不再出现 `set_state "RUNNING" "PROXY"` 与 `set_state "DEGRADED" "PROXY"`，且包含 `TRANSPARENT`。

---

## 2. 包 B：常规页 + 共享样式

### 文件
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/index.volt`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/styles.volt`
- `tests/test_webgui_pages.sh`（只维护既有断言，不新增新页 Menu/ACL 断言）

### styles.volt
- 保持既有类名可用；新增清爽卡片体系：`.mihomo-card`、`.mihomo-card-head`、`.mihomo-card-title`、`.mihomo-card-body`、`.mihomo-stat-grid`、`.mihomo-stat`、`.mihomo-stat-label`、`.mihomo-stat-value`、`.mihomo-metric-grid`、`.mihomo-metric`、`.mihomo-kv`、`.mihomo-section`、`.mihomo-guide`、`.mihomo-mode-row`、`.mihomo-chips`、`.mihomo-chip`、`.mihomo-proxy-layout`、`.mihomo-group-list`、`.mihomo-group-item`、`.mihomo-node-grid`、`.mihomo-node`、`.mihomo-delay`、`.mihomo-picker-*`、`.mihomo-copy-btn`、`.mihomo-empty`。
- 白底、`#e3e3e3` 边框、6px 圆角、轻阴影；橙色 `#d94f00` 只作强调；不使用深色控制台配色；767px 以下单列。
- 不覆盖 OPNsense 全局选择器；只允许 `.mihomo-*`。

### index.volt
- 四张卡片，统一 `.mihomo-card` 结构；每张标题用 `.mihomo-card-head`，副标题只在必要时保留一句。
- 服务控制：工具栏紧凑（按钮 + 状态徽章），不要大段说明。
- 运行参数：`base_form` 外套 `.mihomo-form-wrap`（max-width 760px），保存按钮工具栏。
- 面板与 API：
  - 标题右侧动态端口徽章 `#api_header_port`。
  - `.mihomo-kv` 2 列表：内置面板（#api_bundled_link + #btn_copy_api_endpoint）、API 端点（#api_endpoint_display + 复制）、当前监听（#api_bind_badge）、认证密钥（#api_secret_masked + 查看/生成）。
  - #api_wan_warn 仅在通配绑定时显示。
  - 自定义密钥放进 `<details>`/collapse（保留 #api_secret_custom/#btn_secret_apply/#api_secret_help）。
  - 客户端接入放在 `.mihomo-guide` 简洁框内（保留 #api_dashboard_guide/#api_guide_content）。
  - 删除 JS 中 `'9090'`/`'127.0.0.1'` 回退；`updateApiDisplay` 缺值时显示 `-` 并禁用链接/复制。
- 订阅与策略：
  - URL 全宽；自动更新 + 周期 + 策略来源做成 2 列紧凑布局。
  - 保存/立即更新放工具栏。
  - 最近更新改为紧凑 2 列 `.mihomo-kv`：时间/结果、节点/来源、组数/规则数、消息（跨列）；保留全部 id。
- 保留所有现有 id 与订阅 JS 轮询/密钥逻辑；所有用户可见英文改中文；无 emoji。

### tests/test_webgui_pages.sh
- 保持既有 Menu/ACL/模型/路由断言；新增 `styles.volt` 新类、`index.volt` 新结构 id 的静态断言；不要新增新页断言。

---

## 3. 包 C：策略组页（metacubexd 风格）

### 文件
- `controllers/OPNsense/Mihomo/ProxiesController.php`（页面）
- `controllers/OPNsense/Mihomo/Api/ProxiesController.php`
- `views/OPNsense/Mihomo/proxies.volt`
- `models/OPNsense/Mihomo/Menu/Menu.xml`
- `models/OPNsense/Mihomo/ACL/ACL.xml`
- `tests/test_proxies_page.sh`

### API（严格按设计 §3.4.2）
- `getGroups`：轻量，不返回节点明细；字段 `{name,type,now,count,selectable}`；可选 `include_global=1`；组 ≤200；4MiB 上限；不可达返回 `reachable:false`。
- `getNodes`：`group,q,offset,limit`；返回 `{name,type,current,delay}` + `total/offset/limit/truncated/query`；limit 默认 100、上限 500；`delay` 只取 `history` 最后一条，不主动测速。
- `select`：POST `group,name`；实时 `/proxies` 精确校验、仅 Selector、`name ∈ all`；`PUT /proxies/{rawurlencode(group)}` body `{"name":...}`；200/204 成功；`-m 6`。
- 读配置必须流式；secret `-K` 0600 + `finally`；无 `file()`；无 `:9090`；无 `delay` 接口。
- 所有错误结构化返回，不 500。

### 页面
- 标题「策略组」，工具栏：搜索、刷新、自动刷新（10s，默认开）、内核模式徽章、显示 GLOBAL 开关。
- 左右两栏：组列表（名称/类型/当前/数量）与节点区（标题 + 当前 + 搜索 + 分页 + 节点卡片）。
- 节点卡片：名称、类型、当前标记、最近延迟徽章；Selector 可点击切换，非 Selector 置灰提示。
- 防轮询叠加 `inFlight`/`requestSeq`；保留选中组/搜索/滚动；API 不可达显示重试。
- 零 emoji；全部 `.text()`；用 B 的类名。

### Menu/ACL
- `Menu.xml` 新增 `Proxies`，order 30，Status/Logs 顺延 40/50。
- `ACL.xml` 新增独立 `<page-services-mihomo-proxies>`：`ui/mihomo/proxies*`、`api/mihomo/proxies/*`。

### 测试
- `tests/test_proxies_page.sh`：文件/路由/Menu/ACL、视图类名/分页/防叠加、API 白名单/`fopen`/`-K`/`finally`/200-204/无 `file(`/无 `/delay`/无 `:9090`、无 `.html(`。

---

## 4. 包 D：规则页目标策略选择器

### 文件
- `views/OPNsense/Mihomo/rules.volt`
- `tests/test_rules_page.sh`

### 要求
- 顶部「允许的目标策略」用 `.mihomo-chips` 分组展示内置动作 + 代理组；数据优先 `GET /api/mihomo/proxies/getGroups`，离线回退现有 `data.targets`；显示“实时/离线”徽章；链接到 `/ui/mihomo/proxies`。
- 每行目标列：hidden `.rule-field-target` + `.rule-target-picker` 按钮；picker 弹窗搜索、内置/组两段、显示类型/当前/数量。
- 选中后必须 `$input.val(x).trigger('change')`（或 `updateCounter()`）；保留未知/离线目标回显；`createTableRow` 与 `parseTextToTable` 两个调用点都替换；`serializeTableToText` 不改。
- 保留全部既有 id/行号/源码模式/校验逻辑；零 emoji；无 `.html(`/`:9090`。

### 测试
- `test_rules_page.sh` 增加 picker/hidden input/`trigger('change')`/未知目标/实时徽章/无 emoji 断言；保留既有断言。

---

## 5. 包 G：硬编码清理

### 文件
- `scripts/OPNsense/Mihomo/transport_render.php`
- `etc/mihomo/setup.sh`
- `packaging/freebsd/+POST_INSTALL`
- `Api/GeneralController.php`

### 要求
- `transport_render.php`：删除 `DEV_PF_TEMPLATE` 个人路径；模板查找 = 运行期 `/usr/local/etc/mihomo/pf-transport.conf` + 可选 `--template <path>` CLI（测试用）；不新增环境变量；保留既有 `MIHOMO_LAN_*` 兼容钩子但新代码不依赖。
- `setup.sh`：`API_PORT` 从 `config.yaml` 读；缺失时用单一默认常量；不新增环境变量。
- `+POST_INSTALL`：迁移端口从 config.xml 读；默认值集中一处；遵守禁 `%`/反斜杠续行。
- `GeneralController.php`：`9090`/`127.0.0.1` 回退收敛为类常量 `DEFAULT_API_PORT`/`DEFAULT_API_BIND`；行为不变。
- 不触碰 `sub.sh`/`sub_lib.sh` 的兜底逻辑。

---

## 6. 包 F：开源门禁（可与代码并行）

### 文件
- `tests/test_ui_no_emoji.sh`（新建）
- `tests/test_no_sensitive.sh`（新建）
- `scripts/audit-sensitive.sh`（新建）
- `scripts/export-public.sh`（新建，可选）
- `.gitignore`（如需）
- `README.md`/`README.US.md`/`docs/DESIGN-panel-features*.md` 的占位化（只改示例地址/端口表述）

### 要求
- `audit-sensitive.sh`：优先读 `.private/sensitive-patterns.txt`（gitignored）按真实模式扫描；否则通用检查（个人主目录、OPNsense 默认账号口令、明文 password/secret、邮箱、私网 IPv4，TEST-NET/RFC1918 示例 allowlist）；命中输出文件:行号，不打印命中值，退出非 0。
- `test_no_sensitive.sh` 包装；`test_ui_no_emoji.sh` 扫描插件视图/表单/菜单/ACL。
- `export-public.sh`：复制 tracked 文件到 `dist/public/`，排除内部文档/`work/`/`output/`/`repo/`/`.private/`，跑敏感扫描。
- 不要移动/删除内部交接文档（已从公开历史移除）或 `progress.md`（主控后续决定）；不要改 Git 历史。

---

## 7. 交付格式

每个 agent 返回：
- 改动文件列表；
- 关键实现说明（3-6 条）；
- 已运行的检查（`sh -n`、XML 解析、静态 grep）与结果；
- 偏差/未完成项。

不要 commit/push，不要改版本号，不要动本包之外的文件。
