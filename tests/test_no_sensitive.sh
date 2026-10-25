#!/bin/sh
set -eu

# test_no_sensitive.sh - 敏感信息与交接痕迹工作区门禁
# 依赖 scripts/audit-sensitive.sh 并在外层追加敏感模式与文档断言

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

echo "===> Running sensitive information audit..."

# 1. 路径级断言：仓库内绝对禁止存在 docs/HANDOFF-*.md 文件
echo "--> Test 1: asserting no docs/HANDOFF-*.md files exist..."
handoff_files=$(find "$ROOT_DIR/docs" -maxdepth 1 -name 'HANDOFF-*.md' 2>/dev/null || true)
if [ -n "$handoff_files" ]; then
    fail "found internal handoff files in repository: $handoff_files"
fi
echo "  [PASS] no docs/HANDOFF-*.md files found."

# 2. 扩展敏感模式扫描
# 真实敏感模式从 .private/sensitive-patterns.txt（gitignored，绝不入库）读取；
# 缺省时仅启用不含真实值的通用模式（OPNsense 默认口令等）。
# 白名单：192.168.1.x / 192.168.0.0 / 192.168.10.0 / 192.168.50.x / 192.168.101.x / 127.x / 88.88.88.88（通用示例段）
echo "--> Test 2: checking extended sensitive patterns in tracked files..."
python3 - "$ROOT_DIR" << 'PYEOF'
import sys
import os
import re
import subprocess

root_dir = sys.argv[1]
os.chdir(root_dir)

try:
    out = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        stderr=subprocess.PIPE
    ).decode("utf-8")
    files = out.splitlines()
except Exception as e:
    sys.stderr.write(f"git ls-files failed: {e}\n")
    sys.exit(2)

def is_binary(path):
    try:
        with open(path, "rb") as f:
            return b"\0" in f.read(1024)
    except Exception:
        return True

# 通用敏感正则（不含任何真实值，可入库）
blocked_patterns = [
    (re.compile(r"\broot/opnsense\b", re.IGNORECASE), "sensitive-default-creds-root/opnsense"),
]

# 真实模式从 gitignored 的 .private/sensitive-patterns.txt 加载
patterns_file = os.path.join(root_dir, ".private", "sensitive-patterns.txt")
if os.path.isfile(patterns_file):
    with open(patterns_file, "r", encoding="utf-8") as pf:
        for raw in pf:
            raw = raw.strip()
            if not raw or raw.startswith("#"):
                continue
            blocked_patterns.append((re.compile(raw, re.IGNORECASE), "private-pattern"))
else:
    print("  [WARN] .private/sensitive-patterns.txt not found; only generic patterns active.")

# 排除检查本门禁自身和 audit-sensitive.sh（包含模式字面量）
self_scripts = {"tests/test_no_sensitive.sh", "scripts/audit-sensitive.sh"}

hits = []
for relpath in files:
    if relpath in self_scripts:
        continue
    if not os.path.isfile(relpath) or is_binary(relpath):
        continue

    try:
        with open(relpath, "r", encoding="utf-8", errors="ignore") as f:
            for line_no, line in enumerate(f, 1):
                for regex, label in blocked_patterns:
                    if regex.search(line):
                        hits.append(f"{relpath}:{line_no}: [{label}] 发现敏感信息泄露模式")
    except Exception as e:
        pass

if hits:
    sys.stderr.write(f"=== 敏感模式检测失败: 发现 {len(hits)} 处匹配 ===\n")
    for hit in hits:
        sys.stderr.write(hit + "\n")
    sys.exit(1)

print("  [PASS] extended sensitive patterns scan clean.")
PYEOF

# 3. 运行通用 scripts/audit-sensitive.sh
echo "--> Test 3: running scripts/audit-sensitive.sh..."
if [ "$#" -gt 0 ]; then
    sh "$ROOT_DIR/scripts/audit-sensitive.sh" "$1"
else
    sh "$ROOT_DIR/scripts/audit-sensitive.sh"
fi

echo "===> Sensitive information audit PASSED"
