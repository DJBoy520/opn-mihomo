#!/bin/sh
set -eu

# v3 socks 核心模式回归测试：配置、安装钩子、订阅原子更新、system-status 动作与脚本语法。
# 从仓库根运行：sh tests/test_socks_mode.sh

echo "===> Running SOCKS-core mode tests..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

CONFIG="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/config.yaml"
TEMPLATE="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/template_config.yaml"
POST_INSTALL="$ROOT_DIR/src/os-mihomo/packaging/freebsd/+POST_INSTALL"
SUB_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub.sh"
ACTIONS="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/service/conf/actions.d/actions_mihomo.conf"
STATUS_PY="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/system_status.py"

fail() {
    echo "FAIL: $*"
    exit 1
}

# (a) config.yaml 与订阅模板的 tun 块必须显式 enable: false
echo "--> Test 1: tun block disabled in both configs..."
check_tun_disabled() {
    tun_file="$1"
    awk '
        /^tun:[[:space:]]*$/ { in_tun = 1; next }
        in_tun && /^[^[:space:]#]/ { in_tun = 0 }
        in_tun && /^[[:space:]]+enable:[[:space:]]*false([[:space:]]|#|$)/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$tun_file" || fail "$tun_file: tun.enable is not false"
    echo "  [PASS] $(basename "$tun_file"): tun.enable=false"
}
check_tun_disabled "$CONFIG"
check_tun_disabled "$TEMPLATE"

# (b) post-install 不得触碰防火墙、Unbound 或主规则集
echo "--> Test 2: +POST_INSTALL has no firewall/Unbound side effects..."
# 注释行仅作说明，检查对象是可执行内容
if grep -vE '^[[:space:]]*#' "$POST_INSTALL" | grep -Eiq 'setup_firewall|setup_unbound|filter reload|unbound'; then
    grep -vE '^[[:space:]]*#' "$POST_INSTALL" | grep -Ein 'setup_firewall|setup_unbound|filter reload|unbound'
    fail "+POST_INSTALL still references firewall/Unbound operations"
fi
echo "  [PASS] +POST_INSTALL clean"

# (c) sub.sh 不得预写生产配置，必须经 ATOMIC_UPDATER 原子替换
echo "--> Test 3: subscription update is atomic..."
if grep -Fq 'cp "$TMP_FINAL" "$Conf_Dir/config.yaml"' "$SUB_SH"; then
    fail "sub.sh still pre-writes production config.yaml"
fi
grep -Fq 'ATOMIC_UPDATER' "$SUB_SH" || fail "sub.sh missing ATOMIC_UPDATER"
grep -Fq '"$ATOMIC_UPDATER" "$TMP_FINAL" reload' "$SUB_SH" || \
    fail "sub.sh does not hand the temp config to ATOMIC_UPDATER"
echo "  [PASS] sub.sh applies config only through ATOMIC_UPDATER"

# (d) system-status action 指向独立脚本，且不再内联 python
echo "--> Test 4: system-status action points to system_status.py..."
if ! awk '
    /^\[system-status\]$/ { in_block = 1; next }
    /^\[/ { in_block = 0 }
    in_block && /^command:\/usr\/local\/bin\/python3 \/usr\/local\/opnsense\/scripts\/OPNsense\/Mihomo\/system_status\.py$/ { found = 1 }
    END { exit(found ? 0 : 1) }
' "$ACTIONS"; then
    fail "actions_mihomo.conf [system-status] does not call system_status.py"
fi
if grep -Fq 'python3 -c' "$ACTIONS"; then
    fail "actions_mihomo.conf still contains the inline python command"
fi
echo "  [PASS] system-status -> system_status.py"

# (e) 工作流 A 改动的 shell 脚本语法
echo "--> Test 5: shell syntax of touched scripts..."
for sh_file in \
    "$ROOT_DIR"/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/service_manager.sh \
    "$ROOT_DIR"/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/watchdog.sh \
    "$ROOT_DIR"/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/secret_manager.sh \
    "$ROOT_DIR"/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/atomic_config_updater.sh \
    "$ROOT_DIR"/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub.sh \
    "$ROOT_DIR"/src/os-mihomo/packaging/freebsd/+POST_INSTALL \
    "$ROOT_DIR"/src/os-mihomo/packaging/freebsd/+PRE_DEINSTALL \
    "$ROOT_DIR"/src/os-mihomo/packaging/freebsd/+POST_DEINSTALL; do
    sh -n "$sh_file" || fail "shell syntax error: $sh_file"
    echo "  [PASS] sh -n $(basename "$sh_file")"
done

# (f) system_status.py 必须始终输出单行合法 JSON（异常时为 {}，退出码 0）
echo "--> Test 6: system_status.py emits valid JSON with exit 0..."
command -v python3 >/dev/null 2>&1 || fail "python3 not available"
status_out="$(python3 "$STATUS_PY")" || fail "system_status.py exited non-zero"
printf '%s\n' "$status_out" | python3 -c '
import json
import sys
data = json.load(sys.stdin)
assert isinstance(data, dict), "system_status.py output is not a JSON object"
' || fail "system_status.py did not emit valid JSON"
[ "$(printf '%s\n' "$status_out" | wc -l | tr -d ' ')" -eq 1 ] || \
    fail "system_status.py output is not a single line"
echo "  [PASS] system_status.py -> $status_out"

# (g) 追加回归点：watchdog 兜底、卸载保留配置、secret 安全、DNS/构建与运维脚本
echo "--> Test 7: additional v3 regression points..."

WD_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/watchdog.sh"
SM_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/service_manager.sh"
SEC_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/secret_manager.sh"
POST_DEINSTALL="$ROOT_DIR/src/os-mihomo/packaging/freebsd/+POST_DEINSTALL"
NEW_SYSLOG="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/newsyslog.conf.d/mihomo.conf"
SETUP_UNBOUND="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/mihomo/setup_unbound.php"
VERSION_ENV="$ROOT_DIR/src/os-mihomo/build/mihomo-version.env"
ROOT_BUILD="$ROOT_DIR/scripts/build.sh"

grep -q 'port_listening 1053' "$WD_SH" || fail "watchdog missing DNS(1053) fallback check"
# §2.6 控制面/数据面解耦：API 探测失败只告警 + api-bind reconcile，不得 trigger_failopen
grep -q 'api_bind_manager' "$WD_SH" || fail "watchdog missing api-bind reconcile on API failure"
if grep -q 'trigger_failopen "Mihomo local API' "$WD_SH"; then
    fail "watchdog still fail-opens on API failure (control-plane must not kill data-plane)"
fi
grep -Fq 'setup_unbound' "$WD_SH" && fail "watchdog still touches Unbound"
# v1.0.5 起允许 watchdog 仅操作 mihomo-transport anchor（fail-open 清空 + recover 重挂）：
# 出现任何未锚定到 mihomo-transport 的 pfctl 调用仍视为违规
if grep -n 'pfctl' "$WD_SH" | grep -Ev 'pfctl -a mihomo-transport'; then
    fail "watchdog uses pfctl outside the mihomo-transport anchor"
fi
grep -q 'tun_enabled()' "$SM_SH" || fail "service_manager missing tun_enabled() (socks mode)"
awk '/Already running/{a=NR} /Config validation/{b=NR} END{exit !(a && b && a<b)}' "$SM_SH" || \
    fail "service_manager must check running instance before config validation"
grep -q 'os-mihomo-removed' "$POST_DEINSTALL" || fail "+POST_DEINSTALL should archive config instead of deleting"
# v1.0.5 起 secret 注入逻辑位于 sub_lib.sh 的 compose 函数（sub.sh 只负责编排），
# ENVIRON 传递（不进 argv）的约束断言随之指向库文件
SUB_LIB_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub_lib.sh"
grep -q 'ENVIRON' "$SUB_LIB_SH" || fail "sub_lib.sh secret must pass via ENVIRON (not argv)"
grep -qE 'secret[[:space:]]*:' "$SUB_SH" && grep -qE 'printf .secret:' "$SUB_SH" && \
    fail "sub.sh must not inject secret directly anymore (moved to sub_lib compose)"
grep -q 'mktemp' "$SEC_SH" || fail "secret_manager still leaks secret via argv"
grep -q 'mihomo_watchdog.log' "$NEW_SYSLOG" || fail "newsyslog missing watchdog log rotation"
grep -q 'createElement($missing)' "$SETUP_UNBOUND" || fail "setup_unbound.php missing missing-node autorepair"
grep -q 'ZASHBOARD_SHA256' "$VERSION_ENV" || fail "zashboard not pinned in version env"
grep -q 'ZASH_STAGE' "$ROOT_BUILD" || fail "root build.sh does not stage bundled dashboard"
grep -q 'geo-auto-update: false' "$CONFIG" || fail "config.yaml must disable geo auto update"
grep -Eq '^[[:space:]]*external-ui-url:' "$CONFIG" && fail "config.yaml must not carry external-ui-url (runtime download)"
grep -q '禁止使用 http' "$SUB_SH" || fail "sub.sh must reject plain http subscription URLs"
# 陈旧锁自动清理随锁机制一起移入 sub_lib.sh（mihomo_lib_lock_acquire）
grep -q '陈旧锁' "$SUB_LIB_SH" || fail "sub_lib.sh missing stale-lock cleanup"
test -f "$ROOT_DIR/scripts/opnsense/backup.sh" && \
test -f "$ROOT_DIR/scripts/opnsense/rescue.sh" && \
test -f "$ROOT_DIR/scripts/opnsense/verify.sh" || fail "operator scripts (backup/rescue/verify) missing"
for pkg_script in "$ROOT_DIR/src/os-mihomo/packaging/freebsd/+POST_INSTALL" \
                  "$ROOT_DIR/src/os-mihomo/packaging/freebsd/+PRE_DEINSTALL" \
                  "$ROOT_DIR/src/os-mihomo/packaging/freebsd/+POST_DEINSTALL"; do
    grep -qE '\\[[:space:]]*$' "$pkg_script" && \
        fail "manifest-embedded $pkg_script uses backslash line continuation (breaks under pkg/UCL)"
done
echo "  [PASS] additional regression points"

echo "===> SOCKS-core mode tests PASSED!"
