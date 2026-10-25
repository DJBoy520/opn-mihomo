#!/bin/sh
# 自定义规则应用与配置重合成引擎
# 用于根据订阅缓存与 custom-rules.txt 重新合成并原子更新配置
set -eu

# 1. 引入订阅合成公共函数库
SUB_LIB="${MIHOMO_SUB_LIB:-/usr/local/etc/mihomo/sub/sub_lib.sh}"
if [ ! -f "$SUB_LIB" ]; then
    echo "错误：未找到订阅公共函数库 $SUB_LIB" >&2
    exit 4
fi
. "$SUB_LIB"

# 2. 常量与环境变量配置
RULES_FILE="${MIHOMO_RULES_FILE:-/usr/local/etc/mihomo/custom-rules.txt}"
CACHE="${MIHOMO_CACHE_FILE:-/var/db/os-mihomo/subscription-cache.yaml}"
BIN="${MIHOMO_BIN:-/usr/local/bin/mihomo}"
CONF_DIR="${MIHOMO_CONF_DIR:-/usr/local/etc/mihomo}"
ATOMIC_UPDATER="${MIHOMO_ATOMIC_UPDATER:-/usr/local/opnsense/scripts/OPNsense/Mihomo/atomic_config_updater.sh}"

# 3. 命令行参数处理
ACTION="${1:-}"
case "$ACTION" in
    apply|recompose)
        ;;
    *)
        echo "用法: $0 {apply|recompose}" >&2
        exit 1
        ;;
esac

# 临时文件清理与锁释放状态
TMP_FINAL=""
TMP_STDERR=""
LOCK_ACQUIRED=0

cleanup() {
    [ -n "$TMP_FINAL" ] && rm -f "$TMP_FINAL"
    [ -n "$TMP_STDERR" ] && rm -f "$TMP_STDERR"
    if [ "$LOCK_ACQUIRED" = "1" ]; then
        mihomo_lib_lock_release 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# 4. 获取互斥锁
if ! mihomo_lib_lock_acquire; then
    echo "错误：获取锁失败（订阅或规则任务正在执行），请勿重复运行。" >&2
    exit 9
fi
LOCK_ACQUIRED=1

# 5. 检查订阅缓存是否存在且非空
if [ ! -s "$CACHE" ]; then
    echo "错误：订阅缓存不存在或为空（需先执行一次订阅更新）。" >&2
    exit 3
fi

# 6. 创建临时文件并调用函数库合成完整配置
TMP_FINAL="$(mktemp /tmp/mihomo_recompose.XXXXXX 2>/dev/null || mktemp)"
if [ -z "$TMP_FINAL" ] || [ ! -f "$TMP_FINAL" ]; then
    echo "错误：创建临时文件失败。" >&2
    exit 1
fi

if ! mihomo_lib_compose "$CACHE" "$TMP_FINAL"; then
    echo "错误：配置合成失败。" >&2
    exit 1
fi

# 7. 配置预检 (mihomo -t)
TMP_STDERR="$(mktemp /tmp/mihomo_check_err.XXXXXX 2>/dev/null || mktemp)"
if [ -z "$TMP_STDERR" ] || [ ! -f "$TMP_STDERR" ]; then
    echo "错误：创建预检输出临时文件失败。" >&2
    exit 1
fi

if ! "$BIN" -t -d "$CONF_DIR" -f "$TMP_FINAL" >/dev/null 2>"$TMP_STDERR"; then
    echo "错误：Mihomo 配置预检失败，生产配置保持不变。" >&2
    
    if [ "$ACTION" = "apply" ]; then
        # 从 stderr 中提取形如 line N 的行号
        LINE_NUM="$(sed -n -E 's/.*line[[:space:]]+([0-9]+).*/\1/p' "$TMP_STDERR" | head -n 1)"
        case "$LINE_NUM" in
            ''|*[!0-9]*)
                LINE_NUM=""
                ;;
        esac

        if [ -n "$LINE_NUM" ]; then
            # 获取合成文件中 rules: 顶层段的起始行 R
            RULES_START="$(grep -n '^rules:' "$TMP_FINAL" | cut -d: -f1 | head -n 1 || true)"
            case "$RULES_START" in
                ''|*[!0-9]*)
                    RULES_START=""
                    ;;
            esac

            if [ -n "$RULES_START" ] && [ "$LINE_NUM" -gt "$RULES_START" ]; then
                # 占位符在 rules: 的下一行，因此注入的第 1 行自定义规则位于 R + 1
                # 错误行号 N>R 时，自定义规则序号约为 N - R - 1
                RULE_OFFSET=$((LINE_NUM - RULES_START - 1))
                if [ "$RULE_OFFSET" -le 0 ]; then
                    RULE_OFFSET=1
                fi
                echo "提示：错误行 $LINE_NUM 落在 rules: 段，对应 custom-rules.txt 第 $RULE_OFFSET 行附近" >&2
            fi
        fi
    fi
    
    echo "--- 预检错误详情 (最后 5 行) ---" >&2
    tail -n 5 "$TMP_STDERR" >&2
    exit 1
fi

# 8. 预检通过，执行原子替换与热重载
if [ ! -x "$ATOMIC_UPDATER" ]; then
    echo "错误：未找到原子配置更新脚本 $ATOMIC_UPDATER 或不可执行。" >&2
    exit 1
fi

if ! "$ATOMIC_UPDATER" "$TMP_FINAL" reload >/dev/null; then
    echo "错误：原子更新或配置重载失败。" >&2
    exit 1
fi

# 9. 成功输出并清理退出
if [ "$ACTION" = "apply" ]; then
    RULE_COUNT=0
    if [ -f "$RULES_FILE" ]; then
        RULE_COUNT="$(awk '/^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next } { c++ } END { print c+0 }' "$RULES_FILE" 2>/dev/null || echo 0)"
    fi
    echo "OK: config recomposed from cache (applied $RULE_COUNT custom rules)"
else
    echo "OK: config recomposed from cache"
fi

exit 0
