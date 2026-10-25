#!/bin/sh
set -eu

# setup.sh - os-mihomo 一键配置与部署入口
#
# 两种一键用法：
#   1) MIHOMO_SETUP_URL='https://...' pkg add os-mihomo-1.0.5.pkg（装包即部署）
#   2) sh /usr/local/etc/mihomo/setup.sh 'https://...' transparent（装包后手动执行/改设置）
#
# 用法：
#   sh setup.sh <url> [transport] [interval]
# 环境变量覆盖：
#   MIHOMO_SETUP_URL / MIHOMO_SETUP_TRANSPORT / MIHOMO_SETUP_INTERVAL 可覆盖位置参数
# 缺省值：
#   transport=transparent、interval=o24h、auto_update=1

CONFIGCTL=/usr/local/sbin/configctl
SETUP_PHP=/usr/local/opnsense/scripts/OPNsense/Mihomo/mihomo_setup.php
STATUS=/var/db/os-mihomo/last-sub-update.json
PHP_BIN=/usr/local/bin/php
ANCHOR="mihomo-transport"
CONFIG_FILE=/usr/local/etc/mihomo/config.yaml
DEFAULT_API_HOST="127.0.0.1"
DEFAULT_API_PORT=9090

# 参数解析：环境变量优先，其次位置参数，最后缺省值
URL="${MIHOMO_SETUP_URL:-${1:-}}"
TRANSPORT="${MIHOMO_SETUP_TRANSPORT:-${2:-transparent}}"
INTERVAL="${MIHOMO_SETUP_INTERVAL:-${3:-o24h}}"
AUTO=1

echo "===> 开始 os-mihomo 一键配置与部署"

# 步骤 0: 前置检查
echo "--> 步骤 0/5: 正在检查系统运行环境..."
if ! pkg info -e os-mihomo >/dev/null 2>&1; then
    echo "错误：未检测到已安装的 os-mihomo 软件包，请先安装插件包。" >&2
    exit 1
fi

if [ ! -x "$CONFIGCTL" ]; then
    echo "错误：未找到 configctl 工具 ($CONFIGCTL)。" >&2
    exit 1
fi

if [ ! -r "$SETUP_PHP" ]; then
    echo "错误：模型引导脚本不可读 ($SETUP_PHP)。" >&2
    exit 1
fi

if [ ! -x "$PHP_BIN" ]; then
    echo "错误：未找到 PHP 解释器 ($PHP_BIN)。" >&2
    exit 1
fi

if [ "$TRANSPORT" != "transparent" ] && [ "$TRANSPORT" != "proxy" ]; then
    echo "错误：不支持的传输模式: $TRANSPORT (仅支持 transparent 或 proxy)。" >&2
    exit 1
fi

case "$INTERVAL" in
    o6h|o12h|o24h) ;;
    *)
        echo "错误：不支持的自动更新周期: $INTERVAL (仅支持 o6h, o12h, o24h)。" >&2
        exit 1
        ;;
esac

# configd 就绪等待：装包即部署场景下 configd 可能刚被 +POST_INSTALL 重启
_i=0
while [ "$_i" -lt 10 ]; do
    if "$CONFIGCTL" mihomo version >/dev/null 2>&1; then
        break
    fi
    sleep 1
    _i=$((_i + 1))
done

echo "    运行环境就绪 [传输模式: $TRANSPORT, 更新周期: $INTERVAL]"

# 步骤 1: env 写入
# configd 对 %s 参数做 shell 展开，URL 里的 & 会截断命令——直接调 PHP 写入器
# 并以 b64: 前缀传 URL（openssl base64 -A 输出单行）
echo "--> 步骤 1/5: 正在写入订阅环境变量..."
if [ -n "$URL" ]; then
    _b64_url="$(printf '%s' "$URL" | openssl base64 -A 2>/dev/null || true)"
    if [ -z "$_b64_url" ]; then
        echo "警告：URL base64 编码失败（openssl 不可用？），跳过 env 写入" >&2
    else
        if "$PHP_BIN" /usr/local/opnsense/scripts/OPNsense/Mihomo/subscription_env_writer.php "b64:$_b64_url" "$AUTO" "$INTERVAL" >/dev/null 2>&1; then
            echo "    订阅环境变量写入成功"
        else
            echo "警告：写入订阅环境变量失败（URL 校验未通过或文件不可写）" >&2
        fi
    fi
