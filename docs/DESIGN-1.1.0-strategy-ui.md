# os-mihomo 1.1.0 实施契约：订阅自带分流 + 界面重构 + 全中文

> 本文件是 1.1.0 编码的**唯一接口契约**。四个编码包文件集互不相交，必须严格按本契约实现。
> 基线：`secure-mihomo` @ a63bc80（v1.0.9）。禁止修改本文件未列出的文件；禁止 git commit。
> 所有面向用户的文案使用简体中文；技术标识（DIRECT/REJECT/GEOSITE/RULE-SET、日志级别原值）保留英文。

---

## 0. 总体目标

1. 订阅更新时，除 `proxies:` 外同时保留订阅自带的 `proxy-groups:`、`rules:`、`rule-providers:`、`sub-rules:`、`proxy-providers:`，让面板/zashboard 的策略组与 Windows Clash 客户端一致。
2. 插件模板仍负责端口、`external-controller`、`secret`、`allow-lan`、`bind-address`、DNS/fake-ip、sniffer、geodata、`tun: false` 等基础设施。
3. 日志页去掉纯黑配色，四个页面统一 OPNsense 亮色卡片式排版。
4. 所有可见文案改中文。
5. 保持现有安全红线：配置原子替换、`mihomo -t` 预检失败不覆盖生产配置、自定义规则置顶、XSS 只用 `.text()`、secret 不进 argv、`:9090` 零硬编码。

---

## 1. 文件包与所有权（严格互斥）

### 包 A：订阅合成核心（shell/PHP 校验器）
允许修改：
- `src/os-mihomo/src/usr/local/etc/mihomo/sub/sub_lib.sh`
- `src/os-mihomo/src/usr/local/etc/mihomo/sub/sub.sh`
- `src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/custom_rules_apply.sh`（如需）
- `src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/custom_rules_validate.php`
- `tests/test_subscription_strategy.sh`（新建）

### 包 B：模型、订阅控制器、版本号、WebGUI 契约测试
允许修改：
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/models/OPNsense/Mihomo/Mihomo.xml`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/SubscriptionController.php`
- `src/os-mihomo/src/usr/local/opnsense/version/mihomo`
- `src/os-mihomo/Makefile`
- `src/os-mihomo/build.sh`
- `scripts/build.sh`（仅默认 VERSION 兜底值）
- `tests/test_webgui_pages.sh`（追加断言，不删已有断言）

### 包 C：General 页 + 共享样式 + 表单/菜单/ACL
允许修改/新建：
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/styles.volt`（新建，共享样式）
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/index.volt`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/forms/general.xml`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/forms/subscription.xml`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/forms/rules.xml`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/models/OPNsense/Mihomo/Menu/Menu.xml`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/models/OPNsense/Mihomo/ACL/ACL.xml`

### 包 D：Status / Rules / Logs 页 + 对应测试
允许修改：
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/status.volt`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/rules.volt`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/logs.volt`
- `tests/test_status_display.sh`
- `tests/test_logs_page.sh`

**包 C 与包 D 共享的样式类名只在第 5 节定义；包 D 不得新建/修改 `styles.volt`，只使用其中定义的类。**

---

## 2. 包 A：订阅合成核心契约

### 2.1 新增文件路径常量（sub_lib.sh 顶部）

```sh
MIHOMO_STRATEGY_MODE_FILE="${MIHOMO_STRATEGY_MODE_FILE:-/var/db/os-mihomo/strategy-mode}"
MIHOMO_STRATEGY_FILE="${MIHOMO_STRATEGY_FILE:-/var/db/os-mihomo/subscription-strategy.yaml}"
```

### 2.2 模式读取

`mihomo_lib_strategy_mode()`：

1. 若环境变量 `MIHOMO_STRATEGY_MODE` 为 `subscription` 或 `template`，优先返回（测试与 sub.sh 回退用）。
2. 否则读取 `MIHOMO_STRATEGY_MODE_FILE` 第一行，只接受 `subscription` / `template`。
3. 缺失/非法一律返回 `subscription`。
4. 只输出一行，无其他 stdout。

