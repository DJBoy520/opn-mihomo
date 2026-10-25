#!/bin/sh
set -eu

# export-public.sh - 生成开源导出目录并执行敏感信息扫描
# 输出：dist/public/（默认被 .gitignore 忽略）
# 排除：内部交接文档、工作日志、构建产物/二进制、work/、.private/、dist/

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/dist/public}"

cd "$ROOT_DIR"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "===> Exporting tracked files to $OUT_DIR"
git ls-files --cached --others --exclude-standard | while IFS= read -r file; do
    case "$file" in
        docs/HANDOFF-*|progress.md|work/*|output/*|repo/*|.private/*|dist/*)
            continue
            ;;
    esac
    [ -f "$file" ] || continue
    mkdir -p "$OUT_DIR/$(dirname "$file")"
    cp -p "$file" "$OUT_DIR/$file"
done

echo "===> Scanning exported tree for sensitive information"
sh "$ROOT_DIR/scripts/audit-sensitive.sh" "$OUT_DIR"

echo "===> Public export ready: $OUT_DIR"
