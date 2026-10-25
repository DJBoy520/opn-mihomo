#!/bin/sh
# scripts/audit-sensitive.sh
# 敏感信息审计脚本（只读扫描，命中文档:行号，不打印具体命中值，非 0 退出）
#
# 规则：
# 1. .private/sensitive-patterns.txt（若存在且非空）里的自定义模式叠加到通用检查之上，
#    绝不替代通用规则
# 2. 通用检查：
#    - 个人主目录绝对路径（/home/<user>）
#    - OPNsense 默认账号口令（root/opnsense 等）
#    - 个人邮箱（公共邮箱域不整域放行）
#    - 真实私网 IPv4（逐 IP 判定字面示例 allowlist）
# 3. 命中输出: "文件:行号: [规则类型] 命中敏感信息"，不打印命中值，退出非 0
# 4. 脚本尾部自检合成泄露样例，规则回归时自检失败退出 1

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

PATTERN_FILE="$ROOT_DIR/.private/sensitive-patterns.txt"

# 检查 python3 是否存在，优先用 Python 提供快速、精准、防越界的多行/正则处理
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 required for audit-sensitive.sh" >&2
    exit 2
fi

exec python3 - "$ROOT_DIR" "$PATTERN_FILE" "$@" << 'PYEOF'
import sys
import os
import re
import subprocess

root_dir = sys.argv[1]
pattern_file = sys.argv[2]
cli_target_dir = sys.argv[3] if len(sys.argv) > 3 else None

os.chdir(root_dir)

# 确定扫描文件列表
if cli_target_dir and os.path.exists(cli_target_dir):
    # 如果指定了目标目录（如 dist/public），扫描该目录下所有普通文本文件
    tracked_files = []
    for base, dirs, files in os.walk(cli_target_dir):
        # 排除常见忽略目录
        dirs[:] = [d for d in dirs if d not in {".git", ".private", "work", "output", "repo"}]
        for f in files:
            p = os.path.relpath(os.path.join(base, f), root_dir)
            tracked_files.append(p)
else:
    # 扫描 git tracked 文件
    try:
        out = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], stderr=subprocess.PIPE).decode("utf-8")
        tracked_files = out.splitlines()
    except Exception as e:
        sys.stderr.write(f"Failed to get git ls-files: {e}\n")
        sys.exit(2)

# 二进制文件判定
def is_binary(filepath):
    try:
        with open(filepath, "rb") as f:
            chunk = f.read(1024)
            return b"\0" in chunk
    except Exception:
        return True

# 检查是否存在 .private/sensitive-patterns.txt
custom_patterns = []
if os.path.isfile(pattern_file) and os.path.getsize(pattern_file) > 0:
    try:
        with open(pattern_file, "r", encoding="utf-8") as pf:
            for line in pf:
                line = line.strip()
                if line and not line.startswith("#"):
                    custom_patterns.append(line)
    except Exception as e:
        sys.stderr.write(f"Warning: could not read {pattern_file}: {e}\n")

hits = []

# 通用规则（始终执行；自定义 patterns 只是叠加，不替代通用检查）
# 规则 1: 个人家目录路径
re_home = re.compile(r"/home/[a-zA-Z0-9_-]+", re.IGNORECASE)

# 规则 2: OPNsense 默认账号口令组合
re_cred = re.compile(r"\b(root/opnsense|root:opnsense)\b", re.IGNORECASE)

# 规则 4: 邮箱地址 (排除上游开源许可证通用版权邮箱、文档样例 example.com / @opnsense.org)
re_email = re.compile(r"\b([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})\b")

# 规则 5: 私网 IPv4 地址
re_ipv4 = re.compile(r"\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3})\b")

# 允许的示例 IP 与技术规范 CIDR (白名单)
allowed_ip_substrings = [
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
    "10.0.0.1", "10.0.0.2", "10.0.0.2/30",
    "172.19.0.1/30", "172.19.0.1",
    "192.168.1.0/24", "192.168.1.1", "192.168.1.7", "192.168.1.10", "192.168.1.10:12345", "192.168.1.10:9095",
    "192.168.10.0/24", "192.168.101.0/24", "10.125.0.1/24", "10.125.0.1",
    "192.168.50.2", "192.168.50.255", "10.9.9.9", "10.9.9.90", "10.20.30.40"
]
# 白名单按字面示例逐 IP 精确判定：CIDR/端口写法只用于文档展示，绝不整网段放行，
# 否则同一行任意一个白名单示例都会掩护同行的真实地址。
allowed_ip_literals = {token.split(":")[0].split("/")[0] for token in allowed_ip_substrings}

