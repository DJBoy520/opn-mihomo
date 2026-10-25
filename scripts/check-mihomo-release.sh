#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
VERSION_ENV="${1:-"$ROOT_DIR/src/os-mihomo/build/mihomo-version.env"}"

die() {
    echo "error: $*" >&2
    exit 1
}

[ -f "$VERSION_ENV" ] || die "version env file not found: $VERSION_ENV"
. "$VERSION_ENV"

echo "============================================================"
echo "          MetaCubeX Mihomo Release Check Report             "
echo "============================================================"
echo " Current Pinned Version : ${MIHOMO_VERSION:-unknown}"
echo " Current Pinned Commit  : ${MIHOMO_COMMIT:-unknown}"
echo " Current Target Asset   : ${MIHOMO_ASSET:-unknown}"
echo " Current Target SHA256  : ${MIHOMO_SHA256:-unknown}"
echo "------------------------------------------------------------"

LATEST_VERSION="$(curl -sSL https://github.com/MetaCubeX/mihomo/releases/download/v1.19.30/version.txt 2>/dev/null || echo "failed")"
if [ "$LATEST_VERSION" = "failed" ]; then
    # Fallback to querying GitHub releases html
    echo "==> Warning: Direct version probe unreachable, checking upstream release page..."
    LATEST_VERSION="$(curl -sSL https://github.com/MetaCubeX/mihomo/releases | grep -o 'v1\.[0-9]\+\.[0-9]\+' | head -n 1 || echo "unknown")"
fi

echo " Upstream Latest Probe  : $LATEST_VERSION"

if [ "$LATEST_VERSION" != "unknown" ] && [ "$LATEST_VERSION" != "failed" ]; then
    if [ "$LATEST_VERSION" = "$MIHOMO_VERSION" ]; then
        echo " Status                 : UP TO DATE (Matches pinned version $MIHOMO_VERSION)"
    else
        echo " Status                 : NEW RELEASE AVAILABLE -> $LATEST_VERSION"
        echo " Note                   : Manual review and audit required before bumping version."
    fi
else
    echo " Status                 : UNABLE TO CONTACT UPSTREAM (Network/Rate limited)"
fi
echo "============================================================"
