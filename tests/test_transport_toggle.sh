#!/bin/sh
set -eu

# F2 透明代理开关回归测试：PF anchor 模板（只放 pass/route-to）、filter 钩子注册、
# transport_manager/mihomo_hev 生命周期、安装钩子时序、watchdog 清 anchor、configd 动作。
# 从仓库根运行：sh tests/test_transport_toggle.sh

echo "===> Running transparent transport toggle tests..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

PF_CONF="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/pf-transport.conf"
MIHOMO_INC="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/inc/plugins.inc.d/mihomo.inc"
TRANSPORT_MGR="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/transport_manager.sh"
HEV_RC="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/rc.d/mihomo_hev"
PRE_INSTALL="$ROOT_DIR/src/os-mihomo/packaging/freebsd/+PRE_INSTALL"
PRE_DEINSTALL="$ROOT_DIR/src/os-mihomo/packaging/freebsd/+PRE_DEINSTALL"
WATCHDOG="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/watchdog.sh"
SERVICE_MGR="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/service_manager.sh"
ACTIONS="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/service/conf/actions.d/actions_mihomo.conf"

fail() {
    echo "FAIL: $*"
    exit 1
}

# (a) anchor 模板只允许 pass/route-to：任何以 block/reject 开头的规则行都是红线
echo "--> Test 1: pf-transport.conf never blocks or rejects..."
[ -f "$PF_CONF" ] || fail "missing $PF_CONF"
if grep -Eq '^[[:space:]]*(block|reject)([[:space:]]|$)' "$PF_CONF"; then
    grep -nE '^[[:space:]]*(block|reject)([[:space:]]|$)' "$PF_CONF"
    fail "pf-transport.conf contains a block/reject rule (anchor must be pass/route-to only)"
fi
echo "  [PASS] no block/reject rules in pf-transport.conf"

# (b) bypass 表必须覆盖本机/RFC1918/组播/广播，route-to 规则只对表外目的生效
echo "--> Test 2: bypass table covers self, RFC1918, multicast and broadcast..."
grep -Fq 'table <mihomo_bypass>' "$PF_CONF" || fail "pf-transport.conf missing table <mihomo_bypass>"
_table_body="$(awk '
    /table <mihomo_bypass>/ { in_table = 1 }
    in_table { print }
    in_table && /}/ { exit }
' "$PF_CONF")"
[ -n "$_table_body" ] || fail "pf-transport.conf: could not read the mihomo_bypass table body"
for _net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 255.255.255.255; do
    case "$_table_body" in
        *"$_net"*) ;;
        *) fail "mihomo_bypass table missing $_net" ;;
    esac
done
grep -Eq 'route-to.*to ! <mihomo_bypass>' "$PF_CONF" || \
    fail "pf-transport.conf has no route-to rule with 'to ! <mihomo_bypass>'"
echo "  [PASS] bypass table complete and route-to excludes it"

# (c) mihomo.inc 只在模型 transport_mode=transparent 时注册 head+quick anchor
echo "--> Test 3: mihomo_firewall registers the anchor only in transparent mode..."
[ -f "$MIHOMO_INC" ] || fail "missing $MIHOMO_INC"
grep -Eq 'function[[:space:]]+mihomo_firewall[[:space:]]*\(' "$MIHOMO_INC" || \
    fail "mihomo.inc does not define mihomo_firewall"
grep -Fq "registerAnchor('mihomo-transport', 'fw', 0, 'head', true)" "$MIHOMO_INC" || \
    fail "mihomo.inc does not register mihomo-transport as fw/0/head/quick"
