# Secure OPNsense Mihomo — WebGUI 原生 MVC 架构文档 (Phase 3)

> 文档编号：WEBGUI-DOC-001  
> 适用版本：os-mihomo 1.0.2+  
> 架构规范：OPNsense 26.7+ Phalcon MVC  

---

## 一、 WebGUI 架构重构总览

在 Phase 3 中，彻底清除了旧版本存在重大安全隐患的 4 个面向过程 PHP 页面（`src/usr/local/www/mihomo*.php`），并全面迁移至 OPNsense 官方推行的标准 **Phalcon MVC**（Model-View-Controller）架构。

### 1.1 架构对比与安全提升

| 维度 | 改造前 (Legacy Procedural PHP) | 改造后 (OPNsense Native MVC) |
| :--- | :--- | :--- |
| **页面架构** | `src/usr/local/www/` 独立单脚本 | `opnsense/mvc/app/` 分层 MVC (Volt/Controller/Model) |
| **访问控制** | 日志接口缺失 `guiconfig.inc` (严重未授权访问漏洞) | 接入 OPNsense 全局 ACL 鉴权框架 (`ACL.xml`) |
| **CSRF 防护** | 局部自建 `$_SESSION` Token，易被破坏 | 原生集成 OPNsense Session / XSRF Token 保护 |
| **系统调用** | 大量 PHP 直接 `exec()` 调用 Shell | 严格使用 `(new Backend())->configdRun()` 间接调用 |
| **敏感脱敏** | 日志接口明文打印 Secret / Token | `LogsController` 自动过滤 Secret / Token / 密码 / UUID |

---

## 二、 核心 MVC 组件清单

```
src/usr/local/opnsense/
├── mvc/app/
│   ├── models/OPNsense/Mihomo/
│   │   ├── Menu/Menu.xml                 # 菜单声明：Services -> Mihomo -> General/Status/Logs
│   │   ├── ACL/ACL.xml                   # ACL 权限声明：UI 路由与 API 端点权限控制
│   │   ├── Mihomo.php                    # Model 业务对象 (继承 OPNsense\Base\BaseModel)
│   │   └── Mihomo.xml                    # 配置字段 Schema (enabled, log_level, lan_api)
│   ├── controllers/OPNsense/Mihomo/
│   │   ├── IndexController.php           # 页面路由控制器 (提供 index, status, logs 页面)
│   │   ├── forms/general.xml             # General 页面表单定义
│   │   └── Api/
│   │       ├── ServiceController.php     # 服务启停 API (start, stop, restart, reload, status)
│   │       ├── GeneralController.php     # 配置读取与保存 API (getGeneral, setGeneral)
│   │       ├── StatusController.php      # 运行与健康状态 API (7态状态机、TUN、PID、内存)
│   │       └── LogsController.php        # 安全日志查询 API (支持级别过滤与脱敏)
│   └── views/OPNsense/Mihomo/
│       ├── index.volt                    # General 页面视图模板 (开关、日志级别、启停按钮组)
│       ├── status.volt                   # Status 页面视图模板 (版本、哈希、7态运行监控卡片)
│       └── logs.volt                     # Logs 页面视图模板 (带级别过滤的实时日志查看器)
└── service/conf/actions.d/
    └── actions_mihomo.conf               # configd 动作注册
```

---

## 三、 Web 界面与功能规格

### 3.1 菜单结构
* **服务**
  * **Mihomo**
    * **常规设置** (`/ui/mihomo/`)：3 Tab —— 概览（服务状态 / 运行指标 / 订阅资源三卡仪表盘，含启停重启重载与内核模式运行时切换）、基本设置（运行参数表单 + 面板与 API：内置面板链接、控制 API 端点、认证密钥查看/生成/自定义）、订阅与策略（订阅地址明文可编辑、自动更新与周期、最近更新状态）。
    * **分流规则** (`/ui/mihomo/rules`)：2 Tab —— 自定义规则（表格/源码双模式编辑器，行内类型下拉 + 目标策略选择器 + no-resolve）、规则查询（按关键词查询内核生效规则，不默认铺全量）。
    * **策略组** (`/ui/mihomo/proxies`)：实时读取内核 `/proxies`，左侧组列表 + 右侧紧凑节点行列表（名称/类型/延迟），Selector 组点击即切换。
    * **实时日志** (`/ui/mihomo/logs`)：亮色表格实时日志，级别过滤、每页 20/50/100 行、暂停/清屏/下载/自动滚动。

