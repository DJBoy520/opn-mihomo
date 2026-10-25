#!/bin/sh
set -eu

# test_version_source.sh - 验证单一版本真源与无版本字面量赋值
# 风格对齐其他门禁：set -eu + fail()

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

echo "===> Running single version source tests..."

VERSION_FILE="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/version/mihomo"

# (a) 断言 version/mihomo JSON 含 product_version 且非空
echo "--> Test 1: checking product_version in $VERSION_FILE..."
[ -f "$VERSION_FILE" ] || fail "version file not found: $VERSION_FILE"

PRODUCT_VERSION="$(sed -n 's/.*"product_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_FILE" | tr -d '[:space:]')"
[ -n "$PRODUCT_VERSION" ] || fail "product_version is missing or empty in $VERSION_FILE"
echo "  [PASS] product_version is '$PRODUCT_VERSION'"

# (b) 断言 src/os-mihomo/Makefile 与 scripts/build.sh、src/os-mihomo/build.sh 中 grep -E 'VERSION[?+:]?=[[:space:]]*[0-9]+\.' 零命中
echo "--> Test 2: asserting no literal VERSION assignment in Makefile and build scripts..."
TARGET_ASSIGN_FILES="
$ROOT_DIR/src/os-mihomo/Makefile
$ROOT_DIR/scripts/build.sh
$ROOT_DIR/src/os-mihomo/build.sh
"

for f in $TARGET_ASSIGN_FILES; do
    [ -f "$f" ] || fail "target file for check (b) does not exist: $f"
    if grep -nE 'VERSION[?+:]?=[[:space:]]*[0-9]+\.' "$f"; then
        fail "found forbidden literal VERSION assignment in $f"
    fi
done
echo "  [PASS] no literal VERSION assignment found"

# (c) 断言 grep -rE '1\.4\.[0-9]' scripts/ src/os-mihomo/build.sh src/os-mihomo/Makefile src/os-mihomo/packaging/ 零命中（docs/README 不在范围）
echo "--> Test 3: asserting no '1.4.[0-9]' literal version occurrences in build/packaging files..."
SEARCH_TARGETS="
$ROOT_DIR/scripts
$ROOT_DIR/src/os-mihomo/build.sh
$ROOT_DIR/src/os-mihomo/Makefile
$ROOT_DIR/src/os-mihomo/packaging
"

HITS="$(grep -rnE '1\.4\.[0-9]' $SEARCH_TARGETS 2>/dev/null || true)"
if [ -n "$HITS" ]; then
    echo "$HITS" >&2
    fail "found hardcoded 1.4.x version literal in scripts/ or packaging"
fi
echo "  [PASS] no 1.4.[0-9] version literals found in target build/packaging files"

echo "===> All version source tests PASSED!"
