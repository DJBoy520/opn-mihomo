#!/bin/sh
set -eu

echo "===> Running syntax and lint checks..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

# 1. Shell scripts syntax check (sh -n)
echo "--> Testing Shell script syntax..."
for sh_file in \
    "$ROOT_DIR"/scripts/*.sh \
    "$ROOT_DIR"/src/os-mihomo/*.sh \
    "$ROOT_DIR"/src/os-mihomo/packaging/freebsd/+* \
    "$ROOT_DIR"/src/os-mihomo/src/usr/local/etc/rc.d/* \
    "$ROOT_DIR"/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/*.sh \
    "$ROOT_DIR"/src/os-mihomo/src/usr/local/etc/mihomo/sub/*.sh \
    "$ROOT_DIR"/src/os-mihomo/src/usr/bin/*; do
    case "$(basename "$sh_file")" in
        +MANIFEST.in|pkg-descr) continue ;;
    esac
    # Check using bash if starts with bash, else sh
    if head -n 1 "$sh_file" | grep -q 'bash'; then
        bash -n "$sh_file" || { echo "FAIL: Bash syntax error in $sh_file"; exit 1; }
    else
        sh -n "$sh_file" || { echo "FAIL: Shell syntax error in $sh_file"; exit 1; }
    fi
    echo "  [PASS] Shell: $(basename "$sh_file")"
done

# 2. XML files validation
echo "--> Testing XML files validity..."
python3 -c "
import glob, sys, xml.etree.ElementTree as ET
files = glob.glob('$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/**/*.xml', recursive=True)
for f in files:
    try:
        ET.parse(f)
        print('  [PASS] XML:', f.split('/')[-1])
    except Exception as e:
        print('  [FAIL] XML error in', f, ':', e)
        sys.exit(1)
"

# 3. PHP syntax check (if php available) or token/tag check
echo "--> Testing PHP basic structure..."
python3 -c "
import glob, sys
files = glob.glob('$ROOT_DIR/src/os-mihomo/**/*.php', recursive=True)
for f in files:
    content = open(f, 'r', encoding='utf-8').read()
    if '<?php' not in content:
        print('  [FAIL] Missing <?php tag in', f)
        sys.exit(1)
    print('  [PASS] PHP:', f.split('/')[-1])
"

echo "===> All syntax and lint checks PASSED!"
