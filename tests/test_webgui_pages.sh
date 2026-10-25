#!/bin/sh
set -eu

echo "===> Running WebGUI pages & configd API tests..."

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CTRL_DIR="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo"
VIEW_DIR="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo"
ACTIONS="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/service/conf/actions.d/actions_mihomo.conf"

# Test 1: 每个 /ui/mihomo/{page} 菜单地址必须有同名页面控制器（Phalcon 路由
# /ui/{module}/{controller} 按控制器文件名解析；挂在 IndexController 上的
# action 不可达，历史上导致 Rules/Proxies/Logs 三页 Page not found）
echo "--> Test 1: page controllers for every menu URL..."
for page in index rules proxies logs; do
    if [ "$page" = "index" ]; then
        PAGE_CTRL="$CTRL_DIR/IndexController.php"
    else
        PAGE_CTRL="$CTRL_DIR/$(printf '%s' "$page" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')Controller.php"
    fi
    [ -f "$PAGE_CTRL" ] || { echo "FAIL: missing page controller $PAGE_CTRL (menu /ui/mihomo/$page would 404)"; exit 1; }
    grep -q "function indexAction" "$PAGE_CTRL" || { echo "FAIL: $PAGE_CTRL has no indexAction"; exit 1; }
    [ -f "$VIEW_DIR/$page.volt" ] || { echo "FAIL: missing view $VIEW_DIR/$page.volt"; exit 1; }
    echo "  [PASS] /ui/mihomo/$page -> $(basename "$PAGE_CTRL") + $page.volt"
done

# Test 2: 菜单 URL 与页面控制器一一对应
MENU_XML="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/models/OPNsense/Mihomo/Menu/Menu.xml"
echo "--> Test 2: menu URLs..."
for page in "" rules proxies logs; do
    grep -q "url=\"/ui/mihomo/$page\"" "$MENU_XML" || {
        echo "FAIL: menu URL /ui/mihomo/$page not registered"; exit 1;
    }
done
# 运行状态独立页已下线（信息并入常规设置概览），菜单不得再挂 /ui/mihomo/status
if grep -q "url=\"/ui/mihomo/status\"" "$MENU_XML"; then
    echo "FAIL: menu still registers /ui/mihomo/status (运行状态页应已下线)"; exit 1
fi
echo "  [PASS] Menu.xml registers /ui/mihomo/, /rules/, /proxies/, /logs/ and no /status"

# Test 3: 26.7 configd API 回归守卫 —— configdRun 第二参是 detach（bool），
# 传数组会变成 detach=true，configd 走异步 execute 只返回 job UUID
echo "--> Test 3: no configdRun() with array second argument..."
if grep -rn -E "configdRun\([^)]*,[[:space:]]*(array\(|\[)" \
    "$CTRL_DIR/Api" "$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/models" >/dev/null 2>&1; then
    echo "FAIL: configdRun() called with array second argument (26.7 signature: configdRun(event, detach)); use configdpRun(event, params)"; exit 1
fi
echo "  [PASS] no array-typed configdRun second argument"

# Test 4: 需要传参的调用必须走 configdpRun
echo "--> Test 4: parameterized configd calls use configdpRun..."
grep -q "configdpRun" "$CTRL_DIR/Api/SubscriptionController.php" || {
    echo "FAIL: SubscriptionController must use configdpRun for sub-env-write/setup-cron"; exit 1;
}
echo "  [PASS] configdpRun in use"

# Test 5: 密钥管理闭环 —— configd 动作、脚本子命令与 API action 齐备
echo "--> Test 5: secret management wiring..."
grep -q "^\[secret-set\]" "$ACTIONS" || { echo "FAIL: actions_mihomo.conf missing [secret-set]"; exit 1; }
grep -q "^\[secret-get\]" "$ACTIONS" || { echo "FAIL: actions_mihomo.conf missing [secret-get]"; exit 1; }
grep -q "^\[secret-generate\]" "$ACTIONS" || { echo "FAIL: actions_mihomo.conf missing [secret-generate]"; exit 1; }
grep -q "function secretRevealAction" "$CTRL_DIR/Api/GeneralController.php" || {
    echo "FAIL: GeneralController missing secretRevealAction"; exit 1;
}
grep -q "function secretSetAction" "$CTRL_DIR/Api/GeneralController.php" || {
    echo "FAIL: GeneralController missing secretSetAction"; exit 1;
}
grep -q "secret_manager.sh set" "$ACTIONS" || { echo "FAIL: [secret-set] must call secret_manager.sh set"; exit 1; }
echo "  [PASS] secret-set/secret-get/secret-generate actions + API endpoints wired"

