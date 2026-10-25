#!/bin/sh
set -eu

# F3 持久自定义分流规则回归测试：模板占位符、sub_lib 共享合成库、rules-apply 离线应用、
# custom_rules_validate.php 白名单与注入拒绝。
# 从仓库根运行：sh tests/test_persistent_rules.sh

echo "===> Running persistent custom rules tests..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TEMPLATE="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/template_config.yaml"
SUB_LIB="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub_lib.sh"
SUB_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub.sh"
APPLY_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/custom_rules_apply.sh"
VALIDATOR="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/custom_rules_validate.php"

fail() {
    echo "FAIL: $*"
    exit 1
}

# 脚本是否 source 了 sub_lib.sh（允许直接写文件名，或先赋值变量再 source 变量）
sources_sub_lib() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*(\.[[:space:]]+|source[[:space:]]+)/ { sourced = 1 }
        /sub_lib\.sh/ { referenced = 1 }
        END { exit((sourced && referenced) ? 0 : 1) }
    ' "$1"
}

# (a) 模板 rules: 段下一行必须是自定义规则占位符（sub.sh 合成时插到规则最顶部）
echo "--> Test 1: template keeps the custom rules placeholder directly under rules:..."
awk '
    /^rules:[[:space:]]*$/ { want = 1; next }
    want { found = ($0 == "# __MIHOMO_CUSTOM_RULES__"); exit }
    END { exit(found ? 0 : 1) }
' "$TEMPLATE" || fail "$TEMPLATE: rules: is not followed by # __MIHOMO_CUSTOM_RULES__"
echo "  [PASS] $(basename "$TEMPLATE"): rules: -> # __MIHOMO_CUSTOM_RULES__"

# (b) sub_lib.sh 必须提供订阅合成/加锁/状态/缓存四个共享函数
echo "--> Test 2: sub_lib.sh exports the shared subscription helpers..."
[ -f "$SUB_LIB" ] || fail "missing $SUB_LIB"
for _fn in mihomo_lib_compose mihomo_lib_lock_acquire mihomo_lib_status_write mihomo_lib_cache_store; do
    grep -Eq "^[[:space:]]*${_fn}[[:space:]]*\(\)" "$SUB_LIB" || \
        fail "sub_lib.sh missing function definition: $_fn"
    echo "  [PASS] sub_lib.sh defines $_fn"
done

# (c) sub.sh 必须复用 sub_lib.sh，且在 ATOMIC_UPDATER 成功之后才写订阅缓存
echo "--> Test 3: sub.sh caches the subscription only after the atomic update..."
sources_sub_lib "$SUB_SH" || fail "sub.sh does not source sub_lib.sh"
awk '
    /^[[:space:]]*#/ { next }
    /ATOMIC_UPDATER/ { a = NR }
    /mihomo_lib_cache_store[[:space:]]*\(\)/ { next }
    /mihomo_lib_cache_store/ { if (b == 0) b = NR }
    END { exit !(a && b && a < b) }
' "$SUB_SH" || fail "sub.sh must call mihomo_lib_cache_store after ATOMIC_UPDATER"
echo "  [PASS] sub.sh sources sub_lib.sh and calls mihomo_lib_cache_store after ATOMIC_UPDATER"

# (d) custom_rules_apply.sh：语法、开头 source sub_lib.sh、缓存缺失分支 exit 3
echo "--> Test 4: custom_rules_apply.sh degrades gracefully when the cache is missing..."
[ -f "$APPLY_SH" ] || fail "missing $APPLY_SH"
sh -n "$APPLY_SH" || fail "shell syntax error: $APPLY_SH"
sources_sub_lib "$APPLY_SH" || fail "custom_rules_apply.sh does not source sub_lib.sh"
_src_line="$(awk '/sub_lib\.sh/ { print NR; exit }' "$APPLY_SH")"
[ -n "$_src_line" ] || fail "custom_rules_apply.sh does not source sub_lib.sh"
[ "$_src_line" -le 40 ] || fail "custom_rules_apply.sh sources sub_lib.sh too late (line $_src_line)"
grep -Eq '^[[:space:]]*exit[[:space:]]+3([[:space:]]|$)' "$APPLY_SH" || \
    fail "custom_rules_apply.sh missing exit 3 for the missing-cache branch"
grep -q 'subscription-cache' "$APPLY_SH" || \
    fail "custom_rules_apply.sh does not reference the subscription cache"
echo "  [PASS] sh -n custom_rules_apply.sh; sub_lib.sh referenced at line $_src_line; cache miss -> exit 3"

# (e) custom_rules_validate.php：白名单、禁字符集、no-resolve、容量上限、模板组名解析
echo "--> Test 5: custom_rules_validate.php enforces the F3 whitelist and limits..."
[ -f "$VALIDATOR" ] || fail "missing $VALIDATOR"

for _type in DOMAIN DOMAIN-SUFFIX DOMAIN-KEYWORD IP-CIDR IP-CIDR6 GEOIP GEOSITE DST-PORT; do
    grep -Eq "['\"]${_type}['\"]" "$VALIDATOR" || \
        fail "custom_rules_validate.php missing whitelist type: $_type"
