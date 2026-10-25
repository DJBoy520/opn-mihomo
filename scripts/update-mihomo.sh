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

# Load pinned environment variables
. "$VERSION_ENV"

[ -n "${MIHOMO_VERSION:-}" ] || die "MIHOMO_VERSION not set in $VERSION_ENV"
[ -n "${MIHOMO_URL:-}" ] || die "MIHOMO_URL not set in $VERSION_ENV"
[ -n "${MIHOMO_SHA256:-}" ] || die "MIHOMO_SHA256 not set in $VERSION_ENV"

calculate_sha256() {
    target_file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$target_file" | awk '{print $1}'
    elif command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$target_file"
    else
        die "neither sha256sum nor sha256 command found"
    fi
}

TMP_DIR="$(mktemp -d /tmp/mihomo-download.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_PATH="$TMP_DIR/${MIHOMO_ASSET:-mihomo.gz}"
BINARY_PATH="$TMP_DIR/mihomo"

echo "==> Downloading official MetaCubeX release: $MIHOMO_URL"
if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 --connect-timeout 30 -o "$ARCHIVE_PATH" "$MIHOMO_URL"
elif command -v fetch >/dev/null 2>&1; then
    fetch -T 30 -o "$ARCHIVE_PATH" "$MIHOMO_URL"
else
    die "curl or fetch command not found"
fi

echo "==> Verifying archive SHA256"
ACTUAL_ARCHIVE_SHA256="$(calculate_sha256 "$ARCHIVE_PATH")"
if [ "$ACTUAL_ARCHIVE_SHA256" != "$MIHOMO_SHA256" ]; then
    die "SHA256 mismatch! Expected: $MIHOMO_SHA256, Got: $ACTUAL_ARCHIVE_SHA256"
fi
echo "==> Archive SHA256 verified: $ACTUAL_ARCHIVE_SHA256"

echo "==> Unpacking binary"
if gzip -t "$ARCHIVE_PATH" >/dev/null 2>&1; then
    gzip -dc "$ARCHIVE_PATH" > "$BINARY_PATH"
elif xz -t "$ARCHIVE_PATH" >/dev/null 2>&1; then
    xz -dc "$ARCHIVE_PATH" > "$BINARY_PATH"
else
    die "unsupported archive format"
fi

chmod 0755 "$BINARY_PATH"
[ -s "$BINARY_PATH" ] || die "unpacked binary is empty"

ACTUAL_BIN_SHA256="$(calculate_sha256 "$BINARY_PATH")"
echo "==> Unpacked binary SHA256: $ACTUAL_BIN_SHA256"

if [ -n "${MIHOMO_UNPACKED_SHA256:-}" ]; then
    if [ "$ACTUAL_BIN_SHA256" != "$MIHOMO_UNPACKED_SHA256" ]; then
        die "Unpacked binary SHA256 mismatch! Expected: $MIHOMO_UNPACKED_SHA256, Got: $ACTUAL_BIN_SHA256"
    fi
fi

echo "==> Inspecting binary architecture via file command"
if command -v file >/dev/null 2>&1; then
    FILE_INFO="$(file "$BINARY_PATH")"
    echo "    $FILE_INFO"
    case "$FILE_INFO" in
        *FreeBSD*|*ELF*64-bit*x86-64*)
            echo "==> Architecture verified: FreeBSD 64-bit ELF (x86-64)"
            ;;
        *)
            die "architecture mismatch: expected FreeBSD 64-bit ELF, got: $FILE_INFO"
            ;;
    esac
fi

# Store into cache directory for build consumption
CACHE_DIR="$ROOT_DIR/work/cache"
mkdir -p "$CACHE_DIR"
cp -f "$ARCHIVE_PATH" "$CACHE_DIR/$MIHOMO_ASSET"
cp -f "$BINARY_PATH" "$CACHE_DIR/mihomo"

echo "==> Official MetaCubeX Mihomo binary ready in cache: $CACHE_DIR/mihomo"