> 独立的「运行状态」页 (`/ui/mihomo/status`) 已在 1.3.0 后移除，其全部运行态信息（服务 7 态、接入方式、TUN/API、运行时长、内存、PID、版本、内核模式切换）并入常规设置的「概览」Tab；`/api/mihomo/status/*` 接口保持不变。

### 3.2 安全设计细节
1. **统一经由 configd**：
   - 所有的服务动作（如 `start`, `stop`, `restart`, `reload`）均通过 `(new Backend())->configdRun("mihomo <action>")` 触发，严禁在 PHP 中直接执行命令。
2. **敏感信息脱敏过滤器**：
   - `LogsController.php` 实现了模式匹配脱敏器，对日志行中的 `secret: ...`、`token: ...`、`password: ...` 以及 UUID 等凭证进行动态掩码替换为 `[REDACTED_SECRET]`。

---

## 四、 v1.1.0 界面规范

### 4.1 视觉与排版

- 共享样式片段 `views/OPNsense/Mihomo/styles.volt`，四个页面统一引入；只允许 `.mihomo-*` 前缀，不覆盖 OPNsense 全局样式。
- 亮色卡片：白底 + `#e3e3e3` 边框 + 4px 圆角 + 轻阴影；强调色只用 OPNsense 橙 `#d94f00`。
- Status 顶部 8 个 KPI 卡片；General 四张卡片（服务控制 / 运行参数 / 面板与 API / 订阅与策略）；Rules 两张卡片；Logs 工具栏 + 亮色日志表。
- 日志区禁止深色控制台色（`#1e1e1e`、`#2d2d2d`、`#dcdcdc`、`#2e2e2e`）；表头 sticky，时间列弱化，级别用标准 `label-*` 徽章。
- 表头 sticky 必须挂在 `thead th` 上（`tr` 上的 sticky 在 Chrome 不生效）。
- 响应式：`.mihomo-toolbar` 在 <768px 时纵向排列。

### 4.2 中文化

- 四个页面、三个 form、Menu、ACL、模型 OptionValues/ValidationMessage 的可见文案全部为简体中文。
- 技术标识保留英文：`DIRECT`、`REJECT`、`REJECT-DROP`、`DOMAIN`、`GEOSITE`、`RULE-SET`、`no-resolve`、`SOCKS`、`TUN`、`API`、`Mihomo`、`zashboard`。
- 日志正文（mihomo 原始输出）不翻译；级别徽章显示中文（调试/信息/警告/错误/致命），下载时使用 `data-level` 保留原始级别。
- OPNsense 自身的顶栏/菜单语言仍由系统语言设置决定；本插件内容固定中文。

### 4.3 大规则集下的生效规则

- `getEffectiveRules` 先用 `/version` 做安全探测（`-m 3`、`-K` 传 Bearer、secret 不进 argv），随后由 PHP `fopen/fgets` 流式读取 `config.yaml` 的 `rules:` 块。
- 查询参数 `limit`（默认 200，1~1000）、`offset`、`q`（<=200 字符，去控制字符）；返回 `total`/`truncated`/`query`。
- 前端 `#effective_prev`/`#effective_next`/`#effective_page_info` 翻页，`#filter_effective_rules` 350ms 防抖后走服务端搜索；行号为 `offset+idx+1`。
- 实测 357,229 条规则下首屏 200 条、搜索 `google` 793 条、末页 4 条，页面不卡死。

---

## 十二、1.2.0 界面重构（2026-10）

