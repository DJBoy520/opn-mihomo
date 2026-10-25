#!/bin/sh
set -eu

# test_proxies_page.sh - 策略组页面、控制器、Menu、ACL与安全契约静态断言
# 覆盖任务书 §3 与设计方案 §3.4 / §7.1 的全部断言要求

echo "===> Running proxies page static assertion tests..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

BASE_CTRL="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/ProxiesController.php"
API_CTRL="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/ProxiesController.php"
VIEW_FILE="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/proxies.volt"
MENU_FILE="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/models/OPNsense/Mihomo/Menu/Menu.xml"
ACL_FILE="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/models/OPNsense/Mihomo/ACL/ACL.xml"

fail() {
    echo "FAIL: $*"
    exit 1
}

pass() {
    echo "  [PASS] $*"
}

# 1. 检查目标文件存在性
echo "--> Test 1: File existence..."
[ -f "$BASE_CTRL" ] || fail "Missing ProxiesController.php at $BASE_CTRL"
[ -f "$API_CTRL" ] || fail "Missing Api/ProxiesController.php at $API_CTRL"
[ -f "$VIEW_FILE" ] || fail "Missing proxies.volt at $VIEW_FILE"
[ -f "$MENU_FILE" ] || fail "Missing Menu.xml at $MENU_FILE"
[ -f "$ACL_FILE" ] || fail "Missing ACL.xml at $ACL_FILE"
pass "All target files exist"

# 2. 页面控制器 ProxiesController.php 基础结构
echo "--> Test 2: ProxiesController.php inheritance and action..."
grep -q "class ProxiesController extends \\\OPNsense\\\Base\\\IndexController" "$BASE_CTRL" || \
    fail "ProxiesController must extend \OPNsense\Base\IndexController"
grep -q "function indexAction" "$BASE_CTRL" || fail "ProxiesController missing indexAction"
grep -q "view->pick('OPNsense/Mihomo/proxies')" "$BASE_CTRL" || fail "ProxiesController must pick OPNsense/Mihomo/proxies"
pass "ProxiesController.php structure verified"

# 3. Menu.xml 与 ACL.xml
echo "--> Test 3: Menu.xml and ACL.xml registration..."
grep -q '<Proxies VisibleName="策略组" order="30" url="/ui/mihomo/proxies"/>' "$MENU_FILE" || \
    fail "Menu.xml must contain Proxies order 30 with url /ui/mihomo/proxies"
if grep -q '<Status VisibleName=' "$MENU_FILE"; then
    fail "Menu.xml must not keep 运行状态 entry（已并入常规设置概览）"
fi
grep -q '<Logs VisibleName="实时日志" order="50"' "$MENU_FILE" || \
    fail "Menu.xml Logs order must be 50"

# ACL 独立节点与 pattern
grep -q '<page-services-mihomo-proxies>' "$ACL_FILE" || fail "ACL.xml missing independent <page-services-mihomo-proxies>"
grep -q '<pattern>ui/mihomo/proxies\*</pattern>' "$ACL_FILE" || fail "ACL.xml missing pattern ui/mihomo/proxies*"
grep -q '<pattern>api/mihomo/proxies/\*</pattern>' "$ACL_FILE" || fail "ACL.xml missing pattern api/mihomo/proxies/*"
awk '/<page-services-mihomo-proxies>/,/<\/page-services-mihomo-proxies>/' "$ACL_FILE" | \
    grep -q '<pattern>api/mihomo/status/\*</pattern>' || \
    fail "ACL.xml proxies group must allow api/mihomo/status/* (内核模式徽章)"
pass "Menu.xml and ACL.xml configured correctly"

# 4. API 控制器契约与安全红线 (Api/ProxiesController.php)
echo "--> Test 4: Api/ProxiesController.php methods and security constraints..."
grep -q "function getGroupsAction" "$API_CTRL" || fail "Missing getGroupsAction"
grep -q "function getNodesAction" "$API_CTRL" || fail "Missing getNodesAction"
grep -q "function selectAction" "$API_CTRL" || fail "Missing selectAction"

# 4a. 安全红线：secret 临时配置传参与清理
grep -q "tempnam(" "$API_CTRL" || fail "Api/ProxiesController.php must use tempnam for curl config"
grep -q "chmod(" "$API_CTRL" || fail "Api/ProxiesController.php must chmod 0600 on curl config"
grep -q "\-K " "$API_CTRL" || fail "Api/ProxiesController.php must use -K for secret header passing"
grep -q "finally" "$API_CTRL" || fail "Api/ProxiesController.php must use finally block"
grep -q "unlink(" "$API_CTRL" || fail "Api/ProxiesController.php must unlink temp config file"

# 4b. 流式读取配置，绝不整文件读
grep -q "fopen(" "$API_CTRL" || fail "Api/ProxiesController.php must use fopen for streaming config"
grep -q "fgets(" "$API_CTRL" || fail "Api/ProxiesController.php must use fgets for streaming config"
if grep -E "(file_get_contents|\bfile\s*\()" "$API_CTRL" >/dev/null 2>&1; then
    fail "Api/ProxiesController.php violates streaming rule: contains file() or file_get_contents()"