### 2.3 顶层块提取

`mihomo_lib_extract_top_block <raw_yaml> <key> <out_file>`：

- 从 `^<key>[ \t]*:`（列首，key 为字面量）开始；
- 输出起始行；
- 后续行原样输出，直到遇到下一行列首为 `^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:` 的顶层键；
- 块内的注释行、`- ` 列表项、空行、列首 `- ` 均保留；
- 找不到 key 时 out 为空并返回 1；成功返回 0。

### 2.4 策略片段提取

`mihomo_lib_extract_strategy <raw_yaml> <out_file>`：

- 按顺序提取 5 个块（存在才写）：`proxy-providers`、`proxy-groups`、`rule-providers`、`sub-rules`、`rules`；
- 文件首行写 `# subscription strategy (auto-extracted; do not edit)`；
- **必须**同时存在 `proxy-groups` 与 `rules`，否则返回 1（调用方回退模板）；
- 不在片段里插入自定义规则占位符（由 compose 注入）；
- 原子性不做要求（调用方用临时文件）。

### 2.5 策略片段校验

`mihomo_lib_strategy_valid <file>`：文件非空，且同时含 `^proxy-groups[ \t]*:` 与 `^rules[ \t]*:`，返回 0。

### 2.6 条目计数

`mihomo_lib_count_block_items <file> <key>`：统计该顶层块内 `^[ \t]*-[ \t]` 行数，输出纯数字。块外不计。

### 2.7 策略缓存存取

- `mihomo_lib_strategy_store <bundle>`：写 `MIHOMO_STRATEGY_FILE`，目录 `/var/db/os-mihomo`（缺失则 mkdir 0750），同目录 mktemp → chmod 0600 → 写入 → rename → chmod 0600；失败返回非 0。
- `mihomo_lib_strategy_remove`：`rm -f "$MIHOMO_STRATEGY_FILE"`，失败不报错。

### 2.8 compose 改造（mihomo_lib_compose）

保持现有函数签名与所有现有行为。新增逻辑：

1. 在完成模板变量替换（`_tmp_step1` 生成）之后、LAN/secret 处理之前：
   - `_strategy_mode="$(mihomo_lib_strategy_mode)"`；
   - 若 `_strategy_mode=subscription` 且 `${MIHOMO_STRATEGY_FILE}` 非空、文件存在、`mihomo_lib_strategy_valid` 通过：
     a. 用 awk 从 `_tmp_step1` 删除列首顶层块 `proxy-providers:`、`proxy-groups:`、`rule-providers:`、`sub-rules:`、`rules:`（整块删除，遇到下一个列首顶层键停止；不要误删块内缩进行）；
     b. 把策略片段追加到删除后的文件；追加时在策略片段的 `rules:` 行之后**立即**注入：
        - `_rules_src` 中的自定义规则（与模板注入同格式：空行跳过，`#` 注释输出 `  # ...`，其他输出 `  - ...`）；
        - 再输出 `  - GEOSITE,private,DIRECT`；
     c. 成功则设置全局变量：
        - `MIHOMO_COMPOSE_STRATEGY_USED="subscription"`
        - `MIHOMO_COMPOSE_STRATEGY_GROUPS="$(mihomo_lib_count_block_items "$strategy_file" proxy-groups)"`
        - `MIHOMO_COMPOSE_STRATEGY_RULES="$(mihomo_lib_count_block_items "$strategy_file" rules)"`
     d. 若策略文件缺失/非法：向 stderr 输出一行提示（`提示：未找到可用的订阅策略组缓存，本次使用插件模板`），保持模板并设 `MIHOMO_COMPOSE_STRATEGY_USED="template"`。
   - 其他情况：`MIHOMO_COMPOSE_STRATEGY_USED="template"`，counts 从模板解析（`proxy-groups`、`rules`）或为 0。
2. 不改变 secret 注入、LAN 暴露、权限、输出文件路径。
3. 所有新增临时文件必须进入现有 cleanup 路径（compose 内部 `rm -f`），不得残留。
4. POSIX sh + awk，不得使用 bash 数组/local/`[[ ]]`。