- **菜单**：常规设置 / 分流规则 / 策略组 / 运行状态 / 实时日志。
- **运行状态**：服务概览（服务状态、接入方式、内核模式运行时切换）、运行指标、默认折叠的诊断详情；状态文件 `mode` 现在按传输模式写 `PROXY`/`TRANSPARENT`。
- **常规设置**：面板与 API 改为「访问地址与密钥 / 自定义密钥 / 客户端接入指南」三段式；端口和绑定全部动态渲染，无 `:9090` 字面量。
- **策略组**（新增 `/ui/mihomo/proxies`）：实时读取 mihomo `/proxies`，Selector 组可切换节点，节点分页/搜索，展示最近延迟；不写入配置文件，重启后回订阅默认。
- **分流规则**：目标策略改为实时选择器（内置动作 + 代理组），规则只绑定组名，具体节点在策略组页切换；保留源码/表格模式、行号与校验。
- **运行参数**：`mihomo.general.transport_mode` 默认仍为 `proxy`；透明代理在面板切换。
- **内核模式**：状态页可在 `rule/global/direct` 间运行时切换，仅当前进程生效，不写 `config.yaml`，重启恢复模板的 `rule`。

---

## 十三、1.3.0 常规页 Dashboard 化（2026-10）

- **常规设置页**改为 4 个 Tab：概览（默认）/ 基本设置 / 订阅与策略 / 面板与 API；Tab 与 URL hash 双向绑定，可直达。
- **概览**：系统状态卡（呼吸指示灯、接入方式、内核模式徽章、自启徽章、查看运行状态入口、启动/停止/重启/重载——主按钮随运行状态切换，停止需确认）+ 订阅资源卡（节点/策略组/规则三个大数字、订阅掩码与最近结果、立即同步、策略组页入口）。指标为订阅更新静态数据，载入一次 + 更新后按需刷新，不做 5 秒轮询。
- **基本设置**：保留 base_form 与全部字段，外包现代化样式（label 置顶、控件聚焦品牌色光环）。
- **订阅与策略**：策略来源改为双卡片选择器（保留原 select 的 id 与取值逻辑）；最近更新为两列信息网格。
- **共享样式**：styles.volt 顶部引入设计 token（品牌橙 `--mh-brand`、语义色、表面色、圆角），全站卡片圆角统一 8px；新增状态指示灯、骨架屏、radio 卡片、警告条、保存成功横条组件。
- 兼容性：全部既有 DOM id 保留；`mapDataToFormUI`/订阅轮询/密钥管理行为不变。

---

## 十四、1.4.0 界面精简与收敛（2026-10-24）

- **移除「运行状态」独立页**：`status.volt` 与页面级 `StatusController.php` 下线，`Menu.xml` 去掉该项；诊断详情（Git 提交 / 最近状态消息 / 原始状态输出）不再在界面展示，需要时直接读 `/api/mihomo/status/getMihomoStatus` 或状态文件。
- **概览改为三卡仪表盘**：服务状态（7 态呼吸灯 + 接入方式徽章 + 开机自启 + 内核模式下拉与「应用」+ 启停/重启/重载）、运行指标（运行时长 / 内存 / PID / TUN / 控制 API / 插件·内核版本）、订阅资源。轮询统一走 `/api/mihomo/status/getMihomoStatus`（5 秒，仅概览 Tab 可见时发请求），不再调用 `/api/mihomo/service/status`。
- **概览去掉跳转按钮**：「查看运行状态」「打开策略组」入口移除，信息就地展示。
- **ACL**：`api/mihomo/status/*` 同时并入 `page-services-mihomo-general`（概览轮询与内核模式切换）与 `page-services-mihomo-proxies`（策略组页模式徽章）；删除孤立的 `page-services-mihomo-status` 分组。
- **基本设置**：隐藏 OPNsense `base_form` 自动注入的 `full help / advanced mode` 开关行（表单字段帮助文本不展示）。
- **实时日志**：去掉描述性副标题；每页行数改为 20（默认）/ 50 / 100，DOM 行数上限跟随该值滚动淘汰旧行；日志容器改为随内容自适应（上限 600px）。
- **策略组**：节点由卡片网格改紧凑行列表（一行一节点：名称 + 类型 + 延迟徽章，当前节点打勾并品牌色高亮，多列铺满），45 节点组从约 1050px 降到 660px 内。
- **全站**：成功类反馈统一右上角 toast（`mhToast`）；表单响应式多列网格；时间相对化 + 悬停完整时间；数量千分位。

---

## 十六、1.4.0 分流规则页重构（2026-10-24 晚）