_reg_line="$(grep -n "registerAnchor('mihomo-transport'" "$MIHOMO_INC" | head -n 1 | cut -d: -f1)"
_mode_line="$(grep -n 'transport_mode' "$MIHOMO_INC" | head -n 1 | cut -d: -f1)"
_transparent_line="$(grep -n "'transparent'" "$MIHOMO_INC" | head -n 1 | cut -d: -f1)"
[ -n "$_reg_line" ] || fail "mihomo.inc has no registerAnchor('mihomo-transport') call"
[ -n "$_mode_line" ] || fail "mihomo.inc does not consult transport_mode"
[ -n "$_transparent_line" ] || fail "mihomo.inc does not compare against transparent"
[ "$_mode_line" -lt "$_reg_line" ] || fail "registerAnchor is not guarded by transport_mode"
[ "$_transparent_line" -lt "$_reg_line" ] || fail "registerAnchor is not guarded by transparent mode"
_guard="$(awk -v reg="$_reg_line" '
    NR < reg && /^[[:space:]]*if[[:space:]]*\(/ { last = $0 }
    END { print last }
' "$MIHOMO_INC")"
case "$_guard" in
    *transparent*) ;;
    *) fail "registerAnchor is not inside an if (transparent) block: $_guard" ;;
esac
echo "  [PASS] mihomo_firewall -> mihomo-transport (fw/0/head/quick) only when transparent"

# (d) transport_manager.sh 与 mihomo_hev 语法；PF 操作永远只碰命名 anchor
echo "--> Test 4: transport manager scripts and anchor-only pfctl usage..."
[ -f "$TRANSPORT_MGR" ] || fail "missing $TRANSPORT_MGR"
sh -n "$TRANSPORT_MGR" || fail "shell syntax error: $TRANSPORT_MGR"
[ -f "$HEV_RC" ] || fail "missing $HEV_RC"
sh -n "$HEV_RC" || fail "shell syntax error: $HEV_RC"
echo "  [PASS] sh -n transport_manager.sh mihomo_hev"

