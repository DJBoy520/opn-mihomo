#!/bin/bash
set -euo pipefail

# Determine repository root
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/output"
WORK_DIR="$REPO_ROOT/work/verify-pkg"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

# Cross-platform SHA256 function: outputs raw hex digest of file
calc_sha256() {
    file_path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file_path" | awk '{print $1}'
    elif command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$file_path"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file_path" | awk '{print $1}'
    else
        die "No sha256 calculation tool available (sha256sum, sha256, or shasum required)"
    fi
}

[ -d "$OUTPUT_DIR" ] || die "Output directory not found: $OUTPUT_DIR"
[ -f "$OUTPUT_DIR/SHA256SUMS" ] || die "SHA256SUMS not found in $OUTPUT_DIR"
[ -f "$OUTPUT_DIR/build-info.json" ] || die "build-info.json not found in $OUTPUT_DIR"

# 校验范围以 SHA256SUMS 为准：它只列本次构建产物，output/ 可能残留历史包。
# 未登记的历史包仅提示不阻断（它们不属于本次发布内容）。
PKG_FILES=()
while IFS= read -r _sum_line || [ -n "$_sum_line" ]; do
    case "$_sum_line" in
        ''|'#'*) continue ;;
    esac
    _sum_name="${_sum_line##* }"
    [ -n "$_sum_name" ] || continue
    PKG_FILES+=("$OUTPUT_DIR/$_sum_name")
done < "$OUTPUT_DIR/SHA256SUMS"
[ "${#PKG_FILES[@]}" -gt 0 ] || die "No package entries found in $OUTPUT_DIR/SHA256SUMS"

for _pkg in "${PKG_FILES[@]}"; do
    [ -f "$_pkg" ] || die "Package listed in SHA256SUMS is missing: $(basename "$_pkg")"
done