- **拆为 2 个 Tab**（与常规设置页同一套 `nav nav-tabs` + hash 绑定）：「自定义规则」编辑器 / 「规则查询」。整页高度从 1480px 降到 778px，编辑器与查询各自一屏。
- **删除冗余信息层**：「允许的规则类型」code 行（类型下拉里已有）、「允许的目标策略」整条横向滚动 chips 与 `实时/离线` 徽章（目标只在行内选择器里选）、「打开策略组」跳转按钮、两条 help-block。`loadLiveGroups()` 保留，只是不再展示，仍为行内选择器提供实时组名与当前节点。
- **不再默认展示全量生效规则**：原「当前生效规则」357,229 条默认铺 200 条 + 只能上一页/下一页（1787 页）改为按需查询 —— 默认空态提示，点「查询」或回车才请求；新增每页条数 200/500/1000 与首页/末页按钮；结果计数用千分位，命中自定义规则改为值列前的小圆点（去掉整列「来源」与 `-` 占位）。
- **编辑器凝练**：模式切换（表格/源码）上移到卡片头；列宽固定 `序号 52 / 类型 158 / 值 弹性 / 目标 190 / 解析 108 / 操作 48`，行内边距压到 4px；「添加规则」「行数·字节计数」「校验并应用」合并为卡片底部一行；校验成功改 toast（失败仍行内标红 + 文件级/源码模式错误清单）。
- **下拉框垂直居中修复**：OPNsense 核心给 `select.form-control` 的行高（31px）大于插件紧凑控件高度（28px）时，原生 select 文字会沉到框的下半部。新增 `.mihomo-page select.form-control { line-height: 1.5 }`、`.input-sm { height: 32px; line-height: 20px; padding: 4px 10px }`，并把 `.mihomo-inline-ctl .form-control` 改为 `height: 30px; line-height: 20px; padding: 4px 8px`。
- **新增样式类**：`.mihomo-editor-table/.mihomo-editor-wrap/.mihomo-editor-foot/.mihomo-query-bar/.mihomo-query-wrap/.mh-col-*/.mh-mine-dot`；`.mihomo-radio-*`（策略来源卡片）已随上一轮删除。

---

## 十五、1.4.0 第二轮精简（2026-10-24 晚）

- **Tab 从 4 个收敛到 3 个**：「面板与 API」并入「基本设置」（运行参数表单下方新增一张卡，三行 kv：内置面板 / 控制 API / 认证密钥），原「客户端接入指南」整块删除（与上方信息重复）；`#tab_api` 与 `.api_disp_*`/`.api_link_preview` 一并移除，`api_bind_badge` 改为端点行内的「当前监听」小徽章。
- **订阅地址不再打码**：`/api/mihomo/subscription/get|set` 新增明文 `url` 字段，界面直接回填到输入框可编辑；`url_masked` 保留兼容。注意 `Mvc\Response` 会对 API 输出做 `htmlspecialchars`，前端用 `mhFromEntities()` 还原实体，否则地址里会出现 `&amp;`；保存回写仍是单层转义（已实测 `/conf/config.xml` 不产生 `&amp;amp;`）。
- **策略来源选择器移除**：界面固定沿用订阅自带策略组与规则，保存时不再提交 `strategy` 字段（后端缺省保留原值）；`mihomo-radio-cards` 组件样式随之删除。
- **订阅与策略页重排**：订阅地址输入框加宽（`.mh-input-wide` 突破核心 348px 限宽）、自动更新与更新周期并排、最近更新状态由 4×2 表格改为三行紧凑 kv（更新时间 / 更新结果 / 节点·策略组·分流规则），删除「策略来源」「结果消息」两行。
- **概览去掉更新结果文案**：`#ov_sub_msg`（「订阅更新成功（策略：订阅自带，… 条规则）」）与 `#ov_sub_masked` 掩码行移除，只留结果徽章 + 相对时间。
- **策略组页布局**：左栏 `col-md-4 → col-md-3`（308px）、右栏 `col-md-8 → col-md-9`（870px）；删除「搜索策略组」输入框及其过滤逻辑（保留组内节点搜索）；节点行 `minmax(230px,1fr)` 三列，45 节点组高度 660px → 432px；组列表自身改为 `max-height: 620px` 内部滚动。