### 2.9 状态 JSON 扩展（mihomo_lib_status_write）

现有签名 `status_write <result> <nodes> <hash> <msg>`。扩展为可选第 5~7 参：

```sh
mihomo_lib_status_write "$RES" "$NODES" "$HASH" "$MSG" "$STRATEGY" "$GROUPS" "$RULES"
```

输出 JSON 追加：

```json
"strategy":"subscription","groups":12,"rules":108
```

- `strategy` 只接受 `subscription`/`template`，其他回退 `template`；
- `groups`/`rules` 非数字回退 0；
- 保持单行 JSON、写临时文件、chmod 0644、rename 的现有行为；
- 保持转义逻辑。

### 2.10 sub.sh 改造

在现有下载、proxies 提取、计数之后，合成之前：

```sh
STRATEGY_MODE="$(mihomo_lib_strategy_mode)"
STRATEGY_FALLBACK_MSG=""
TMP_STRATEGY=""
if [ "$STRATEGY_MODE" = "subscription" ]; then
    TMP_STRATEGY="$(mktemp "$Temp_Dir/strategy.XXXXXX")" || { ...失败退出... }
    if mihomo_lib_extract_strategy "$TMP_RAW" "$TMP_STRATEGY"; then
        export MIHOMO_STRATEGY_FILE="$TMP_STRATEGY"
    else
        rm -f "$TMP_STRATEGY"
        TMP_STRATEGY=""
        export MIHOMO_STRATEGY_MODE="template"
        STRATEGY_FALLBACK_MSG="订阅缺少 proxy-groups 或 rules，已回退插件模板"
    fi
fi
```

要求：

- `TMP_STRATEGY` 纳入 `cleanup_tmp_files`；
- 合成后读取 `MIHOMO_COMPOSE_STRATEGY_USED` / GROUPS / RULES；
- 原子更新成功后：
  - 若 used=subscription 且 TMP_STRATEGY 非空：`mihomo_lib_strategy_store "$TMP_STRATEGY"`；失败则在消息后追加 `（策略缓存写入失败）`；
  - 若 used=template 且原始 `STRATEGY_MODE=subscription`：`mihomo_lib_strategy_remove`（清掉陈旧缓存）；
- 状态写入改为 7 参：
  - 成功且 subscription：`订阅更新成功（策略：订阅自带，N 个策略组 / M 条规则）`
  - 成功且 template：`订阅更新成功（策略：插件模板）`
  - 追加 `STRATEGY_FALLBACK_MSG`（如有）
- 控制台输出同步打印上述消息；
- 保持现有 URL 脱敏、锁、HTTPS 强制、错误码、原子更新调用不变；
- `custom_rules_apply.sh` 只需确保能通过 compose 自动读取模式与缓存；若需要，可加一行 stderr 提示，不改契约。

### 2.11 custom_rules_validate.php 目标来源

新增：

- 若环境变量 `MIHOMO_TARGETS_FILE` 非空且可读，用该文件解析 `proxy-groups`；
- 否则若 `/usr/local/etc/mihomo/config.yaml` 可读，用生效配置；
- 否则回退 `template_file()`；
- 若选中的生效配置解析出 0 个组，回退模板（stderr 提示，不影响 stdout JSON）；
- `--targets` 输出格式保持 `{"targets":[...]}`，不得混入提示文本；
- 保持现有参数/校验/错误输出不变。

### 2.12 包 A 测试（新建 tests/test_subscription_strategy.sh）

必须覆盖：