else
    echo "    提示：订阅 URL 为空，沿用既有订阅配置"
fi

# 步骤 2: 模型 + Cron 写入
echo "--> 步骤 2/5: 正在配置模型与定时任务..."
_setup_tmp="$(mktemp /tmp/mihomo-setup.XXXXXX 2>/dev/null || echo /tmp/mihomo-setup.$$.log)"
/usr/local/bin/php "$SETUP_PHP" "$URL" "$TRANSPORT" "$AUTO" "$INTERVAL" > "$_setup_tmp" 2>&1 || true
if ! grep -q '"result":"ok"' "$_setup_tmp"; then
    echo "错误：模型与定时任务引导失败: $(cat "$_setup_tmp" 2>/dev/null)" >&2
    rm -f "$_setup_tmp"
    exit 1
fi
rm -f "$_setup_tmp"
echo "    模型与定时任务配置成功"

# 步骤 3: 传输层分发
# 注意：configctl 的动作与参数必须分开传（'filter reload' 带引号会被当成单个动作名）
echo "--> 步骤 3/5: 正在配置并装载传输层规则..."
if [ "$TRANSPORT" = "transparent" ]; then
    echo "    正在执行 filter reload 以注册 anchor 引用..."
    "$CONFIGCTL" filter reload >/dev/null 2>&1 || true
    echo "    正在启用透明代理传输层 (transport-enable)..."
    "$CONFIGCTL" mihomo transport-enable >/dev/null 2>&1 || true
else
    echo "    正在禁用透明代理传输层 (transport-disable)..."
    "$CONFIGCTL" mihomo transport-disable >/dev/null 2>&1 || true
    echo "    正在重载防火墙规则集 (filter reload)..."
    "$CONFIGCTL" filter reload >/dev/null 2>&1 || true
fi

# 步骤 4: 订阅拉取
echo "--> 步骤 4/5: 正在拉取订阅节点配置..."
if [ -n "$URL" ]; then
    echo "    开始同步拉取订阅（网络较慢时最长可能需要 5 分钟，请耐心等待）..."
    $CONFIGCTL mihomo sub-update >/dev/null 2>&1 || true

    _sub_summary=""
    if [ -f "$STATUS" ]; then
        if command -v python3 >/dev/null 2>&1; then
            _sub_summary="$(python3 -c '
import json, sys
try:
    with open("'"$STATUS"'") as f:
        d = json.load(f)
    print("结果: %s, 节点数: %s, 说明: %s" % (d.get("result","unknown"), d.get("nodes", 0), d.get("message","")))
except Exception:
    pass
' 2>/dev/null || true)"
        fi
        if [ -z "$_sub_summary" ]; then
            _res="$(sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATUS" 2>/dev/null || true)"
            _nodes="$(sed -n 's/.*"nodes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATUS" 2>/dev/null || true)"
            _sub_summary="结果: ${_res:-unknown}, 节点数: ${_nodes:-0}"
        fi
        echo "    订阅更新状态: $_sub_summary"
    else
        echo "    警告：未找到订阅状态记录文件 ($STATUS)，可稍后在面板重新尝试更新" >&2
    fi
else
    echo "    订阅 URL 为空，跳过订阅拉取步骤"
fi

# 步骤 5: 终检报告
echo "--> 步骤 5/5: 正在检查系统运行健康状态..."

_sockstat="$(sockstat -l 2>/dev/null || true)"

