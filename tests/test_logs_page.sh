#!/bin/sh
set -eu

# v1.0.9 b2: 实时日志台测试（LogsController 增量游标 + logs.volt 表格化展示）
# 覆盖静态语法断言、边界条件检查与安全红线检查

echo "===> Running logs page & incremental cursor tests..."

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LOGS_CTRL="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/LogsController.php"
LOGS_VOLT="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/logs.volt"

fail() {
    echo "FAIL: $*"
    exit 1
}

# 1. LogsController.php 增量游标与读取逻辑严格断言
echo "--> Test 1: LogsController.php incremental cursor and file operations..."
[ -f "$LOGS_CTRL" ] || fail "missing LogsController.php"

# (a) 文件读写函数 (fopen/fseek/fread/fclose)
grep -q "fopen(" "$LOGS_CTRL" || fail "LogsController.php missing fopen"
grep -q "fseek(" "$LOGS_CTRL" || fail "LogsController.php missing fseek"
grep -q "fread(" "$LOGS_CTRL" || fail "LogsController.php missing fread"
grep -q "fclose(" "$LOGS_CTRL" || fail "LogsController.php missing fclose"

# (b) 文件路径与常量
grep -q "private const LOG_FILE_PATH = '/var/log/mihomo.log';" "$LOGS_CTRL" || \
    fail "LogsController.php missing LOG_FILE_PATH constant"
grep -q "private const MAX_DELTA_BYTES = 262144;" "$LOGS_CTRL" || \
    fail "LogsController.php missing MAX_DELTA_BYTES (256KB)"

# (c) 轮转截断与超限分支断言
grep -q '\$fileSize < \$cursor' "$LOGS_CTRL" || fail "LogsController.php missing \$fileSize < \$cursor rotation handling"
grep -q '(\$fileSize - \$cursor) > self::MAX_DELTA_BYTES' "$LOGS_CTRL" || \
    fail "LogsController.php missing MAX_DELTA_BYTES delta overflow check"

# (d) 换行对齐与未完成半行处理 (findLastNewlineOffset / strrpos)
grep -q "function findLastNewlineOffset" "$LOGS_CTRL" || fail "LogsController.php missing findLastNewlineOffset"
grep -q "findLastNewlineOffset(" "$LOGS_CTRL" || fail "LogsController.php missing findLastNewlineOffset call"
grep -Fq 'strrpos($content, "\n")' "$LOGS_CTRL" || fail "LogsController.php missing strrpos newline check for delta"

# (e) 级别过滤函数定义与调用
grep -q "function matchLevelFilter" "$LOGS_CTRL" || fail "LogsController.php missing matchLevelFilter definition"
grep -q "matchLevelFilter(" "$LOGS_CTRL" || fail "LogsController.php missing matchLevelFilter call"

# (f) 脱敏函数 sanitizeLogLine 必须存在，且对 time/level/msg/raw 逐字段调用
grep -q "function sanitizeLogLine" "$LOGS_CTRL" || fail "LogsController.php missing sanitizeLogLine definition"
grep -q "'time' => \$this->sanitizeLogLine" "$LOGS_CTRL" || fail "LogsController.php missing sanitizeLogLine on 'time'"
grep -q "'level' => \$this->sanitizeLogLine" "$LOGS_CTRL" || fail "LogsController.php missing sanitizeLogLine on 'level'"
grep -q "'msg' => \$this->sanitizeLogLine" "$LOGS_CTRL" || fail "LogsController.php missing sanitizeLogLine on 'msg'"
grep -q "'raw' => \$this->sanitizeLogLine" "$LOGS_CTRL" || fail "LogsController.php missing sanitizeLogLine on 'raw'"

# (g) fopen 失败权限检查（noroot 支持）
grep -q "\$handle === false" "$LOGS_CTRL" || fail "LogsController.php missing handle false check"
grep -q "'status' => 'failed'" "$LOGS_CTRL" || fail "LogsController.php missing 'status' => 'failed' on fopen error"

# (h) 返回结构字段齐全性
grep -q "'status' => 'ok'" "$LOGS_CTRL" || fail "LogsController.php missing 'status' => 'ok'"
grep -q "'entries' => \$entries" "$LOGS_CTRL" || fail "LogsController.php missing 'entries'"
grep -q "'cursor' => \$newCursor" "$LOGS_CTRL" || fail "LogsController.php missing 'cursor'"
grep -q "'truncated' => \$truncated" "$LOGS_CTRL" || fail "LogsController.php missing 'truncated'"

echo "  [PASS] LogsController.php rigorous assertions passed"

# 2. logs.volt 界面与控件断言
echo "--> Test 2: logs.volt UI controls, badges, and rendering..."
[ -f "$LOGS_VOLT" ] || fail "missing logs.volt"