# Test 5b: configd 动作格式守卫 —— %s 只能出现在 parameters: 模板行；
# command 行里的 %s 会被原样传给脚本（字面 %s 占住 argv，参数整体错位，
# 表现为 Execute error / exit 64）
echo "--> Test 5b: no %s placeholders in action command lines..."
if grep -E "^command:.*%s" "$ACTIONS" | grep -q .; then
    grep -E "^command:.*%s" "$ACTIONS" | while read -r line; do echo "  BAD: $line"; done
    echo "FAIL: action command lines must not contain %s (use the parameters: template)"; exit 1
fi
echo "  [PASS] all action parameters live in parameters: templates"

# Test 7: v1.0.7 安全加固守卫
echo "--> Test 7: v1.0.7 security and robustness guards..."
# ① ACL.xml 的 general 组含 ui/mihomo、ui/mihomo/、api/mihomo/service/* 与 api/mihomo/subscription/*
ACL_XML="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/models/OPNsense/Mihomo/ACL/ACL.xml"
[ -f "$ACL_XML" ] || { echo "FAIL: missing ACL.xml"; exit 1; }
awk '
    /<page-services-mihomo-general>/ { in_gen = 1 }
    in_gen && /<pattern>ui\/mihomo<\/pattern>/ { has_ui_exact = 1 }
    in_gen && /<pattern>ui\/mihomo\/<\/pattern>/ { has_ui_slash = 1 }
    in_gen && /<pattern>api\/mihomo\/service\/\*<\/pattern>/ { has_svc = 1 }
    in_gen && /<pattern>api\/mihomo\/subscription\/\*<\/pattern>/ { has_sub = 1 }
    in_gen && /<\/page-services-mihomo-general>/ { closed = 1; exit }
    END {
        if (!in_gen || !closed || !has_ui_exact || !has_ui_slash || !has_svc || !has_sub) {
            exit 1
        }
    }
' "$ACL_XML" || { echo "FAIL: ACL.xml general group must contain ui/mihomo, ui/mihomo/, api/mihomo/service/* and api/mihomo/subscription/*"; exit 1; }
echo "  [PASS] ACL.xml general group contains ui/mihomo, ui/mihomo/, api/mihomo/service/* and api/mihomo/subscription/*"

# ② LogsController.php 含 configdpRun 且不含 "mihomo log ' ." 拼接
LOGS_CTRL="$CTRL_DIR/Api/LogsController.php"
[ -f "$LOGS_CTRL" ] || { echo "FAIL: missing LogsController.php"; exit 1; }
grep -q "configdpRun('mihomo log'" "$LOGS_CTRL" || {
    echo "FAIL: LogsController.php must use configdpRun('mihomo log', ...)"; exit 1;
}
if grep -E "configdRun\(['\"]mihomo log[[:space:]]*['\"][[:space:]]*\." "$LOGS_CTRL" >/dev/null 2>&1; then
    echo "FAIL: LogsController.php must not concatenate configdRun('mihomo log ' .)"; exit 1;
fi
echo "  [PASS] LogsController uses configdpRun without string concatenation"

# ③ GeneralController.php 的 secretRevealAction 含 isPost 校验
GEN_CTRL="$CTRL_DIR/Api/GeneralController.php"
[ -f "$GEN_CTRL" ] || { echo "FAIL: missing GeneralController.php"; exit 1; }
awk '
    /function secretRevealAction/ { in_fn = 1 }
    in_fn && /isPost\(\)/ { has_post = 1 }
    in_fn && /^    \}/ {
        if (!has_post) { exit 1 }
        exit 0
    }
' "$GEN_CTRL" || { echo "FAIL: GeneralController secretRevealAction must check isPost()"; exit 1; }
echo "  [PASS] GeneralController secretRevealAction checks isPost()"