1. 提取 fixture（含 `proxies`、`proxy-groups`、`rule-providers`、`rules`，以及干扰顶层键）只输出目标块，不串块；
2. `extract_strategy` 在有 groups+rules 时成功，缺任一失败；
3. subscription 模式 compose：输出含 fixture 组名（如 `代理模式`、`全球拦截`），不含模板组名 `🌍选择节点`；自定义规则出现在 `rules:` 之后、`GEOSITE,private,DIRECT` 之前；`GEOSITE,private,DIRECT` 存在；`secret:`/`external-controller:`/`dns:` 仍来自模板；
4. template 模式 compose：保持模板组名，且不出现 fixture 组名；
5. 策略文件缺失时 subscription 模式回退模板（输出模板组名）；
6. `mihomo_lib_strategy_mode`：env 覆盖、模式文件、缺失默认 subscription；
7. `mihomo_lib_status_write` 7 参输出含 strategy/groups/rules，4 参旧调用仍合法；
8. 所有测试在 `mktemp -d` 下运行，设置 `MIHOMO_CONF_DIR`、`MIHOMO_TEMPLATE_FILE`、`MIHOMO_RULES_FILE`、`MIHOMO_STRATEGY_FILE`、`MIHOMO_STRATEGY_MODE_FILE`、`MIHOMO_SECRET_MANAGER`（指向不存在路径，避免读取生产 secret）等环境变量，绝不写 `/var/db` 或 `/usr/local`。

脚本必须 `sh -n` 通过，`set -eu`，POSIX sh。

---

## 3. 包 B：模型 / 控制器 / 版本号契约

### 3.1 Mihomo.xml

在 `<subscription>` 内、`auto_interval` 之后新增：

```xml
<strategy type="OptionField">
    <default>subscription</default>
    <Required>Y</Required>
    <OptionValues>
        <subscription>订阅自带策略组与规则</subscription>
        <template>插件内置模板</template>
    </OptionValues>
</strategy>
```

`<version>` 保持不变（不引入 migration）。

### 3.2 SubscriptionController.php

新增常量：

```php
const STRATEGY_MODE_FILE = '/var/db/os-mihomo/strategy-mode';
const STRATEGY_CACHE_FILE = '/var/db/os-mihomo/subscription-strategy.yaml';
const CACHE_FILE = '/var/db/os-mihomo/subscription-cache.yaml';
```

`getAction()` 返回的 `subscription` 增加：

```php
'strategy' => $strategy !== '' ? $strategy : 'subscription',
'strategy_cache' => is_file(self::STRATEGY_CACHE_FILE),
```

（`$strategy = (string)$model->subscription->strategy`）

`readSubscriptionInput()` 的字段列表加入 `strategy`。

`setAction()`：

1. 标量校验列表加入 `strategy`；
2. 读取 `$strategy`（缺省沿用当前模型值），只接受 `subscription` / `template`，非法返回 `status=failed` 中文原因；
3. 保存模型时写入 `$model->subscription->strategy = $strategy;`；
4. 保存成功后写模式文件（原子：同目录 tempnam → chmod 0600 → `$strategy . "\n"` → rename → chmod 0600；目录 `/var/db/os-mihomo` 缺失则 mkdir 0750）；写失败时返回 `status=ok` 但 `message` 追加 `；模式状态文件写入失败（下次保存会重试）`；
5. 若策略值发生变化（保存前快照旧值）：
   - 若 `CACHE_FILE` 存在且非空：`$recompose = trim((string)(new Backend())->configdRun('mihomo rules-recompose'));`
     - 输出含 `OK`：message 追加 `；配置已重新合成`
     - 否则：message 追加 `；策略来源已保存，但重新合成失败（旧配置继续运行）: ` + 截断输出
   - 否则：message 追加 `；尚未拉取订阅，请点击「立即更新」以应用新策略来源`
6. 返回值增加 `strategy`、`strategy_cache`、`recompose`；
7. 保持 URL 掩码、cron、env 写入等现有逻辑完全不变；
8. 不新增 configd action；recompose 直接用现有 `configdRun('mihomo rules-recompose')`（单参，26.7 合法）。

注意：`configdRun` 第二参是 detach，单参调用合法；不要传数组。

### 3.3 版本号

统一升到 `1.1.0`：

- `src/os-mihomo/src/usr/local/opnsense/version/mihomo` 的 `product_version`
- `src/os-mihomo/Makefile` 的 `VERSION?=`
- `src/os-mihomo/build.sh` 的 `VERSION` 默认值
- `scripts/build.sh` 的 `VERSION="${VERSION:-...}"` 兜底值

### 3.4 tests/test_webgui_pages.sh 追加

