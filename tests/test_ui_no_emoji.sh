#!/bin/sh
set -eu

# test_ui_no_emoji.sh - 插件自有界面文案零 emoji 门禁
# 只扫描插件自己的视图/表单/菜单/ACL；订阅数据（组名/节点名）不在扫描范围。

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app"

echo "===> Running UI no-emoji audit..."

python3 - "$APP_DIR" <<'PYEOF'
import os
import re
import sys

app_dir = sys.argv[1]
targets = []
for base, dirs, files in os.walk(app_dir):
    for name in files:
        path = os.path.join(base, name)
        if path.endswith('.volt') and '/views/OPNsense/Mihomo/' in path:
            targets.append(path)
        elif '/controllers/OPNsense/Mihomo/forms/' in path and name.endswith('.xml'):
            targets.append(path)
        elif '/models/OPNsense/Mihomo/' in path and name in ('Menu.xml', 'ACL.xml'):
            targets.append(path)

if not targets:
    print('FAIL: no UI files found', file=sys.stderr)
    sys.exit(1)

# 非 BMP emoji + 常见 BMP 符号（避免把中文/技术箭头误判）
emoji_re = re.compile(
    r'[\U0001F000-\U0001FAFF\u2600-\u27BF\u2B00-\u2BFF\uFE0F]'
)

hits = []
for path in sorted(targets):
    with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
        for line_no, line in enumerate(fh, 1):
            if emoji_re.search(line):
                rel = os.path.relpath(path, os.path.dirname(os.path.dirname(app_dir)))
                hits.append(f'{rel}:{line_no}')

if hits:
    print('FAIL: plugin-authored UI contains emoji:', file=sys.stderr)
    for hit in hits:
        print('  ' + hit, file=sys.stderr)
    sys.exit(1)

print('  [PASS] plugin-authored UI has zero emoji')
PYEOF

echo "===> UI no-emoji audit PASSED"