# ④ GeneralController.php 含 getModelNodes 覆盖
grep -q "function getModelNodes" "$GEN_CTRL" || {
    echo "FAIL: GeneralController must override getModelNodes()"; exit 1;
}
echo "  [PASS] GeneralController overrides getModelNodes()"

# Test 8: v1.0.8 api-bind 方案守卫
echo "--> Test 8: v1.0.8 api-bind guards..."
# ① actions conf 含 [api-bind-apply] 且 %s 仅在 parameters 行
grep -q "^\[api-bind-apply\]" "$ACTIONS" || {
    echo "FAIL: actions_mihomo.conf missing [api-bind-apply]"; exit 1;
}
awk '
    /^\[api-bind-apply\]/ { in_act = 1; next }
    in_act && /^\[/ { in_act = 0 }
    in_act && /^command:.*%s/ { print "FAIL: [api-bind-apply] command line contains %s"; exit 1 }
    in_act && /^parameters:.*%s.*%s/ { has_params = 1 }
    END {
        if (!has_params) {
            print "FAIL: [api-bind-apply] missing two %s placeholders in parameters"
            exit 1
        }
    }
' "$ACTIONS" || exit 1
echo "  [PASS] actions_mihomo.conf contains [api-bind-apply] with parameters %s %s"

# ② Mihomo.xml 含 api_bind/api_port、不含 lan_api
MODEL_XML="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/models/OPNsense/Mihomo/Mihomo.xml"
[ -f "$MODEL_XML" ] || { echo "FAIL: missing Mihomo.xml"; exit 1; }
grep -q "<api_bind type=\"TextField\">" "$MODEL_XML" || {
    echo "FAIL: Mihomo.xml missing api_bind TextField"; exit 1;
}
grep -q "<api_port type=\"IntegerField\">" "$MODEL_XML" || {
    echo "FAIL: Mihomo.xml missing api_port IntegerField"; exit 1;
}
if grep -q "lan_api" "$MODEL_XML"; then
    echo "FAIL: Mihomo.xml must not contain deprecated lan_api"; exit 1;
fi
echo "  [PASS] Mihomo.xml has api_bind/api_port and no lan_api"

# ②-b 契约 3.4：Mihomo.xml strategy 字段及选项
grep -q '<strategy type="OptionField">' "$MODEL_XML" || {
    echo "FAIL: Mihomo.xml missing strategy OptionField"; exit 1;
}
grep -q '<subscription>订阅自带策略组与规则</subscription>' "$MODEL_XML" || {
    echo "FAIL: Mihomo.xml missing subscription strategy option label"; exit 1;
}
grep -q '<template>插件内置模板</template>' "$MODEL_XML" || {
    echo "FAIL: Mihomo.xml missing template strategy option label"; exit 1;
}
echo "  [PASS] Mihomo.xml contains strategy OptionField with subscription and template options"

# ②-c 契约 3.4：SubscriptionController.php 常量与 strategy 逻辑
SUB_CTRL="$CTRL_DIR/Api/SubscriptionController.php"
[ -f "$SUB_CTRL" ] || { echo "FAIL: missing SubscriptionController.php"; exit 1; }
grep -q "const STRATEGY_MODE_FILE" "$SUB_CTRL" || {
    echo "FAIL: SubscriptionController.php missing STRATEGY_MODE_FILE constant"; exit 1;
}
grep -q "writeStrategyMode" "$SUB_CTRL" || {
    echo "FAIL: SubscriptionController.php missing writeStrategyMode method"; exit 1;
}
# setAction 中对 strategy 的白名单校验（含 subscription、template 字面量）
awk '
    /function setAction/ { in_act = 1 }
    in_act && /subscription/ && /template/ { has_whitelist = 1 }
    in_act && /^    \}/ {
        if (!has_whitelist) { exit 1 }
        exit 0
    }
' "$SUB_CTRL" || { echo "FAIL: SubscriptionController setAction must whitelist validate strategy against subscription and template"; exit 1; }
echo "  [PASS] SubscriptionController.php has STRATEGY_MODE_FILE, writeStrategyMode and strategy whitelist validation"