在现有模型契约检查之后追加：

- `Mihomo.xml` 含 `<strategy type="OptionField">`；
- 含 `<subscription>订阅自带策略组与规则</subscription>` 与 `<template>插件内置模板</template>`；
- `SubscriptionController.php` 含 `STRATEGY_MODE_FILE` 常量与 `writeStrategyMode`；
- `setAction` 中对 `strategy` 的白名单校验（含 `subscription`、`template` 字面量）。

不得删除/弱化任何现有断言。

---

## 4. 包 C：General 页 + 共享样式 + 表单/菜单/ACL

### 4.1 styles.volt（新建）

内容为单个 `<style>` 块，定义第 5 节列出的类。必须：

- 不含任何深色控制台色（`#1e1e1e`、`#2d2d2d`、`#444`、`#dcdcdc`、`#2e2e2e`）；
- 不覆盖 OPNsense 全局选择器（只允许 `.mihomo-*` 前缀）；
- 无 `<script>`、无 PHP、无外链字体。

### 4.2 index.volt 结构

顶部引入：`{{ partial('OPNsense/Mihomo/styles') }}`，最外层 `<div class="mihomo-page">`。

四张卡片（每张 `.content-box` + `.mihomo-card-title`）：

1. **服务控制**：`#service_status_badge` + `#btn_start/#btn_stop/#btn_restart/#btn_reload`。
2. **运行参数**：保留 `{{ partial("layout_partials/base_form", ['fields': generalForm, 'id': 'frm_general_settings']) }}` 与 `#btn_save/#btn_save_progress`，位置不能破坏 `mapDataToFormUI`。
3. **面板与 API**：保留全部现有 secret 相关 id/按钮/链接（`#api_secret_masked`、`#btn_secret_reveal`、`#btn_secret_generate`、`#api_secret_custom`、`#btn_secret_apply`、`.api_disp_host`、`.api_disp_port`、`#api_bundled_link`、`#api_wan_warn`）。
4. **订阅与策略**：保留全部现有订阅 id，并新增：
   - `#sub_strategy`（select，value `subscription`/`template`）
   - `#sub_state_strategy`、`#sub_state_groups`、`#sub_state_rules` 三个 `<td>`

订阅卡片控件顺序建议：订阅地址 → 当前订阅（掩码）→ 自动更新 → 更新周期 → 策略来源 → 保存/立即更新 → 最近更新表格。

策略来源文案：

- label：`策略来源`
- option subscription：`沿用订阅自带策略组与规则（推荐）`
- option template：`插件内置策略组与规则`
- help：`沿用订阅时，代理组与分流规则与 Windows/Clash 客户端一致；订阅缺少 proxy-groups 或 rules 时自动回退插件模板。切换后建议点「立即更新」。`

### 4.3 index.volt JS 契约

- `applySubscription(sub)` 增加：`$('#sub_strategy').val(sub.strategy === 'template' ? 'template' : 'subscription');`
- `renderLastUpdate(lastUpdate)` 增加：
  - `last_update.strategy === 'subscription' ? '订阅自带' : '插件模板'` → `#sub_state_strategy`
  - `last_update.groups` → `#sub_state_groups`（缺失显示 `-`）
  - `last_update.rules` → `#sub_state_rules`（缺失显示 `-`）
- `#btn_sub_save` 的 payload 增加 `strategy: $('#sub_strategy').val()`
- 保存成功对话框显示 `data.message`（已含 recompose 结果），不要只显示固定文案
- 保持轮询、暂停、密钥、服务按钮等现有行为不变
- 所有用户可见英文改中文（含 BootstrapDialog 标题/正文/确认文案）

### 4.4 表单与菜单/ACL 中文化

- `forms/general.xml`：字段顺序调整为 `enabled, log_level, transport_mode, lan_expose, lan_user, api_bind, api_port`；label/help 全部中文，保留 id 与 type 不变。
- `forms/subscription.xml`：label/help 中文。
- `forms/rules.xml`：label/help 中文。
- `Menu.xml`：
  - General → `常规设置`
  - Rules → `分流规则`
  - Status → `运行状态`
  - Logs → `实时日志`
  - 父级 `Mihomo` 保留