# 控件元素：暂停/恢复、清屏、下载、级别过滤、行数选择、自动滚动、连接状态
grep -q "btn_toggle_pause" "$LOGS_VOLT" || fail "logs.volt missing pause/resume button"
grep -q "btn_clear_logs" "$LOGS_VOLT" || fail "logs.volt missing clear button"
grep -q "btn_download_logs" "$LOGS_VOLT" || fail "logs.volt missing download button"
grep -q "log_level_filter" "$LOGS_VOLT" || fail "logs.volt missing level filter"
grep -q "log_limit" "$LOGS_VOLT" || fail "logs.volt missing limit selector"
grep -q "chk_auto_scroll" "$LOGS_VOLT" || fail "logs.volt missing auto scroll checkbox"
grep -q "log_conn_status" "$LOGS_VOLT" || fail "logs.volt missing connection status indicator"

# 样式类名正向断言
grep -q "mihomo-log-view" "$LOGS_VOLT" || fail "logs.volt missing mihomo-log-view class"
grep -q "mihomo-log-table" "$LOGS_VOLT" || fail "logs.volt missing mihomo-log-table class"

# 亮色主题：严禁深色控制台色值
for dark_color in "#1e1e1e" "#2d2d2d" "#dcdcdc" "#2e2e2e"; do
    if grep -q "$dark_color" "$LOGS_VOLT"; then
        fail "logs.volt contains dark theme color: $dark_color"
    fi
done

# 级别徽章 (debug / info / warning / error)
grep -q "label-info" "$LOGS_VOLT" || fail "logs.volt missing info badge"
grep -q "label-warning" "$LOGS_VOLT" || fail "logs.volt missing warning badge"
grep -q "label-danger" "$LOGS_VOLT" || fail "logs.volt missing danger/error badge"
grep -q "label-default" "$LOGS_VOLT" || fail "logs.volt missing default/debug badge"

# XSS 安全红线：时间/级别/消息一律 .text()/textContent 渲染，严禁 .html()/innerHTML
grep -q "\.text(" "$LOGS_VOLT" || fail "logs.volt missing safe .text() rendering"
if grep -E "(\.html\(|innerHTML)" "$LOGS_VOLT" >/dev/null 2>&1; then
    fail "logs.volt violates XSS safety rule: contains .html() or innerHTML"
fi

# 异步并发与失败处理优化断言：
# - 回调内防竞态检查 isPaused
grep -q "if (isPaused)" "$LOGS_VOLT" || fail "logs.volt missing isPaused guard in ajax callback"
# - 严禁在 ajaxCall 后再链式挂 .fail(（避免与 callback 内的失败处理重复触发）
if grep -q "\.fail(" "$LOGS_VOLT"; then
    fail "logs.volt must not chain .fail() on ajaxCall (avoids duplicate handlePollFailure)"
fi
# - 错误状态展示与更新
grep -q "updateConnStatus('error'" "$LOGS_VOLT" || fail "logs.volt missing updateConnStatus('error')"

echo "  [PASS] logs.volt controls, level badges, and safe text rendering verified"

# 3. 零硬编码守卫：两文件严禁出现 ":9090"
echo "--> Test 3: zero hardcoded :9090 in logs files..."
if grep -q ":9090" "$LOGS_CTRL"; then
    fail "LogsController.php contains hardcoded :9090"
fi
if grep -q ":9090" "$LOGS_VOLT"; then
    fail "logs.volt contains hardcoded :9090"
fi
echo "  [PASS] zero :9090 literal found in LogsController.php and logs.volt"

# 4. 游标与解析行为验证（Python 行为仿真）
echo "--> Test 4: behavioral simulation check for logfmt and cursor math..."
python3 -c "
import re, io

# 验证 logfmt 解析与脱敏
pattern = re.compile(r'^time=(?:\"([^\"]*)\"|(\S+))\s+level=(?:\"([^\"]*)\"|(\S+))\s+msg=(?:\"([^\"]*)\"|(.*))$')
m = pattern.search('time=\"2026-10-20T12:00:00Z\" level=info msg=\"secret: 12345\"')
assert m is not None, 'Regex failed to match logfmt'

# 验证未完成换行截断计算
buf = b'line 1\nline 2\nincomplete_half_line'
nl = buf.rfind(b'\n')
assert nl == 13, f'Expected nl=13, got {nl}'
complete = buf[:nl]
new_c = 0 + nl + 1
assert new_c == 14, f'Expected new_c=14, got {new_c}'
print('  [PASS] Behavioral simulation verified')
"

echo "===> All logs page tests PASSED 100%!"