shopt -s nullglob
for _existing in "$OUTPUT_DIR"/*.pkg; do
    _listed=0
    for _pkg in "${PKG_FILES[@]}"; do
        if [ "$(basename "$_pkg")" = "$(basename "$_existing")" ]; then
            _listed=1
            break
        fi
    done
    [ "$_listed" -eq 1 ] || log "NOTE: skipping $(basename "$_existing") (not listed in SHA256SUMS; stale artifact)"
done
shopt -u nullglob

log "Found package(s): ${PKG_FILES[*]}"

# Clean & Prepare verify work dir
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

for PKG_PATH in "${PKG_FILES[@]}"; do
    PKG_FILENAME="$(basename "$PKG_PATH")"
    log "Verifying package: $PKG_FILENAME"

    # 1. Verify SHA256SUMS matching
    log "Step 1: Verifying SHA256SUMS entry for $PKG_FILENAME"
    ACTUAL_PKG_HASH="$(calc_sha256 "$PKG_PATH")"
    EXPECTED_PKG_HASH="$(awk -v pkg="$PKG_FILENAME" '$2 == pkg {print $1}' "$OUTPUT_DIR/SHA256SUMS")"
    [ -n "$EXPECTED_PKG_HASH" ] || die "No entry for $PKG_FILENAME in $OUTPUT_DIR/SHA256SUMS"
    [ "$ACTUAL_PKG_HASH" = "$EXPECTED_PKG_HASH" ] || die "SHA256 mismatch for $PKG_FILENAME (actual: $ACTUAL_PKG_HASH, expected: $EXPECTED_PKG_HASH)"
    log "SHA256 checksum matched: $ACTUAL_PKG_HASH"

    # 2. Extract .pkg to temp dir and verify manifests
    EXTRACT_DIR="$WORK_DIR/extracted"
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"

    log "Step 2: Extracting package contents..."
    tar -xzf "$PKG_PATH" -C "$EXTRACT_DIR"

    MANIFEST="$EXTRACT_DIR/+MANIFEST"
    COMPACT_MANIFEST="$EXTRACT_DIR/+COMPACT_MANIFEST"

    [ -f "$MANIFEST" ] || die "+MANIFEST missing in package"
    [ -s "$MANIFEST" ] || die "+MANIFEST is empty"
    [ -f "$COMPACT_MANIFEST" ] || die "+COMPACT_MANIFEST missing in package"
    [ -s "$COMPACT_MANIFEST" ] || die "+COMPACT_MANIFEST is empty"
    log "+MANIFEST and +COMPACT_MANIFEST exist and are non-empty"

    # 3. Check metadata declarations (name, version, abi, arch)
    log "Step 3: Checking metadata declarations in +MANIFEST"
    PKG_NAME="$(sed -n 's/^name:[[:space:]]*"\?\([^"]*\)"\?/\1/p' "$MANIFEST" | head -n1)"
    PKG_VERSION="$(sed -n 's/^version:[[:space:]]*"\?\([^"]*\)"\?/\1/p' "$MANIFEST" | head -n1)"
    PKG_ABI="$(sed -n 's/^abi:[[:space:]]*"\?\([^"]*\)"\?/\1/p' "$MANIFEST" | head -n1)"
    PKG_ARCH="$(sed -n 's/^arch:[[:space:]]*"\?\([^"]*\)"\?/\1/p' "$MANIFEST" | head -n1)"

    [ "$PKG_NAME" = "os-mihomo" ] || die "Unexpected package name in +MANIFEST: '$PKG_NAME' (expected: os-mihomo)"
    [ -n "$PKG_VERSION" ] || die "Version in +MANIFEST is empty"
    [ "$PKG_ABI" = "FreeBSD:*:amd64" ] || die "Unexpected ABI in +MANIFEST: '$PKG_ABI' (expected: FreeBSD:*:amd64)"
    [ "$PKG_ARCH" = "freebsd:*:x86:64" ] || die "Unexpected arch in +MANIFEST: '$PKG_ARCH' (expected: freebsd:*:x86:64)"
    log "Metadata confirmed: name=$PKG_NAME, version=$PKG_VERSION, abi=$PKG_ABI, arch=$PKG_ARCH"

    # 4. Check files list and sha256 checksums
    log "Step 4: Checking all files declared in +MANIFEST files section"
    FILES_SECTION="$(awk '/^files:[[:space:]]*\{/{flag=1; next} /^\}/{flag=0} flag' "$MANIFEST")"
    [ -n "$FILES_SECTION" ] || die "No files section found in +MANIFEST"

    CHECKED_FILES_COUNT=0
    while IFS= read -r line; do
        # Line format: "path": "1$checksum" or "/path": "1$checksum"
        # Example: "/usr/local/bin/mihomo": "1$abcd..."
        [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\":[[:space:]]*\"1\$([a-fA-F0-9]+)\" ]] || continue
        file_path="${BASH_REMATCH[1]}"
        expected_hash="${BASH_REMATCH[2]}"

        # Remove leading slash to find in EXTRACT_DIR
        rel_path="${file_path#/}"
        target_file="$EXTRACT_DIR/$rel_path"

        [ -f "$target_file" ] || die "File declared in +MANIFEST does not exist: $file_path (at $target_file)"
        actual_hash="$(calc_sha256 "$target_file")"
        [ "$actual_hash" = "$expected_hash" ] || die "File hash mismatch for $file_path (expected: $expected_hash, actual: $actual_hash)"

        CHECKED_FILES_COUNT=$((CHECKED_FILES_COUNT + 1))
    done <<< "$FILES_SECTION"

    [ "$CHECKED_FILES_COUNT" -gt 0 ] || die "No files were checked from +MANIFEST"
    log "Successfully verified SHA256 for all $CHECKED_FILES_COUNT files declared in +MANIFEST"

    # 5. Check usr/local/bin/mihomo binary and file ELF format
    log "Step 5: Verifying usr/local/bin/mihomo ELF binary format"
    MIHOMO_BIN="$EXTRACT_DIR/usr/local/bin/mihomo"
    [ -f "$MIHOMO_BIN" ] || die "usr/local/bin/mihomo not found in extracted package"
    [ -x "$MIHOMO_BIN" ] || die "usr/local/bin/mihomo is not executable"

    FILE_OUT="$(file "$MIHOMO_BIN")"
    log "Binary file info: $FILE_OUT"

    # Must be FreeBSD and 64-bit ELF (ELF 64-bit LSB executable, ... FreeBSD)
    if [[ "$FILE_OUT" != *"ELF 64-bit"* ]] || [[ "$FILE_OUT" != *"FreeBSD"* ]]; then
        die "Binary usr/local/bin/mihomo is not a FreeBSD 64-bit ELF executable: $FILE_OUT"
    fi
    log "Mihomo binary confirmed as FreeBSD 64-bit ELF"

    # 5b. Verify pre-install script, panel feature files, clean tree, and pf safety
    # 1.0.2 / 1.0.4 是面板化之前的遗留产物：以下断言只对 1.0.5+ 生效
    case "$PKG_VERSION" in
        1.0.2|1.0.4) ;;
        *)
    log "Step 5b: Verifying pre-install script, panel feature files, clean tree, and pf safety"
    grep -q '"pre-install"' "$MANIFEST" || die "scripts section in $MANIFEST does not contain pre-install"

    REQUIRED_PANEL_FILES=(
        "usr/local/etc/mihomo/pf-transport.conf"
        "usr/local/etc/mihomo/hev.yaml.sample"
        "usr/local/etc/mihomo/config.yaml.sample"
        "usr/local/etc/mihomo/sub/env.sample"
        "usr/local/etc/mihomo/sub/sub_lib.sh"
        "usr/local/etc/rc.d/mihomo_hev"
        "usr/local/opnsense/scripts/OPNsense/Mihomo/transport_manager.sh"
        "usr/local/opnsense/scripts/OPNsense/Mihomo/custom_rules_apply.sh"
        "usr/local/opnsense/scripts/OPNsense/Mihomo/custom_rules_validate.php"
        "usr/local/opnsense/scripts/OPNsense/Mihomo/subscription_env_writer.php"
        "usr/local/opnsense/scripts/OPNsense/Mihomo/transport_render.php"
        "usr/local/etc/mihomo/setup.sh"
        "usr/local/opnsense/scripts/OPNsense/Mihomo/mihomo_setup.php"
    )
    for pfile in "${REQUIRED_PANEL_FILES[@]}"; do
        [ -f "$EXTRACT_DIR/$pfile" ] || die "Required panel file missing in package: $pfile (at $EXTRACT_DIR/$pfile)"
    done

    PYCACHE_FOUND="$(find "$EXTRACT_DIR" -name __pycache__ -o -name '*.pyc')"
    [ -z "$PYCACHE_FOUND" ] || die "Package contains python cache files or directories: $PYCACHE_FOUND"

    PF_CONF="$EXTRACT_DIR/usr/local/etc/mihomo/pf-transport.conf"
    if grep -Eiq '^[[:space:]]*(block|reject)' "$PF_CONF"; then
        die "pf-transport.conf contains block or reject rules"
    fi
    log "Step 5b verified: pre-install declared, all panel files present, no pycache, safe pf rules"
        ;;
    esac
done

# 6. Verify build-info.json format and required fields
log "Step 6: Verifying build-info.json schema and required fields"
BUILD_INFO="$OUTPUT_DIR/build-info.json"

REQUIRED_FIELDS=(
    "plugin_version"
    "mihomo_version"
    "mihomo_commit"
    "mihomo_sha256"
    "target_os"
    "target_arch"
    "build_environment"
    "source_commit"
)

for field in "${REQUIRED_FIELDS[@]}"; do
    val="$(grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$BUILD_INFO" || true)"
    [ -n "$val" ] || die "Required field '$field' is missing or invalid in $BUILD_INFO"
done

# Validate json syntax using jq or python if available
if command -v jq >/dev/null 2>&1; then
    jq . "$BUILD_INFO" >/dev/null || die "$BUILD_INFO is not valid JSON"
elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$BUILD_INFO" >/dev/null || die "$BUILD_INFO is not valid JSON"
fi
log "build-info.json is valid"

echo "==> Package verification SUCCESS"