# ③ GeneralController 含 secret 有效值前置检查与 api-bind-apply 调用
grep -q "getConfigSecret" "$GEN_CTRL" || {
    echo "FAIL: GeneralController must check config.yaml secret value before binding non-loopback"; exit 1;
}
grep -q "configdpRun('mihomo api-bind-apply'" "$GEN_CTRL" || {
    echo "FAIL: GeneralController must call configdpRun('mihomo api-bind-apply', ...)"; exit 1;
}
echo "  [PASS] GeneralController includes active secret check and api-bind-apply"

# ④ index.volt 不含 ":9090" 字面量与硬编码主机端口回退
INDEX_VOLT="$VIEW_DIR/index.volt"
[ -f "$INDEX_VOLT" ] || { echo "FAIL: missing index.volt"; exit 1; }
if grep -q ":9090" "$INDEX_VOLT"; then
    echo "FAIL: index.volt contains hardcoded :9090 literal"; exit 1;
fi
if grep -E "'9090'|\"9090\"|'127\.0\.0\.1'|\"127\.0\.0\.1\"" "$INDEX_VOLT" >/dev/null 2>&1; then
    echo "FAIL: index.volt contains hardcoded 9090 or 127.0.0.1 fallback literals"; exit 1;
fi
echo "  [PASS] index.volt has zero :9090 literals and no hardcoded JS port/bind fallback"

# ④-b index.volt 新结构与 ID 断言（面板与 API 并入基本设置、订阅与概览控件）
echo "--> Test 8b: index.volt structure & element IDs..."
for elem_id in \
    api_secret_masked btn_secret_reveal btn_secret_generate \
    api_secret_custom btn_secret_apply api_bundled_link \
    api_wan_warn api_header_port api_secret_help api_endpoint_display \
    btn_copy_api_endpoint api_bind_badge collapse_secret_custom \
    btn_start btn_stop btn_restart btn_reload service_status_badge \
    frm_general_settings btn_save \
    sub_url sub_url_hint sub_auto_update sub_interval \
    btn_sub_save btn_sub_update btn_sub_update_icon \
    sub_state sub_state_time sub_state_result sub_state_counts sub_state_message; do
    grep -q "$elem_id" "$INDEX_VOLT" || {
        echo "FAIL: index.volt missing required element/ID: $elem_id"; exit 1;
    }
done
for class_name in \
    mihomo-card mihomo-card-head mihomo-form-wrap mihomo-kv mihomo-toolbar \
    mihomo-modern-form mihomo-kv-rows mihomo-inline-ctl mihomo-row-cards; do
    grep -q "$class_name" "$INDEX_VOLT" || {
        echo "FAIL: index.volt missing required class: $class_name"; exit 1;
    }
done
# 已下线的结构不得回归：面板与 API 独立 Tab、客户端接入指南、订阅掩码行、策略来源选择器
for gone in tab_api api_dashboard_guide api_guide_content api_link_preview sub_url_masked sub_strategy mihomo-radio-cards; do
    if grep -q "$gone" "$INDEX_VOLT"; then
        echo "FAIL: index.volt must not keep removed element: $gone"; exit 1
    fi
done
echo "  [PASS] index.volt contains all required card structures, element IDs and classes"

# ④-c styles.volt 新类体系静态断言
echo "--> Test 8c: styles.volt class system..."
STYLES_VOLT="$VIEW_DIR/styles.volt"
[ -f "$STYLES_VOLT" ] || { echo "FAIL: missing styles.volt"; exit 1; }
for req_class in \
    mihomo-card mihomo-card-head mihomo-card-title mihomo-card-body \
    mihomo-stat-grid mihomo-stat mihomo-stat-label mihomo-stat-value \
    mihomo-metric-grid mihomo-metric mihomo-kv mihomo-section \
    mihomo-guide mihomo-mode-row mihomo-chips mihomo-chip \
    mihomo-proxy-layout mihomo-group-list mihomo-group-item \
    mihomo-node-list mihomo-node mihomo-node-name mihomo-delay \
    mihomo-picker-search mihomo-picker-list mihomo-picker-item \
    mihomo-copy-btn mihomo-empty mihomo-kv-strip mihomo-kv-rows \
    mihomo-inline-ctl mh-input-wide mh-col-index mihomo-query-bar \
    mihomo-editor-table mihomo-toast mihomo-save-toast; do
    grep -q "\.$req_class" "$STYLES_VOLT" || {
        echo "FAIL: styles.volt missing CSS class .$req_class"; exit 1;
    }
