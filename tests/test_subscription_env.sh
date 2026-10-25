#!/bin/sh
set -eu

# F1 订阅面板化回归测试：sub-env-write 的 URL 强校验、单引号安全转义、动作接线与模型字段。
# 从仓库根运行：sh tests/test_subscription_env.sh

echo "===> Running subscription env (F1) tests..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

WRITER="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/subscription_env_writer.php"
ACTIONS="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/service/conf/actions.d/actions_mihomo.conf"
MODEL="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/models/OPNsense/Mihomo/Mihomo.xml"

fail() {
    echo "FAIL: $*"
    exit 1
}

# (a) env 写入器静态契约：https 强制、FILTER_VALIDATE_URL、单引号转义、拒绝 $( 与控制字符
echo "--> Test 1: subscription_env_writer.php validates and escapes the URL..."
[ -f "$WRITER" ] || fail "missing $WRITER"
grep -Fiq 'https' "$WRITER" || fail "subscription_env_writer.php does not enforce https"
grep -Fq 'FILTER_VALIDATE_URL' "$WRITER" || \
    fail "subscription_env_writer.php does not use FILTER_VALIDATE_URL"
grep -Fq 'str_replace' "$WRITER" || \
    fail "subscription_env_writer.php does not use str_replace for single-quote escaping"
if ! grep -Fq 'chr(39)' "$WRITER" && ! grep -Fq "\\''" "$WRITER"; then
    fail "subscription_env_writer.php does not escape single quotes as chr(39) or '\\''"
fi
if ! grep -Fq '$(' "$WRITER" && ! grep -Fq '\$\(' "$WRITER"; then
    fail "subscription_env_writer.php does not explicitly reject \$( command substitution"
fi
if ! grep -Fq '[:cntrl:]' "$WRITER" && ! grep -Fq '\x00' "$WRITER" && \
   ! grep -Fq '\x1f' "$WRITER" && ! grep -Fq '\x1F' "$WRITER" && \
   ! grep -Eq 'ord\([^)]*\)[[:space:]]*<=?[[:space:]]*(32|0x20)' "$WRITER"; then
    fail "subscription_env_writer.php does not explicitly reject control characters"
fi
echo "  [PASS] https + FILTER_VALIDATE_URL + str_replace('\\'') + \$( / control-char rejection"

# (b) 反证：不转义的单引号 env 会被 shell 解释执行——证明必须按 POSIX 规则转义
echo "--> Test 2: unescaped env demonstrates the injection (escaping is mandatory)..."
TMP_ENV_DIR="$(mktemp -d /tmp/test-subenv.XXXXXX)"
trap 'rm -rf "$TMP_ENV_DIR"' EXIT

ENV_BAD="$TMP_ENV_DIR/env.bad"
ENV_GOOD="$TMP_ENV_DIR/env.good"
PAYLOAD="https://x/'; echo INJECTED; #'"

cat > "$ENV_BAD" <<'EOF'
mihomo_URL='https://x/'; echo INJECTED; #'
EOF

_stdout="$(env -i /bin/sh -c '. "$0"' "$ENV_BAD" 2>&1)" || true
case "$_stdout" in
    *INJECTED*)
        echo "  [PASS] unescaped env executes 'echo INJECTED' — single-quote escaping is mandatory"
        ;;
    *)
        fail "unescaped env did not execute the injected command (test premise invalid): $_stdout"
        ;;
esac
_value="$(env -i /bin/sh -c '. "$0" >/dev/null; printf "%s" "$mihomo_URL"' "$ENV_BAD" 2>/dev/null)" || true
[ "$_value" = "https://x/" ] || \
    fail "unescaped env did not truncate mihomo_URL at the semicolon: [$_value]"

# (c) 正证：按 POSIX 规则转义（' -> '\''）后 source 不执行任何命令，且变量值完整保留
# 注：末尾的 '' 是重新打开后的空串闭合；等价于写入器的 str_replace(chr(39), "'\''") 结果。
echo "--> Test 3: escaped env keeps the payload literal and executes nothing..."
cat > "$ENV_GOOD" <<'EOF'
mihomo_URL='https://x/'\''; echo INJECTED; #'\'''
EOF

_stdout="$(env -i /bin/sh -c '. "$0"' "$ENV_GOOD" 2>&1)" || \
    fail "sourcing the escaped env failed: $_stdout"
case "$_stdout" in
    *INJECTED*) fail "escaped env still executed the injected command: $_stdout" ;;
esac
_value="$(env -i /bin/sh -c '. "$0"; printf "%s" "$mihomo_URL"' "$ENV_GOOD" 2>&1)" || \
    fail "reading mihomo_URL from the escaped env failed"
[ "$_value" = "$PAYLOAD" ] || fail "escaped env value mismatch: [$_value] != [$PAYLOAD]"
echo "  [PASS] no INJECTED output; mihomo_URL is the exact original payload"

# (d) configd 动作 sub-env-write 必须指向 PHP 写入器（面板不拼 shell）
echo "--> Test 4: actions_mihomo.conf wires sub-env-write to the writer..."
awk '
    /^\[sub-env-write\]$/ { in_block = 1; next }
    /^\[/ { in_block = 0 }
    in_block && /^command:.*subscription_env_writer\.php([[:space:]]|$)/ { found = 1 }
    END { exit(found ? 0 : 1) }
' "$ACTIONS" || fail "actions_mihomo.conf [sub-env-write] does not call subscription_env_writer.php"
echo "  [PASS] [sub-env-write] -> subscription_env_writer.php"

# (e) 模型 subscription 段：url / auto_update / auto_interval，且不提供 48h 选项
echo "--> Test 5: Mihomo.xml subscription model fields..."
[ -f "$MODEL" ] || fail "missing $MODEL"
_sub_block="$(awk '
    /<subscription>/ { in_sub = 1 }
    in_sub { print }
    in_sub && /<\/subscription>/ { exit }
' "$MODEL")"
[ -n "$_sub_block" ] || fail "Mihomo.xml has no <subscription> node"
printf '%s\n' "$_sub_block" | grep -Eq '<url([[:space:]>])' || \
    fail "Mihomo.xml <subscription> missing <url>"
printf '%s\n' "$_sub_block" | grep -Eq '<auto_update([[:space:]>])' || \
    fail "Mihomo.xml <subscription> missing <auto_update>"
printf '%s\n' "$_sub_block" | grep -Eq '<auto_interval([[:space:]>])' || \
    fail "Mihomo.xml <subscription> missing <auto_interval>"
if printf '%s\n' "$_sub_block" | grep -Eq '>48<|<48>|48h|48[[:space:]]*(小时|hours)'; then
    fail "Mihomo.xml <auto_interval> must not offer 48h"
fi
echo "  [PASS] subscription url/auto_update/auto_interval present, no 48h option"

echo "===> Subscription env (F1) tests PASSED!"