fi

# 4c. 零硬编码：不含 :9090
if grep -q ":9090" "$API_CTRL"; then
    fail "Api/ProxiesController.php must not contain hardcoded :9090"
fi

# 4d. 主动测速已移出范围：不含 delay? 或 /delay 或 gstatic
if grep -E "(/delay|delay\?|gstatic)" "$API_CTRL" >/dev/null 2>&1; then
    fail "Api/ProxiesController.php must not contain /delay or gstatic active latency tests"
fi

# 4e. 响应白名单负向断言：不输出 extra, server, provider-name, dialer-proxy
for field in "extra" "server" "provider-name" "dialer-proxy"; do
    if grep -q "'$field'" "$API_CTRL"; then
        fail "Api/ProxiesController.php violates response whitelist: contains '$field'"
    fi
done

# 4f. HTTP 语义与参数校验：rawurlencode, Selector, 204, -m 5, -m 6, offset, limit, total, truncated
grep -q "rawurlencode(" "$API_CTRL" || fail "Api/ProxiesController.php missing rawurlencode"
grep -q "'Selector'" "$API_CTRL" || fail "Api/ProxiesController.php missing Selector validation"
grep -q "204" "$API_CTRL" || fail "Api/ProxiesController.php must accept 204 No Content as success"
grep -q "m 5" "$API_CTRL" || fail "Api/ProxiesController.php missing -m 5 timeout"
grep -q "m 6" "$API_CTRL" || fail "Api/ProxiesController.php missing -m 6 timeout"
grep -q "offset" "$API_CTRL" || fail "Api/ProxiesController.php missing offset pagination"
grep -q "limit" "$API_CTRL" || fail "Api/ProxiesController.php missing limit pagination"
grep -q "total" "$API_CTRL" || fail "Api/ProxiesController.php missing total field"
grep -q "truncated" "$API_CTRL" || fail "Api/ProxiesController.php missing truncated field"
pass "Api/ProxiesController.php security & contract assertions passed"

# 5. 视图 proxies.volt 断言
echo "--> Test 5: proxies.volt layout, classes, and rendering..."
grep -q "mh-glist" "$VIEW_FILE" || fail "proxies.volt missing mh-glist"
grep -q "mh-gcard" "$VIEW_FILE" || fail "proxies.volt missing mh-gcard"
grep -q "mh-ghead" "$VIEW_FILE" || fail "proxies.volt missing mh-ghead"
grep -q "mh-gbody" "$VIEW_FILE" || fail "proxies.volt missing mh-gbody"
grep -q "mh-mb-grid" "$VIEW_FILE" || fail "proxies.volt missing mh-mb-grid"
grep -q "mh-mb" "$VIEW_FILE" || fail "proxies.volt missing mh-mb"
grep -q "btn_refresh_proxies" "$VIEW_FILE" || fail "proxies.volt missing #btn_refresh_proxies"
if grep -q "group_search_input" "$VIEW_FILE"; then
    fail "proxies.volt must not keep group_search_input（搜索策略组已按需求移除）"
fi
grep -q "node_search_input" "$VIEW_FILE" || fail "proxies.volt missing node_search_input"
grep -q "inFlight" "$VIEW_FILE" || fail "proxies.volt missing inFlight guard"
grep -q "requestSeq" "$VIEW_FILE" || fail "proxies.volt missing requestSeq sequence guard"
grep -q "chk_include_global" "$VIEW_FILE" || fail "proxies.volt missing #chk_include_global"

# 已下线的旧双栏及分页结构不得回归
for gone in mihomo-proxy-layout mihomo-group-list mihomo-node-list proxies_prev proxies_next proxies_page_info; do
    if grep -q "$gone" "$VIEW_FILE"; then
        fail "proxies.volt must not keep removed element/class: $gone"
    fi
done

# 5a. 零硬编码与安全红线：无 :9090，全部 .text()，严禁 .html() / innerHTML
if grep -q ":9090" "$VIEW_FILE"; then
    fail "proxies.volt must not contain :9090"
fi
grep -q "\.text(" "$VIEW_FILE" || fail "proxies.volt missing safe .text() rendering"
if grep -E "(\.html\(|innerHTML)" "$VIEW_FILE" >/dev/null 2>&1; then
    fail "proxies.volt violates XSS safety rule: contains .html() or innerHTML"
fi

# 5b. 零 emoji 断言
python3 -c "
import re, sys
with open('$VIEW_FILE', 'r', encoding='utf-8') as f:
    text = f.read()
if re.search(r'[\U00010000-\U0010ffff]', text):
    print('FAIL: proxies.volt contains emojis')
    sys.exit(1)
"
pass "proxies.volt layout, classes, zero emoji, and security assertions passed"

# 6. Python XML 解析验证 Menu.xml 与 ACL.xml
echo "--> Test 6: Python XML parsing validation..."
python3 -c "
import xml.etree.ElementTree as ET
ET.parse('$MENU_FILE')
ET.parse('$ACL_FILE')
"
pass "Menu.xml and ACL.xml parsed cleanly"

echo "===> All proxies page tests PASSED!"
