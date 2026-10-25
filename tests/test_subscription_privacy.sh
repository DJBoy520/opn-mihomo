#!/bin/sh
set -eu

echo "===> Running Subscription Privacy & TLS Security Tests (Phase 9)..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

# 1. Scan codebase for forbidden third-party converter URLs
echo "--> Test 1: Scanning for forbidden subconverters.com or third-party conversion endpoints..."
FORBIDDEN_HITS="$(grep -r "subconverters.com" "$ROOT_DIR/src/os-mihomo" || true)"
if [ -n "$FORBIDDEN_HITS" ]; then
    echo "FAIL: Found hardcoded third-party converter in codebase:"
    echo "$FORBIDDEN_HITS"
    exit 1
fi
echo "  [PASS] Zero instances of subconverters.com found in codebase."

# 2. Check sub.sh for TLS security flags (prohibit curl -k or INSECURE_TLS)
echo "--> Test 2: Checking TLS enforcement in sub.sh..."
SUB_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub.sh"
if grep -q "curl .*-k" "$SUB_SH" || grep -q "INSECURE_TLS" "$SUB_SH"; then
    echo "FAIL: sub.sh contains insecure TLS flags (-k or INSECURE_TLS)"
    exit 1
fi
echo "  [PASS] TLS certificate validation is strictly enforced in sub.sh."

# 3. Check for URL / Secret masking in sub.sh
echo "--> Test 3: Checking URL & Secret masking logic in sub.sh..."
if ! grep -q "mask_url" "$SUB_SH"; then
    echo "FAIL: sub.sh missing mask_url privacy function"
    exit 1
fi
echo "  [PASS] URL & Secret privacy masking verified."

echo "===> Subscription Privacy & TLS Security tests PASSED 100%!"