done
# 策略来源单选卡片与旧节点网格已删除
for gone_class in mihomo-radio-cards mihomo-radio-card mihomo-node-grid; do
    if grep -q "\.$gone_class" "$STYLES_VOLT"; then
        echo "FAIL: styles.volt must not keep removed CSS class .$gone_class"; exit 1
    fi
done
echo "  [PASS] styles.volt defines full card/stat/metric/kv/proxy/picker/toast CSS classes"

# 1.3.0 Dashboard 化增量静态门禁（P3）
# ④-d index.volt 3-Tab 结构、概览卡片 ID 与新增 DOM 元素断言
echo "--> Test 8d: index.volt Tab structure & overview element IDs..."
# BS3 nav-tabs 与 3 个 tab-pane（面板与 API 已并入基本设置）
grep -q 'data-toggle="tab"' "$INDEX_VOLT" || {
    echo "FAIL: index.volt missing data-toggle=\"tab\""; exit 1;
}
for tab_id in tab_overview tab_general tab_subscription; do
    grep -q "$tab_id" "$INDEX_VOLT" || {
        echo "FAIL: index.volt missing tab pane ID: $tab_id"; exit 1;
    }
done

# 概览新 id 契约（吸收原运行状态页：TUN/API 徽章、内核模式运行时切换、运行指标）
for ov_elem_id in \
    ov_state_dot ov_state_text ov_autostart ov_core_mode_select \
    btn_core_mode_apply core_mode_config core_mode_msg btn_ov_refresh \
    ov_uptime ov_memory ov_pid ov_tun ov_api ov_versions \
    ov_nodes ov_groups ov_rules ov_sub_result \
    ov_sub_time ov_btn_sub_update; do
    grep -q "$ov_elem_id" "$INDEX_VOLT" || {
        echo "FAIL: index.volt missing overview element ID: $ov_elem_id"; exit 1;
    }
done
# 概览不得再放跳转入口与结果文案（信息就地展示）
for gone_ov in ov_sub_msg ov_sub_masked 查看运行状态 打开策略组; do
    if grep -q "$gone_ov" "$INDEX_VOLT"; then
        echo "FAIL: index.volt overview must not contain: $gone_ov"; exit 1
    fi
done
echo "  [PASS] index.volt contains 3 nav-tabs panes and all overview element IDs"

# ④-e styles.volt 1.3.0 Design Tokens、关键帧动画与组件样式类断言
echo "--> Test 8e: styles.volt 1.3.0 tokens & classes..."
# 设计 Token 与品牌色声明/引用
grep -q -- "--mh-brand:[[:space:]]*#d94f00" "$STYLES_VOLT" || {
    echo "FAIL: styles.volt missing --mh-brand: #d94f00 token definition"; exit 1;
}
grep -q "var(--mh-brand)" "$STYLES_VOLT" || {
    echo "FAIL: styles.volt missing var(--mh-brand) reference"; exit 1;
}

# 关键帧动画
grep -q "@keyframes[[:space:]]\+mh-dot-pulse" "$STYLES_VOLT" || {
    echo "FAIL: styles.volt missing @keyframes mh-dot-pulse"; exit 1;
}
grep -q "mh-shimmer" "$STYLES_VOLT" || {
    echo "FAIL: styles.volt missing mh-shimmer keyframes or class"; exit 1;
}

# 新增样式类
for mh_class in \
    mihomo-status-dot mihomo-stat-card \
    mihomo-modern-form mihomo-skeleton mihomo-save-toast mihomo-toast; do
    grep -q "\.$mh_class" "$STYLES_VOLT" || {
        echo "FAIL: styles.volt missing CSS class .$mh_class"; exit 1;
    }
done
# 全站轻提示组件必须存在（成功类反馈统一走 toast）
grep -q "function mhToast" "$STYLES_VOLT" || {
    echo "FAIL: styles.volt missing mhToast() helper"; exit 1;
}
echo "  [PASS] styles.volt defines 1.3.0 tokens, mh-dot-pulse/shimmer, and all new component classes"