done
# SRC-IP-CIDR / PROCESS-NAME 在 socks 入口下无意义，必须不在白名单里
grep -Eq "['\"](SRC-IP-CIDR|PROCESS-NAME)['\"]" "$VALIDATOR" && \
    fail "custom_rules_validate.php still whitelists SRC-IP-CIDR/PROCESS-NAME"
echo "  [PASS] 8 whitelist types present, SRC-IP-CIDR/PROCESS-NAME absent"

# 禁字符集：单/双引号、花括号、方括号、Tab 必须出现在同一个字符集字面量里
_charset_line="$(grep -E "\{\}\[\]" "$VALIDATOR" | grep -E "\\\\t" | head -n 1 || true)"
[ -n "$_charset_line" ] || fail "custom_rules_validate.php missing the forbidden charset charset (quotes/braces/brackets/Tab)"
case "$_charset_line" in
    *"'"*\"*|*\"*"'"*) ;;
    *) fail "forbidden charset does not include both single and double quotes: $_charset_line" ;;
esac
if ! printf '%s\n' "$_charset_line" | grep -Eq 'strpbrk|preg_match|strpbrk\(|str_contains|strpos'; then
    fail "forbidden charset is declared but never used for rejection: $_charset_line"
fi
echo "  [PASS] forbidden charset covers quotes, braces, brackets and Tab"

grep -Fq 'no-resolve' "$VALIDATOR" || fail "custom_rules_validate.php missing no-resolve handling"
grep -Eq 'IP-CIDR6?.*no-resolve|no-resolve.*IP-CIDR|GEOIP' "$VALIDATOR" || \
    fail "no-resolve is not restricted to IP-CIDR/IP-CIDR6/GEOIP"
grep -Fq '32768' "$VALIDATOR" || fail "custom_rules_validate.php missing the 32KB (32768) limit"
grep -Eq '(^|[^0-9])200([^0-9]|$)' "$VALIDATOR" || \
    fail "custom_rules_validate.php missing the 200 rule line limit"
grep -Fq 'template_config.yaml' "$VALIDATOR" || \
    fail "custom_rules_validate.php does not read template_config.yaml"
grep -Fq 'proxy-groups' "$VALIDATOR" || \
    fail "custom_rules_validate.php does not parse proxy-groups names from the template"
echo "  [PASS] no-resolve / 32768 / 200 / template proxy-groups checks present"

# (f) 有 php 时做真实验证；本机（Linux 开发机）通常没有 php，退化为结构检查
echo "--> Test 6: dynamic validation of good and injected rule files..."
if command -v php >/dev/null 2>&1; then
    TMP_RULES_DIR="$(mktemp -d /tmp/test-rules.XXXXXX)"
    trap 'rm -rf "$TMP_RULES_DIR"' EXIT

    json_valid() {
        printf '%s' "$1" | php -r '
            $d = json_decode(stream_get_contents(STDIN), true);
            exit(is_array($d) ? 0 : 1);
        ' 2>/dev/null
    }

    json_ok() {
        printf '%s' "$1" | php -r '
            $d = json_decode(stream_get_contents(STDIN), true);
            exit((is_array($d) && !empty($d["valid"])) ? 0 : 1);
        ' 2>/dev/null
    }

    printf '%s\n' 'DOMAIN,example.com,DIRECT' 'DOMAIN-SUFFIX,example.org,REJECT' \
        'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve' > "$TMP_RULES_DIR/good.txt"
    _out="$(MIHOMO_TEMPLATE_FILE="$TEMPLATE" php "$VALIDATOR" "$TMP_RULES_DIR/good.txt" 2>/dev/null)" || \
        fail "validator rejected a valid rule file: $_out"
    json_valid "$_out" || fail "validator output is not JSON for the good file: $_out"
    json_ok "$_out" || fail "validator did not report valid=true for the good file: $_out"
    echo "  [PASS] valid rules accepted"

    for _bad in 'DOMAIN,"q",DIRECT' 'DOMAIN-SUFFIX,x.com,DIRECT # c' 'PROCESS-NAME,x,DIRECT' 'DOMAIN,x.com'; do
        printf '%s\n' "$_bad" > "$TMP_RULES_DIR/bad.txt"
        _rc=0
        _out="$(MIHOMO_TEMPLATE_FILE="$TEMPLATE" php "$VALIDATOR" "$TMP_RULES_DIR/bad.txt" 2>/dev/null)" || _rc=$?
        json_valid "$_out" || fail "validator output is not JSON for rejected sample: $_bad"
        if [ "$_rc" -eq 0 ] && json_ok "$_out"; then
            fail "validator accepted injection sample: $_bad"
        fi
        echo "  [PASS] rejected: $_bad"
    done
else
    echo "  [PASS] (php 不可用，结构检查)"
fi

echo "===> Persistent custom rules tests PASSED!"