- `ACL.xml`：`name` 改中文（`服务：Mihomo`、`服务：Mihomo：常规设置` 等），patterns 一字不改。

---

## 5. 共享样式类名（包 C 定义，包 D 只使用）

必须提供以下类（可增加，不可改名）：

```css
.mihomo-page
.mihomo-card-title
.mihomo-subtitle
.mihomo-toolbar
.mihomo-kpi
.mihomo-kpi-label
.mihomo-kpi-value
.mihomo-mono
.mihomo-log-view
.mihomo-log-table
.mihomo-log-time
.mihomo-log-level
.mihomo-log-msg
.mihomo-table-wrap
.mihomo-empty
.mihomo-nowrap
```

关键视觉要求：

- 页面底色与 OPNsense 内容区一致；卡片白底、1px `#e3e3e3` 边框、4px 圆角、轻微阴影；
- 强调色只用 OPNsense 橙 `#d94f00`（标题图标/卡片左边框）；
- 日志区**不得**出现深色背景；表头 sticky 用 `#f5f5f5`，行分隔 `#eee`，时间列 `#777`；
- KPI 卡片：`#fafafa` 底、左侧 3px 橙边；
- 表格包裹 `.mihomo-table-wrap` 时 sticky 表头背景 `#f5f5f5`；
- 响应式：`@media (max-width: 767px)` 下工具栏纵向排列。

---

## 6. 包 D：Status / Rules / Logs

### 6.1 status.volt

- 顶部引入 `{{ partial('OPNsense/Mihomo/styles') }}`，最外层 `.mihomo-page`。
- 顶部 8 个 KPI 卡片（`.mihomo-kpi`）：服务状态、传输层、TUN 接口、外部控制 API、运行时长、内存占用、进程 PID、插件/内核版本。
- 必须保留全部现有 id：`#stat_state_desc`、`#stat_mode`、`#stat_transport`、`#stat_plugin_version`、`#stat_mihomo_version`、`#stat_commit`、`#stat_pid`、`#stat_memory`、`#stat_uptime`、`#stat_tun`、`#stat_api`、`#stat_message`、`#stat_last_change`、`#stat_raw`、`#btn_refresh_status`。
- JS 逻辑保持：`data.transport_mode === 'transparent'` 分支、TUN UP/DOWN/SOCKS 三态、SOCKS 分支不得有 `label-danger`、4 秒轮询。
- 徽章文案改中文：
  - 模式：透明代理 / 模式：代理 / 模式：直连
  - 运行中 / 启动中 / 停止中 / 降级 / 故障 / 已禁用 / 已停止
  - TUN：正常 / 断开 / SOCKS
  - API：正常 / 不可用
- 明细表保留版本、提交、最近状态消息、最近状态变更、原始状态输出。

### 6.2 rules.volt

- 顶部引入 styles partial，最外层 `.mihomo-page`。
- 两张卡片：自定义规则编辑器、当前生效规则（只读）。
- 保留全部现有 id 与行为：`#tbl_rules_editor`、`#tbl_rules_body`、`#btn_add_rule_row`、`#btn_mode_table`、`#btn_mode_raw`、`#rules_content`、`#rules_counter`、`#btn_rules_apply`、`#rules_result`、`#rules_error_table`、`#rules_error_body`、`#rules_file_error`、`#tbl_effective_rules`、`#tbl_effective_body`、`#filter_effective_rules`、`#btn_refresh_effective`、`#effective_rules_alert`、`#effective_count_label`。
- **禁止** `.html(` / `innerHTML`（测试红线）；动态内容一律 `.text()`。
- 保留 `payload !== ''` 与 `attr('data-line', outLineNum)` 逻辑。
- 生效规则表使用 `.mihomo-table-wrap` + sticky 表头；目标策略用 `label` 徽章（DIRECT 绿、REJECT/REJECT-DROP 红、其他蓝）。
- 所有可见文案中文。

### 6.3 logs.volt