# 允许的邮箱白名单 (上游开源软件的原作者、开源组织、测试样例)
# 公共邮箱域（gmail.com 等）不得整域放行；上游版权头里的具体作者地址单独精确豁免。
allowed_email_domains = [
    "opnsense.org", "glockners.net", "cekal.org", "lshell.com",
    "frenking.eu", "der-ingo.de", "bluemedia.dev", "neon1.net", "max-it.de",
    "li.org", "example.com", "example.org", "example.net"
]
allowed_emails = {"ilumos@gmail.com", "sullrich@gmail.com"}

def ip_allowed(ip):
    return ip in allowed_ip_literals

def email_allowed(em):
    if em.lower() in allowed_emails:
        return True
    return em.split("@")[-1].lower() in allowed_email_domains

def general_tags(line):
    tags = []
    if re_home.search(line):
        tags.append("user-home")
    if re_cred.search(line):
        tags.append("default-credentials")
    if any(not email_allowed(em) for em in re_email.findall(line)):
        tags.append("personal-email")
    if any(not ip_allowed(ip) for ip in re_ipv4.findall(line)):
        tags.append("private-ipv4")
    return tags

TAG_MESSAGES = {
    "user-home": "命中个人绝对路径模式",
    "default-credentials": "命中默认账号口令模式",
    "personal-email": "命中未登记域名的个人邮箱",
    "private-ipv4": "命中未列入白名单的私网 IPv4 地址",
}

# 按照自定义模式逐条扫描（叠加在通用规则之上）
compiled = []
for pat in custom_patterns:
    try:
        compiled.append((pat, re.compile(pat, re.IGNORECASE)))
    except Exception:
        compiled.append((pat, re.compile(re.escape(pat), re.IGNORECASE)))

# 内部文件豁免（公开发布目录与新仓库中不得有内部交接文档豁免）
# audit-sensitive.sh 与 test_no_sensitive.sh 自身包含模式字面量，予以排除
exempt_internal = {"scripts/audit-sensitive.sh", "tests/test_no_sensitive.sh"} if not cli_target_dir else set()

for relpath in tracked_files:
    if relpath in exempt_internal:
        continue
    if os.path.basename(relpath) == "audit-sensitive.sh":
        continue
    if not os.path.isfile(relpath) or is_binary(relpath):
        continue

    try:
        with open(relpath, "r", encoding="utf-8", errors="ignore") as f:
            for line_idx, line in enumerate(f, 1):
                for tag in general_tags(line):
                    hits.append(f"{relpath}:{line_idx}: [{tag}] {TAG_MESSAGES[tag]}")
                for pat_str, reg in compiled:
                    if reg.search(line):
                        hits.append(f"{relpath}:{line_idx}: [custom-pattern] 命中匹配规则")
                        break
    except Exception:
        pass

# ---- 自检：合成泄露样例必须被通用规则标记 ----
# 回归防线：白名单曾是整行放行（同行任意白名单串即掩护所有 IP），
# 公共邮箱域也曾整域放行；任一回归都必须让审计自身失败。
selfcheck_cases = [
    ("白名单行内夹杂非白名单 IP", "示例 10.0.0.1 与 10.99.7.7", "private-ipv4"),
    ("个人 gmail 邮箱", "联系 someone.personal@gmail.com", "personal-email"),
]
selfcheck_failed = False
for _name, _sample, _tag in selfcheck_cases:
    if _tag not in general_tags(_sample):
        sys.stderr.write(f"ERROR: audit self-check failed: {_name} 未被标记\n")
        selfcheck_failed = True
if selfcheck_failed:
    sys.stderr.write("=== 敏感信息扫描失败: 审计规则自检未通过 ===\n")
    sys.exit(1)

if hits:
    print(f"=== 敏感信息扫描失败: 发现 {len(hits)} 处可能泄露 ===", file=sys.stderr)
    for h in hits:
        print(h, file=sys.stderr)
    sys.exit(1)
else:
    print("=== 敏感信息扫描通过: 未发现敏感泄露 ===")
    sys.exit(0)
PYEOF