# ④-f index.volt 1.3.0 JS 交互契约断言
echo "--> Test 8f: index.volt 1.3.0 JS interaction contracts..."
grep -q "shown\.bs\.tab" "$INDEX_VOLT" || {
    echo "FAIL: index.volt missing shown.bs.tab event handler"; exit 1;
}
grep -q "history\.replaceState" "$INDEX_VOLT" || {
    echo "FAIL: index.volt missing history.replaceState for tab hash synchronization"; exit 1;
}
grep -q "visibilitychange" "$INDEX_VOLT" || {
    echo "FAIL: index.volt missing visibilitychange listener for polling guard"; exit 1;
}
grep -q "selectpicker('refresh')" "$INDEX_VOLT" || {
    echo "FAIL: index.volt missing selectpicker('refresh') on tab shown"; exit 1;
}
grep -q "BootstrapDialog\.confirm" "$INDEX_VOLT" || {
    echo "FAIL: index.volt missing BootstrapDialog.confirm for service stop confirmation"; exit 1;
}

# 概览指标不走 5s 轮询守卫：不能有在 setInterval 中直接请求 subscription/get
if python3 -c "
import sys, re

with open('$INDEX_VOLT', 'r', encoding='utf-8') as f:
    content = f.read()

# 检查 setInterval 回调体内是否直接调用 subscription/get
# 匹配 setInterval(function...{ ... subscription/get ... }, ...)
pattern = r'setInterval\s*\(\s*function\s*\([^)]*\)\s*\{[^}]*subscription/get[^}]*\}'
if re.search(pattern, content, re.DOTALL):
    print('FAIL: found subscription/get directly inside setInterval callback')
    sys.exit(1)
" ; then
    echo "  [PASS] index.volt JS interaction contracts and polling guard verified"
else
    echo "FAIL: index.volt has forbidden direct subscription/get polling in setInterval"; exit 1
fi

# ④-g index.volt 负向断言：无 :9090、无 .html(/innerHTML、无 fetch(、无非 BMP emoji
echo "--> Test 8g: index.volt negative assertions (security/standards)..."
if grep -q ":9090" "$INDEX_VOLT"; then
    echo "FAIL: index.volt contains hardcoded :9090 literal"; exit 1
fi
if grep -E "\.html\(|innerHTML" "$INDEX_VOLT" >/dev/null 2>&1; then
    echo "FAIL: index.volt contains forbidden .html() or innerHTML assignment"; exit 1
fi
if grep -E "\bfetch\(" "$INDEX_VOLT" >/dev/null 2>&1; then
    echo "FAIL: index.volt contains forbidden fetch() API"; exit 1
fi

python3 - "$INDEX_VOLT" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
    content = fh.read()

# 扫描非 BMP 字符（emoji）
non_bmp = re.findall(r'[^\u0000-\uFFFF]', content)
if non_bmp:
    print(f"FAIL: {path} contains non-BMP characters/emojis: {set(non_bmp)}", file=sys.stderr)
    sys.exit(1)
PYEOF
echo "  [PASS] index.volt negative assertions passed (no :9090, no .html/innerHTML, no fetch, no non-BMP emojis)"

# ⑤ setup_firewall.php 不含 port 9090
FW_PHP="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/mihomo/setup_firewall.php"
[ -f "$FW_PHP" ] || { echo "FAIL: missing setup_firewall.php"; exit 1; }
if grep -q "9090" "$FW_PHP"; then
    echo "FAIL: setup_firewall.php contains port 9090"; exit 1;
fi
echo "  [PASS] setup_firewall.php contains no port 9090"

# Test 9: PHP 语法检查（有 php 时）
echo "--> Test 9: PHP syntax..."
if command -v php >/dev/null 2>&1; then
    for php_file in "$CTRL_DIR"/*.php "$CTRL_DIR"/Api/*.php; do
        php -l "$php_file" >/dev/null || { echo "FAIL: PHP syntax error in $php_file"; exit 1; }
    done
    echo "  [PASS] all controller PHP files lint clean"
else
    echo "  [SKIP] php not available"
fi

echo "===> WebGUI pages & configd API tests PASSED 100%!"