# external-controller 探测地址（§2.3 零硬编码）：从 config.yaml 读取；0.0.0.0 归一化为回环；
# 缺失或解析失败时回退单一默认常量
API_HOST="$DEFAULT_API_HOST"
API_PORT="$DEFAULT_API_PORT"
_api_raw="$(awk '
          BEGIN { sq = sprintf("%c", 39) }
  /^external-controller:[[:space:]]*/ {
      line = $0
      sub(/^external-controller:[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      gsub(/"/, "", line)
      gsub(sq, "", line)
      n = split(line, p, ":")
      if (n == 2 && p[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
          p[2] ~ /^[0-9]+$/ &&
          (p[2] + 0) >= 1 && (p[2] + 0) <= 65535) {
          print p[1], p[2]
          found = 1
      }
      exit
  }
' "$CONFIG_FILE" 2>/dev/null || true)"
if [ -n "$_api_raw" ]; then
    API_HOST="${_api_raw% *}"
    API_PORT="${_api_raw#* }"
    if [ "$API_HOST" = "0.0.0.0" ]; then
        API_HOST="$DEFAULT_API_HOST"
    fi
fi

# $1=port；$2=可选 host（给出时也接受通配绑定，0.0.0.0 天然覆盖该地址）
port_listening() {
    _p="$1"
    _h="${2:-}"
    [ -n "$_sockstat" ] || return 1
    if [ -z "$_h" ]; then
        printf "%s\n" "$_sockstat" | grep -E -q "(127\.0\.0\.1|\*|0\.0\.0\.0):${_p}([[:space:]]|$)"
        return $?
    fi
    _hre="$(printf '%s' "$_h" | sed 's/\./\\./g')"
    printf "%s\n" "$_sockstat" | grep -E -q "(${_hre}|\*|0\.0\.0\.0):${_p}([[:space:]]|$)"
}

PORT_7891_STATUS="未监听"
PORT_1053_STATUS="未监听"
PORT_API_STATUS="未监听"
ALL_PORTS_OK=1

if port_listening 7891; then
    PORT_7891_STATUS="监听中"
else
    ALL_PORTS_OK=0
fi

if port_listening 1053; then
    PORT_1053_STATUS="监听中"
else
    ALL_PORTS_OK=0
fi

if port_listening "$API_PORT" "$API_HOST"; then
    PORT_API_STATUS="监听中"
else
    ALL_PORTS_OK=0
fi

TUN_STATUS="不存在"
if ifconfig tun0 >/dev/null 2>&1; then
    TUN_STATUS="存在"
fi

_rules="$(pfctl -a "$ANCHOR" -sr 2>/dev/null || true)"
ANCHOR_RULE_COUNT=0
if [ -n "$_rules" ]; then
    ANCHOR_RULE_COUNT="$(printf "%s\n" "$_rules" | grep -c . || true)"
fi

MODE_CONTENT="未知"
if [ -f /var/db/os-mihomo/transport-mode ]; then
    MODE_CONTENT="$(cat /var/db/os-mihomo/transport-mode 2>/dev/null || echo "未知")"
fi

SUB_SUMMARY_FINAL="无记录"
if [ -f "$STATUS" ]; then
    _res_f="$(sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATUS" 2>/dev/null || true)"
    _nodes_f="$(sed -n 's/.*"nodes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATUS" 2>/dev/null || true)"
    SUB_SUMMARY_FINAL="结果: ${_res_f:-unknown}, 节点数: ${_nodes_f:-0}"
fi

echo "==================== 一键配置终检报告 ===================="
echo "  服务端口 7891 (SOCKS):    $PORT_7891_STATUS"
echo "  服务端口 1053 (DNS):      $PORT_1053_STATUS"
echo "  服务端口 ${API_PORT} (API):      $PORT_API_STATUS"
echo "  虚拟网卡 tun0:            $TUN_STATUS"
echo "  PF anchor 规则数:         $ANCHOR_RULE_COUNT"
echo "  传输层模式文件记录:       $MODE_CONTENT"
echo "  最近订阅更新摘要:         $SUB_SUMMARY_FINAL"
echo "=========================================================="

if [ "$ALL_PORTS_OK" -eq 1 ]; then
    echo "os-mihomo 部署就绪，核心服务运行健康。"
    exit 0
else
    echo "错误：os-mihomo 核心端口健康检查未通过 (7891/1053/${API_PORT})。" >&2
    exit 1
fi
