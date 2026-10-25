#!/bin/sh
set -eu

# 一键安装回归测试：setup.sh 的用法与流程顺序、mihomo_setup.php 的结构与 URL 校验、
# +POST_INSTALL 的环境变量钩子、两套 build.sh 与 verify-package.sh 接线、configd 动作入口。
# 从仓库根运行：sh tests/test_oneclick_setup.sh
# 本机无 php 时，PHP 相关断言降级为结构检查并打印 [PASS] (php 不可用，结构检查)。

echo "===> Running one-click setup tests..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

SETUP_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/setup.sh"
SETUP_PHP="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/mihomo_setup.php"
POST_INSTALL="$ROOT_DIR/src/os-mihomo/packaging/freebsd/+POST_INSTALL"
ROOT_BUILD="$ROOT_DIR/scripts/build.sh"
INNER_BUILD="$ROOT_DIR/src/os-mihomo/build.sh"
VERIFY_PKG="$ROOT_DIR/scripts/verify-package.sh"
ACTIONS="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/service/conf/actions.d/actions_mihomo.conf"

fail() {
    echo "FAIL: $*"
    exit 1
}

# 取首个可执行调用行号：跳过整行注释、纯变量赋值与常见日志/提示行，
# 避免文件头说明与常量定义干扰流程顺序断言。
first_exec_line() {
    awk -v pat="$2" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ { next }
        /^[[:space:]]*(echo|printf|log|info|warn|warning|notice|msg|say|die|fail)([[:space:]]|$)/ { next }
        $0 ~ pat { print NR; exit }
    ' "$1"
}

# (a) setup.sh 存在、语法通过，文件头同时给出 pkg add 与手工执行两种一键用法
echo "--> Test 1: setup.sh exists, parses, and documents both one-click usages..."
[ -f "$SETUP_SH" ] || fail "missing $SETUP_SH"
sh -n "$SETUP_SH" || fail "shell syntax error: $SETUP_SH"
echo "  [PASS] sh -n setup.sh"

if ! head -n 40 "$SETUP_SH" | grep -F 'MIHOMO_SETUP_URL' | grep -F 'pkg add' | grep -q .; then
    fail "setup.sh 文件头缺少 'MIHOMO_SETUP_URL=... pkg add ...' 一条龙用法示例"
fi
if ! head -n 40 "$SETUP_SH" | grep -F 'setup.sh' | grep -F 'https://' | grep -q .; then
    fail "setup.sh 文件头缺少 'sh /usr/local/etc/mihomo/setup.sh https://...' 手工用法示例"
fi
echo "  [PASS] header documents pkg-add and manual usages"

# (b) 流程顺序：env 写入 -> 模型/Cron -> filter reload -> transport 分发 -> sub-update
echo "--> Test 2: setup.sh executes steps in the mandated order..."
_line_env="$(first_exec_line "$SETUP_SH" 'subscription_env_writer')"
_line_b64="$(first_exec_line "$SETUP_SH" 'b64:')"
_line_setup="$(first_exec_line "$SETUP_SH" '/usr/local/bin/php.*(SETUP_PHP|mihomo_setup[.]php)|PHP_BIN.*(SETUP_PHP|mihomo_setup[.]php)|(^|[^A-Za-z_])PHP[[:space:]].*(SETUP_PHP|mihomo_setup[.]php)')"
_line_reload="$(first_exec_line "$SETUP_SH" 'filter.*reload')"
_line_enable="$(first_exec_line "$SETUP_SH" 'transport-enable|TRANSPORT_ENABLE|transport_manager[.]sh.*enable|TRANSPORT_MGR.*enable')"
_line_disable="$(first_exec_line "$SETUP_SH" 'transport-disable|TRANSPORT_DISABLE|transport_manager[.]sh.*disable|TRANSPORT_MGR.*disable')"
_line_subupdate="$(first_exec_line "$SETUP_SH" 'sub-update|SUB_UPDATE')"

[ -n "$_line_env" ] || fail "setup.sh 未找到 subscription_env_writer 直调（configd 参数走 shell 展开，& 会截断命令，必须直调 PHP）"
[ -n "$_line_b64" ] || fail "setup.sh 必须以 b64: 前缀传 URL"
[ -n "$_line_setup" ] || fail "setup.sh 未找到 mihomo_setup.php 调用"
[ -n "$_line_reload" ] || fail "setup.sh 未找到 filter reload 调用"
[ -n "$_line_enable" ] || fail "setup.sh 未找到 transport-enable 调用"
[ -n "$_line_disable" ] || fail "setup.sh 未找到 transport-disable 调用"
[ -n "$_line_subupdate" ] || fail "setup.sh 未找到 sub-update 调用"

[ "$_line_env" -lt "$_line_setup" ] || \
    fail "流程顺序错误：sub-env-write(line $_line_env) 必须早于 mihomo_setup.php(line $_line_setup)"
echo "  [PASS] env writer (b64:) before mihomo_setup.php"

[ "$_line_setup" -lt "$_line_reload" ] || \
    fail "流程顺序错误：mihomo_setup.php(line $_line_setup) 必须早于 filter reload(line $_line_reload)"
