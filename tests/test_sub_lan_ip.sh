#!/bin/sh
set -eu

echo "===> Running sub.sh LAN IP & Safety Checks..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
SUB_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub.sh"

# 1. 验证 sub.sh Shell 语法
echo "--> Test 1: Checking sub.sh shell syntax..."
sh -n "$SUB_SH" || { echo "FAIL: sub.sh shell syntax error"; exit 1; }
echo "  [PASS] sub.sh shell syntax verified."

# 2. 断言 sub.sh 不含 "php -r"、不含 "/etc/inc"
echo "--> Test 2: Asserting no php -r or /etc/inc in sub.sh..."
if grep -q "php -r" "$SUB_SH"; then
    echo "FAIL: sub.sh contains 'php -r'"
    exit 1
fi
if grep -q "/etc/inc" "$SUB_SH"; then
    echo "FAIL: sub.sh contains '/etc/inc'"
    exit 1
fi
echo "  [PASS] Zero instances of 'php -r' or '/etc/inc' in sub.sh."

# 3. 断言原子更新调用仍在（对既有原子更新/校验调用特征行 grep -q）
echo "--> Test 3: Checking atomic config updater invocation..."
if ! grep -q '\$ATOMIC_UPDATER.*\$TMP_FINAL.*reload' "$SUB_SH"; then
    echo "FAIL: sub.sh missing atomic updater reload invocation"
    exit 1
fi
if ! grep -q '原子更新配置' "$SUB_SH"; then
    echo "FAIL: sub.sh missing atomic update status message"
    exit 1
fi
echo "  [PASS] Atomic config updater invocation verified."

# 4. 断言 awk 兜底块存在（如 grep -q "169" 的特征行）
echo "--> Test 4: Checking awk fallback logic for LAN IP..."
if ! grep -q '169' "$SUB_SH"; then
    echo "FAIL: sub.sh missing awk 169 filter"
    exit 1
fi
if ! grep -q 'skip=(iface ~' "$SUB_SH"; then
    echo "FAIL: sub.sh missing awk virtual interface skip filter"
    exit 1
fi
if ! grep -q '192' "$SUB_SH"; then
    echo "FAIL: sub.sh missing awk private IP filter"
    exit 1
fi
echo "  [PASS] awk LAN IP logic verified."

echo "===> sub.sh LAN IP & Safety Checks PASSED 100%!"
