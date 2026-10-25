#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
VERSION_ENV="${1:-"$ROOT_DIR/src/os-mihomo/build/hev-version.env"}"

die() {
    echo "error: $*" >&2
    exit 1
}

[ -f "$VERSION_ENV" ] || die "version env file not found: $VERSION_ENV"

# Load pinned environment variables
. "$VERSION_ENV"

[ -n "${HEV_VERSION:-}" ] || die "HEV_VERSION not set in $VERSION_ENV"
[ -n "${HEV_URL:-}" ] || die "HEV_URL not set in $VERSION_ENV"
[ -n "${HEV_SHA256:-}" ] || die "HEV_SHA256 not set in $VERSION_ENV"

echo "============================================================"
echo "       hev-socks5-tunnel Official Release Fetch / Verify    "
echo "============================================================"
echo " Pinned Version       : ${HEV_VERSION}"
echo " Pinned Asset         : ${HEV_ASSET:-hev-socks5-tunnel-freebsd-x86_64}"
echo " Expected SHA256      : ${HEV_SHA256}"
echo "------------------------------------------------------------"

calculate_sha256() {
    target_file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$target_file" | awk '{print $1}'
    elif command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$target_file"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$target_file" | awk '{print $1}'
    else
        die "neither sha256sum, sha256, nor shasum command found"
    fi
}

CACHE_DIR="$ROOT_DIR/work/cache"
mkdir -p "$CACHE_DIR"
CACHED_ASSET_FILE="$CACHE_DIR/${HEV_ASSET:-hev-socks5-tunnel-freebsd-x86_64}"
CACHED_BIN_FILE="$CACHE_DIR/hev-socks5-tunnel"

TMP_DIR="$(mktemp -d /tmp/hev-download.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_PATH="$TMP_DIR/${HEV_ASSET:-hev-socks5-tunnel-freebsd-x86_64}"
BINARY_PATH="$TMP_DIR/hev-socks5-tunnel"

# 1. 下载或复用 work/cache/ 资产（如缺失则下载）
if [ -f "$CACHED_ASSET_FILE" ]; then
    echo "==> Found existing cached asset: $CACHED_ASSET_FILE"
    CACHED_HASH="$(calculate_sha256 "$CACHED_ASSET_FILE")"
    if [ "$CACHED_HASH" = "$HEV_SHA256" ]; then
        echo "==> Cached asset SHA256 matches pinned hash ($CACHED_HASH)"
        cp -f "$CACHED_ASSET_FILE" "$ARCHIVE_PATH"
    else
        echo "==> Cached asset hash mismatch ($CACHED_HASH != $HEV_SHA256), re-downloading..."
        rm -f "$CACHED_ASSET_FILE"
    fi
fi

if [ ! -f "$ARCHIVE_PATH" ]; then
    echo "==> Downloading official hev-socks5-tunnel release: $HEV_URL"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 --connect-timeout 30 -o "$ARCHIVE_PATH" "$HEV_URL"
    elif command -v fetch >/dev/null 2>&1; then
        fetch -T 30 -o "$ARCHIVE_PATH" "$HEV_URL"
    else
        die "curl or fetch command not found"
    fi

    echo "==> Verifying downloaded asset SHA256"
    ACTUAL_ARCHIVE_SHA256="$(calculate_sha256 "$ARCHIVE_PATH")"
    if [ "$ACTUAL_ARCHIVE_SHA256" != "$HEV_SHA256" ]; then
        die "SHA256 mismatch! Expected: $HEV_SHA256, Got: $ACTUAL_ARCHIVE_SHA256"
    fi
    echo "==> Asset SHA256 verified: $ACTUAL_ARCHIVE_SHA256"
    cp -f "$ARCHIVE_PATH" "$CACHED_ASSET_FILE"
fi

# 2. 解包/准备二进制
echo "==> Unpacking / preparing binary"
if gzip -t "$ARCHIVE_PATH" >/dev/null 2>&1; then
    gzip -dc "$ARCHIVE_PATH" > "$BINARY_PATH"
elif xz -t "$ARCHIVE_PATH" >/dev/null 2>&1; then
    xz -dc "$ARCHIVE_PATH" > "$BINARY_PATH"
elif tar -tf "$ARCHIVE_PATH" >/dev/null 2>&1; then
    tar -xf "$ARCHIVE_PATH" -C "$TMP_DIR"
    if [ -f "$TMP_DIR/hev-socks5-tunnel" ]; then
        :
    elif [ -f "$TMP_DIR/bin/hev-socks5-tunnel" ]; then
        mv "$TMP_DIR/bin/hev-socks5-tunnel" "$BINARY_PATH"
    fi
else
    cp -f "$ARCHIVE_PATH" "$BINARY_PATH"
fi

chmod 0755 "$BINARY_PATH"
[ -s "$BINARY_PATH" ] || die "prepared binary is empty"

ACTUAL_BIN_SHA256="$(calculate_sha256 "$BINARY_PATH")"
echo "==> Prepared binary SHA256: $ACTUAL_BIN_SHA256"

if [ -n "${HEV_UNPACKED_SHA256:-}" ]; then
    if [ "$ACTUAL_BIN_SHA256" != "$HEV_UNPACKED_SHA256" ]; then
        die "Unpacked binary SHA256 mismatch! Expected: $HEV_UNPACKED_SHA256, Got: $ACTUAL_BIN_SHA256"
    fi
fi

# 3. 架构核验 (FreeBSD 64-bit ELF)
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

# 4. 存入 work/cache/
cp -f "$BINARY_PATH" "$CACHED_BIN_FILE"
chmod 0755 "$CACHED_BIN_FILE"

# 5. 压缩并落位至 src/os-mihomo/src/usr/local/bin/hev-socks5-tunnel.xz
DEST_DIR="$ROOT_DIR/src/os-mihomo/src/usr/local/bin"
mkdir -p "$DEST_DIR"
xz -c "$BINARY_PATH" > "$DEST_DIR/hev-socks5-tunnel.xz"
chmod 0644 "$DEST_DIR/hev-socks5-tunnel.xz"
[ -s "$DEST_DIR/hev-socks5-tunnel.xz" ] || die "generated hev-socks5-tunnel.xz is empty"

echo "==> Official hev-socks5-tunnel ready in cache: $CACHED_BIN_FILE"
echo "==> Compressed binary placed at: $DEST_DIR/hev-socks5-tunnel.xz"
echo "============================================================"