echo "  [PASS] mihomo_setup.php before filter reload"

[ "$_line_reload" -lt "$_line_enable" ] || \
    fail "流程顺序错误：filter reload(line $_line_reload) 必须早于 transport-enable(line $_line_enable)（transparent 分支）"
echo "  [PASS] filter reload before transport-enable (transparent branch)"

_max_transport="$_line_enable"
if [ "$_line_disable" -gt "$_max_transport" ]; then
    _max_transport="$_line_disable"
fi
[ "$_line_subupdate" -gt "$_max_transport" ] || \
    fail "流程顺序错误：sub-update(line $_line_subupdate) 必须晚于 transport-enable/disable(line $_max_transport)"
echo "  [PASS] sub-update after transport enable/disable"

# (c) mihomo_setup.php 结构：phalcon 引导、模型命名空间、Cron 描述常量、URL 校验、无直接 config.xml 访问
echo "--> Test 3: mihomo_setup.php structure..."
[ -f "$SETUP_PHP" ] || fail "missing $SETUP_PHP"

_require_line="$(awk '
    {
        line = $0
        sub(/^[[:space:]]+/, "", line)
    }
    line == "" { next }
    substr(line, 1, 1) == "#" { next }
    substr(line, 1, 2) == "//" { next }
    substr(line, 1, 1) == "*" { next }
    substr(line, 1, 2) == "/*" { next }
    line ~ /(^|[^A-Za-z_])require(_once)?[[:space:](]/ { print NR ":" line; exit }
' "$SETUP_PHP")"
[ -n "$_require_line" ] || fail "mihomo_setup.php 没有任何 require 语句"
case "$_require_line" in
    *script/load_phalcon.php*) ;;
    *) fail "mihomo_setup.php 第一处 require 不是 script/load_phalcon.php: $_require_line" ;;
esac
echo "  [PASS] first require -> script/load_phalcon.php"

grep -Fq 'use OPNsense\Cron\Cron' "$SETUP_PHP" || \
    fail "mihomo_setup.php 缺少 use OPNsense\\Cron\\Cron（Cron 必须经模型 API）"
echo "  [PASS] use OPNsense\\Cron\\Cron"

grep -Fq 'use OPNsense\Mihomo\Mihomo' "$SETUP_PHP" || \
    fail "mihomo_setup.php 缺少 use OPNsense\\Mihomo\\Mihomo"
echo "  [PASS] use OPNsense\\Mihomo\\Mihomo"

grep -Fq 'os-mihomo auto sub-update' "$SETUP_PHP" || \
    fail "mihomo_setup.php 缺少 description 常量 'os-mihomo auto sub-update'"
grep -Fq 'os-mihomo watchdog' "$SETUP_PHP" || \
    fail "mihomo_setup.php 缺少 description 常量 'os-mihomo watchdog'"
echo "  [PASS] cron description constants present"

grep -Fq 'FILTER_VALIDATE_URL' "$SETUP_PHP" || \
    fail "mihomo_setup.php 缺少 FILTER_VALIDATE_URL 校验"
echo "  [PASS] FILTER_VALIDATE_URL present"

# config.xml 只允许经模型 API 写：可执行行不得出现 /conf/config.xml
if grep -vE '^[[:space:]]*(#|//|\*|/\*)' "$SETUP_PHP" | grep -Fq '/conf/config.xml'; then
    grep -nF '/conf/config.xml' "$SETUP_PHP"
    fail "mihomo_setup.php 可执行行直接引用 /conf/config.xml（必须只经模型 API）"
fi
echo "  [PASS] no direct /conf/config.xml access in executable lines"

# (d) +POST_INSTALL：环境变量钩子指向 setup.sh；manifest 内嵌约束零 % 零续行
echo "--> Test 4: +POST_INSTALL one-click hook and manifest safety..."
[ -f "$POST_INSTALL" ] || fail "missing $POST_INSTALL"
_hook_line="$(grep -vE '^[[:space:]]*#' "$POST_INSTALL" | grep -F 'MIHOMO_SETUP_URL' | grep -F 'setup.sh' || true)"
[ -n "$_hook_line" ] || fail "+POST_INSTALL 缺少 MIHOMO_SETUP_URL -> setup.sh 钩子"
echo "  [PASS] hook -> $(printf '%s\n' "$_hook_line" | head -n 1)"

_pct_count="$(grep -c '%' "$POST_INSTALL" || true)"
[ "$_pct_count" = "0" ] || fail "+POST_INSTALL 含 $_pct_count 个 % 字符（manifest 内嵌禁止）"
echo "  [PASS] zero % characters"

if grep -Eq '\\[[:space:]]*$' "$POST_INSTALL"; then
    grep -nE '\\[[:space:]]*$' "$POST_INSTALL"
    fail "+POST_INSTALL 含反斜杠续行（manifest 内嵌禁止）"
fi
echo "  [PASS] zero backslash continuations"

