#!/bin/sh
set -eu

# test_repo_hygiene.sh - 仓库结构与清洁度门禁
# 断言：
# 1. repo/*/All 只允许 os-mihomo-*.pkg
# 2. 不存在 repo/FreeBSD:14:amd64 目录
# 3. src/ 下只有 os-mihomo 目录
# 4. git ls-files 中无 output/ 文件
# 5. 仓库根存在 opn-mihomo.conf 且内容含 opn-mihomo: 与 djboy520.github.io
# 6. 不存在 opnwall.conf

echo "===> Running repository hygiene gate checks..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# 1. repo/*/All 只允许 os-mihomo-*.pkg
echo "--> Test 1: checking repo/*/All contains only os-mihomo-*.pkg..."
for pkg in "$ROOT_DIR"/repo/*/All/*; do
    if [ -f "$pkg" ]; then
        filename="$(basename "$pkg")"
        case "$filename" in
            os-mihomo-*.pkg) ;;
            *) fail "Disallowed package file found in repo: $pkg" ;;
        esac
    fi
done
echo "  [PASS] repo/*/All contains only os-mihomo-*.pkg."

# 2. 不存在 repo/FreeBSD:14:amd64
echo "--> Test 2: asserting no repo/FreeBSD:14:amd64 directory exists..."
if [ -d "$ROOT_DIR/repo/FreeBSD:14:amd64" ]; then
    fail "repo/FreeBSD:14:amd64 directory still exists"
fi
echo "  [PASS] repo/FreeBSD:14:amd64 is absent."

# 3. src/ 下只有 os-mihomo
echo "--> Test 3: checking src/ contains only os-mihomo..."
for dir in "$ROOT_DIR"/src/*; do
    if [ -d "$dir" ]; then
        dirname="$(basename "$dir")"
        if [ "$dirname" != "os-mihomo" ]; then
            fail "Disallowed directory found in src/: $dirname"
        fi
    fi
done
echo "  [PASS] src/ contains only os-mihomo."

# 4. git ls-files 中无 output/ 文件
echo "--> Test 4: asserting no output/ files tracked by git..."
tracked_output=$(cd "$ROOT_DIR" && git ls-files "output/*" "output" 2>/dev/null || true)
if [ -n "$tracked_output" ]; then
    fail "git is tracking output/ files: $tracked_output"
fi
echo "  [PASS] no output/ files tracked in git."

# 5. 仓库根存在 opn-mihomo.conf 且内容含 opn-mihomo: 与 djboy520.github.io
echo "--> Test 5: checking opn-mihomo.conf existence and content..."
CONF_FILE="$ROOT_DIR/opn-mihomo.conf"
if [ ! -f "$CONF_FILE" ]; then
    fail "opn-mihomo.conf does not exist at repository root"
fi
grep -qF 'opn-mihomo:' "$CONF_FILE" || fail "opn-mihomo.conf does not contain repo id 'opn-mihomo:'"
grep -qF 'djboy520.github.io' "$CONF_FILE" || fail "opn-mihomo.conf does not contain 'djboy520.github.io'"
echo "  [PASS] opn-mihomo.conf verified."

# 6. 不存在 opnwall.conf
echo "--> Test 6: asserting opnwall.conf is absent..."
if [ -f "$ROOT_DIR/opnwall.conf" ]; then
    fail "legacy opnwall.conf still exists at repository root"
fi
echo "  [PASS] opnwall.conf is absent."

echo "===> All repository hygiene gate checks PASSED."