- 顶部引入 styles partial，最外层 `.mihomo-page`。
- 工具栏保留所有 id：`#log_level_filter`、`#log_limit`、`#btn_toggle_pause`、`#icon_toggle_pause`、`#text_toggle_pause`、`#btn_clear_logs`、`#btn_download_logs`、`#chk_auto_scroll`、`#log_conn_status`、`#log_conn_text`、`#log_container`、`#log_table_body`。
- 使用 `.mihomo-log-view` / `.mihomo-log-table` / `.mihomo-log-time` / `.mihomo-log-level` / `.mihomo-log-msg`；**不得**出现深色背景/文字色（`#1e1e1e`、`#2d2d2d`、`#444`、`#dcdcdc`、`#2e2e2e`、`#888` 作为正文色也不行）。
- 级别徽章只用 `label-default/info/warning/danger`，不得内联 background-color；显示中文映射：debug→调试、info→信息、warning/warn→警告、error/fatal→错误/致命，其他原样。
- 保留 `.text()` 渲染、`if (isPaused)` 防竞态、`updateConnStatus('error'`、不链式 `.fail(`、`:9090` 零硬编码。
- 工具栏中文：日志级别、全部级别、调试、信息、警告、错误、行数、暂停/继续、清屏、下载、自动滚动、实时/已暂停/连接中断/重连中、时间/级别/消息。
- 日志正文（mihomo 原始输出）不翻译。

### 6.4 测试更新

`tests/test_status_display.sh`：

- 将 `MODE: TRANSPARENT/PROXY/DIRECT` 三条 grep 改为 `模式：透明代理`、`模式：代理`、`模式：直连`；
- 保留 `data\.transport_mode === .transparent.`、TUN UP/DOWN/SOCKS、SOCKS 无 label-danger 等断言；
- 其余不动。

`tests/test_logs_page.sh`：

- 保留现有全部 id/行为/XSS/`:9090` 断言；
- 新增负向断言：`logs.volt` 不得包含 `#1e1e1e`、`#2d2d2d`、`#dcdcdc`、`#2e2e2e`（深色控制台色）；
- 新增正向断言：含 `mihomo-log-view`、`mihomo-log-table`。

---

## 7. 中文文案表（统一用词）

- 页面：常规设置 / 分流规则 / 运行状态 / 实时日志
- 服务：服务控制 / 启动 / 停止 / 重启 / 重载 / 运行中 / 已停止 / 检查中
- 运行参数：运行参数 / 启用 Mihomo / 日志级别 / 传输模式 / 仅代理模式 / 透明代理模式 / LAN 代理暴露 / LAN 代理用户名 / API 绑定地址 / API 端口 / 保存并应用
- 面板：面板与 API / 当前密钥（掩码）/ 查看密钥 / 生成新密钥 / 设置自定义密钥 / 应用 / 面板与客户端访问指南
- 订阅：订阅与策略 / 订阅地址 / 当前订阅（掩码）/ 启用自动更新 / 更新周期 / 每 6 小时 / 每 12 小时 / 每 24 小时 / 策略来源 / 保存订阅 / 立即更新
- 最近更新：最近更新时间 / 最近更新结果 / 节点数量 / 策略来源 / 策略组数量 / 分流规则数量 / 结果消息 / 成功 / 失败 / 订阅自带 / 插件模板
- 状态：服务状态 / 传输层 / 插件版本 / Mihomo 内核版本 / Git 提交 / 进程 ID / 内存占用 / 运行时长 / TUN 接口 / 外部控制 API / 最近状态消息 / 最近状态变更 / 原始状态输出 / 立即刷新
- 规则：自定义规则 / 允许的规则类型 / 允许的目标策略 / 表格模式 / 源码模式 / 序号 / 类型 / 值 / 目标策略 / 选项 / 操作 / 添加规则 / 校验并应用 / 行数 / 字节数 / 当前生效规则 / 来源 / 自定义 / 总计 / 暂无生效规则
- 日志：日志级别 / 全部级别 / 调试 / 信息 / 警告 / 错误 / 行数 / 暂停 / 继续 / 清屏 / 下载 / 自动滚动 / 实时 / 已暂停 / 连接中断 / 重连中 / 时间 / 级别 / 消息