sh -n "$POST_INSTALL" || fail "shell syntax error: $POST_INSTALL"
echo "  [PASS] sh -n +POST_INSTALL"

# (e) 两套 build.sh 与 verify-package.sh 必须把两个新文件纳入打包/校验
echo "--> Test 5: build scripts and verify-package wiring..."
for _build in "$ROOT_BUILD" "$INNER_BUILD"; do
    [ -f "$_build" ] || fail "missing $_build"
    grep -Fq 'usr/local/etc/mihomo/setup.sh' "$_build" || \
        fail "$(basename "$_build") 未在 need_file/chmod 段引用 setup.sh"
    grep -Fq 'usr/local/opnsense/scripts/OPNsense/Mihomo/mihomo_setup.php' "$_build" || \
        fail "$(basename "$_build") 未在 need_file/chmod 段引用 mihomo_setup.php"
    echo "  [PASS] $(basename "$_build") references setup.sh + mihomo_setup.php"
done

[ -f "$VERIFY_PKG" ] || fail "missing $VERIFY_PKG"
_panel_files="$(awk '
    /^[[:space:]]*REQUIRED_PANEL_FILES=\(/ { flag = 1; next }
    flag && /^[[:space:]]*\)/ { exit }
    flag { print }
' "$VERIFY_PKG")"
[ -n "$_panel_files" ] || fail "verify-package.sh 未找到 REQUIRED_PANEL_FILES 数组"
printf '%s\n' "$_panel_files" | grep -Fq 'usr/local/etc/mihomo/setup.sh' || \
    fail "verify-package.sh REQUIRED_PANEL_FILES 缺少 usr/local/etc/mihomo/setup.sh"
printf '%s\n' "$_panel_files" | grep -Fq 'usr/local/opnsense/scripts/OPNsense/Mihomo/mihomo_setup.php' || \
    fail "verify-package.sh REQUIRED_PANEL_FILES 缺少 usr/local/opnsense/scripts/OPNsense/Mihomo/mihomo_setup.php"
echo "  [PASS] verify-package.sh REQUIRED_PANEL_FILES contains both paths"

# (f) setup.sh 依赖的 configd 入口
echo "--> Test 6: configd actions required by setup..."
[ -f "$ACTIONS" ] || fail "missing $ACTIONS"
for _action in sub-env-write watchdog; do
    grep -Fxq "[$_action]" "$ACTIONS" || fail "actions_mihomo.conf missing [$_action]"
    echo "  [PASS] action [$_action] present"
done

# (g) php 可用时动态验证 URL 校验；否则降级为结构检查
echo "--> Test 7: dynamic URL validation (or structural fallback)..."
if command -v php >/dev/null 2>&1 && [ -r /usr/local/opnsense/mvc/script/load_phalcon.php ] && [ -r /conf/config.xml ]; then
    _payload="https://x/'; echo INJECTED; #'"
    _dyn_rc=0
    _dyn_out="$(php "$SETUP_PHP" "$_payload" transparent 1 o24h 2>/dev/null)" || _dyn_rc=$?
    [ "$_dyn_rc" -ne 0 ] || fail "mihomo_setup.php 接受了注入 URL（应拒绝并以非零退出）"
    [ -n "$_dyn_out" ] || fail "mihomo_setup.php 拒绝注入 URL 时没有输出 JSON"
    [ "$(printf '%s\n' "$_dyn_out" | wc -l | tr -d ' ')" -eq 1 ] || \
        fail "mihomo_setup.php 拒绝输出不是单行 JSON"
    printf '%s\n' "$_dyn_out" | php -r '
$raw = stream_get_contents(STDIN);
$data = json_decode($raw, true);
if (!is_array($data)) {
    fwrite(STDERR, "not json\n");
    exit(1);
}
if (!isset($data["result"]) || $data["result"] !== "failed") {
    fwrite(STDERR, "result is not failed\n");
    exit(1);
}
' || fail "mihomo_setup.php 拒绝输出的 JSON 不可解析或 result 不是 failed"
    echo "  [PASS] injection payload rejected with parseable JSON (exit $_dyn_rc)"
elif command -v php >/dev/null 2>&1; then
    echo "  [PASS] mihomo_setup.php URL 校验 (php 可用但非 OPNsense 环境，结构检查)"
else
    echo "  [PASS] mihomo_setup.php URL 校验 (php 不可用，结构检查)"
fi

# setup.sh 用法报错分支：无参数调用必须非零退出（不依赖 php）
_usage_rc=0
# 清空一键安装环境变量，保证是真正的“无参数”调用
_usage_out="$(unset MIHOMO_SETUP_URL MIHOMO_SETUP_TRANSPORT MIHOMO_SETUP_INTERVAL; sh "$SETUP_SH" 2>&1)" || \
    _usage_rc=$?
[ "$_usage_rc" -ne 0 ] || fail "setup.sh 无参数调用应走用法报错分支并返回非零退出码"
echo "  [PASS] setup.sh no-arg -> exit $_usage_rc ($(printf '%s\n' "$_usage_out" | head -n 1))"

echo "===> One-click setup tests PASSED!"