# 每个 pfctl 调用行都必须带 -a（永不触碰主规则集）；注释/纯路径赋值/探测行除外
if ! awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^$`(]*$/ { next }
    /command -v[[:space:]]+pfctl/ { next }
    /pfctl/ {
        if ($0 !~ /-a([[:space:]]|$)/) {
            print "  pfctl without -a at line " NR ": " $0
            bad = 1
        }
    }
    END { exit(bad ? 1 : 0) }
' "$TRANSPORT_MGR"; then
    fail "transport_manager.sh has a pfctl call without -a"
fi
grep -Fq 'mihomo-transport' "$TRANSPORT_MGR" || \
    fail "transport_manager.sh does not use the mihomo-transport anchor name"
grep -vE '^[[:space:]]*#' "$TRANSPORT_MGR" | grep -Eq '(^|[[:space:]])pfctl[[:space:]]' || \
    fail "transport_manager.sh has no pfctl invocation"
echo "  [PASS] every pfctl call is scoped with -a (mihomo-transport anchor)"

# (e) mihomo_hev：无 pkill、daemon -p 记 pid、stop 按 pidfile kill
echo "--> Test 5: mihomo_hev owns hev via pidfile (no global pkill)..."
if grep -vE '^[[:space:]]*#' "$HEV_RC" | grep -q 'pkill'; then
    fail "mihomo_hev still uses pkill (forbidden: kill by pidfile only)"
fi
awk '/daemon/ && /(^|[[:space:]])-p([[:space:]]|$)/ { found = 1 } END { exit(found ? 0 : 1) }' "$HEV_RC" || \
    fail "mihomo_hev does not start hev with daemon -p"
grep -q 'pidfile' "$HEV_RC" || fail "mihomo_hev does not declare a pidfile"
awk '
    /^[[:space:]]*#/ { next }
    /kill/ && /(pidfile|PID_FILE|\.pid|_pid)/ { found = 1 }
    END { exit(found ? 0 : 1) }
' "$HEV_RC" || fail "mihomo_hev stop does not kill by pidfile"
echo "  [PASS] mihomo_hev: daemon -p + pidfile kill, no pkill"

# (f) 安装/卸载钩子第一步切断传输层：transport flush/disable 先于任何其他 transport/PF 动作
#     （升级前置必须 flush 保留模式意图，卸载前置 disable）
echo "--> Test 6: pre-install/pre-deinstall tear down transport first..."
first_transport_action() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ { next }
        /pfctl[[:space:]]|[[:space:]]transport-(enable|disable|flush|status|recover)|transport_manager\.sh"?[[:space:]]+(enable|disable|flush|status|recover)|"\$TRANSPORT_MGR"[[:space:]]+(enable|disable|flush|status|recover)|[[:space:]](hev|mihomo_hev)([[:space:]]|$)/ {
            print NR ":" $0
            exit
        }
    ' "$1"
}
for _pkg_script in "$PRE_INSTALL" "$PRE_DEINSTALL"; do
    [ -f "$_pkg_script" ] || fail "missing $_pkg_script"
    _first="$(first_transport_action "$_pkg_script")"
    [ -n "$_first" ] || fail "$(basename "$_pkg_script") has no transport action"
    case "$_first" in
        *disable*|*flush*) ;;
        *) fail "$(basename "$_pkg_script") first transport action is not disable/flush: $_first" ;;
    esac
    echo "  [PASS] $(basename "$_pkg_script") -> transport teardown first"
done

# (g) fail-open：watchdog 判死不健康时必须清空 anchor（恢复直连，避免 route-to 黑洞）
echo "--> Test 7: watchdog flushes the transport anchor on fail-open..."
grep -Fq -- '-a mihomo-transport -F all' "$WATCHDOG" || \
    fail "watchdog.sh does not flush the mihomo-transport anchor on fail-open"
echo "  [PASS] watchdog -> pfctl -a mihomo-transport -F all"

# (h) service_manager：stop/failopen 先 flush（临时拆除、保留模式意图），start 末尾按模式 enable
echo "--> Test 8: service_manager toggles transport around stop/failopen/start..."
extract_func() {
    awk -v fn="$2" '
        $0 ~ "^" fn "[[:space:]]*\\(\\)" { in_fn = 1; next }
        in_fn && /^}/ { exit }
        in_fn { print }
    ' "$1"
}
_stop_body="$(extract_func "$SERVICE_MGR" do_stop)"
[ -n "$_stop_body" ] || fail "service_manager.sh has no do_stop()"
if ! printf '%s\n' "$_stop_body" | grep -Eiq 'transport'; then
    fail "do_stop does not tear down the transport layer"
fi
if ! printf '%s\n' "$_stop_body" | grep -q 'flush'; then
    fail "do_stop must use flush (mode intent preserved), not disable"
fi
echo "  [PASS] do_stop -> transport flush"

_failopen_body="$(extract_func "$SERVICE_MGR" do_failopen)"
[ -n "$_failopen_body" ] || fail "service_manager.sh has no do_failopen()"
if ! printf '%s\n' "$_failopen_body" | grep -Eiq 'transport'; then
    fail "do_failopen does not tear down the transport layer"
fi
if ! printf '%s\n' "$_failopen_body" | grep -q 'flush'; then
    fail "do_failopen must use flush (mode intent preserved), not disable"
fi
echo "  [PASS] do_failopen -> transport flush"

_start_body="$(extract_func "$SERVICE_MGR" do_start)"
[ -n "$_start_body" ] || fail "service_manager.sh has no do_start()"
if ! printf '%s\n' "$_start_body" | grep -Eiq 'transport'; then
    fail "do_start does not enable the transport layer by mode"
fi
if ! printf '%s\n' "$_start_body" | grep -q 'enable'; then
    fail "do_start does not enable the transport layer by mode"
fi
if ! printf '%s\n' "$_start_body" | grep -Eq 'transport-mode|TRANSPORT_MODE|transparent'; then
    fail "do_start enables transport without checking the mode"
fi
echo "  [PASS] do_start -> mode-aware transport enable"

# (i) configd 动作齐全（面板按钮全部有后端入口）
echo "--> Test 9: configd actions for subscription/rules/transport..."
for _action in sub-env-write rules-apply rules-recompose transport-enable transport-disable transport-status transport-recover; do
    grep -Fxq "[$_action]" "$ACTIONS" || fail "actions_mihomo.conf missing [$_action]"
    echo "  [PASS] action [$_action] present"
done

echo "===> Transparent transport toggle tests PASSED!"