技术标识保留英文：`DIRECT`、`REJECT`、`REJECT-DROP`、`DOMAIN`、`GEOSITE`、`RULE-SET`、`no-resolve`、`SOCKS`、`TUN`、`API`、`Mihomo`、`zashboard`、`WebGUI`。

---

## 8. 质量门禁（每个包自检，主控终审）

- `sh -n` 所有改动的 `.sh`；
- Python XML 解析所有改动的 `.xml`；
- 不改动文件集之外的任何文件；
- 不引入 `:9090` 字面量到 volt/控制器（既有守卫）；
- volt 中动态内容不使用 `.html(`/`innerHTML`（logs/rules 硬红线）；
- PHP 只使用现有 26.7 基类 API，不调用 `getNodes/setNodes`；
- 不在 shell 中使用 bashism；
- 完成后返回：改动文件列表、实现摘要、偏差/风险。

---

## 9. 追加包 E（主工作流结束后执行）：大规则集下的生效规则分页

背景（VM 实测）：本机机场订阅 17.2MB / 357,438 行，`rules:` 约 357,227 条（335k DOMAIN-SUFFIX + 13k IP-CIDR + 7k IP-CIDR6）。`mihomo -t` 仅 1s，但当前 `getEffectiveRulesAction` 会把 `/rules` 全量 JSON 交给 PHP 并下发浏览器，前端会渲染 35 万行 DOM，页面必然卡死。必须改为**服务端流式解析 + 分页 + 服务端搜索**。

允许修改：
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/RulesController.php`
- `src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/rules.volt`
- `src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/custom_rules_validate.php`
- `tests/test_rules_page.sh`

契约：

1. `getEffectiveRulesAction` 保留现有安全探测（`/version` 代替 `/rules`，`-m 3`、`-K`、`escapeshellarg`、secret 不进 argv），用于 `reachable` 判定；不可达时仍返回 `reachable:false`。
2. 可达时**不再请求 `/rules`**，改为流式读取 `/usr/local/etc/mihomo/config.yaml` 的 `rules:` 块（`fopen`/`fgets`，不得 `file_get_contents` + `preg_split` 全量载入）。
3. 查询参数：`limit`（默认 200，1~1000）、`offset`（>=0）、`q`（<=200 字符，去控制字符）。
4. 返回 `{status:'ok', reachable:true, rules:[{type,payload,proxy}], total, offset, limit, truncated, query}`；`total` 是匹配 `q` 的规则数（无 q 时为全部规则数），`rules` 只含当前窗口。
5. 规则解析：按逗号分段；`MATCH,proxy` → payload 空、proxy=第 2 段；其余 type/payload/proxy 取前三段；无法解析的行跳过。
6. `effectiveRulesCache` 改为当前页；`#filter_effective_rules` 输入 350ms 防抖后带 `q` 重新请求（不再只过滤当前页 DOM）。
7. 新增 `#effective_prev`、`#effective_next`、`#effective_page_info`；`#effective_count_label` 显示 `总计 N 条`（有 q 时 `匹配 N 条`）和当前窗口；上一页/下一页按 offset 翻页。
8. 行号显示 `offset + index + 1`；保留「自定义」来源徽章逻辑（基于编辑器内容）。
9. `custom_rules_validate.php` 的 `parse_proxy_group_names` 改为流式读取并在 `proxy-groups` 下一个顶层键处停止；新增 `MIHOMO_TARGETS_FILE` > 生效 `config.yaml` > 模板的来源顺序；解析 0 组时回退模板。
10. `tests/test_rules_page.sh`：
    - 保留 `-m 3`、`-K`、`escapeshellarg`、无 `:9090`、无 `.html(` 等既有断言；
    - 新增断言：action 含 `fopen`/`fgets`、`limit`/`offset`/`q`/`total`/`truncated`、`/version`、分页控件 id；
    - 保留现有表格/源码模式/生效规则/序列化断言。
11. 任何情况下不得把 35 万条规则一次性放进 JSON 或 DOM。
