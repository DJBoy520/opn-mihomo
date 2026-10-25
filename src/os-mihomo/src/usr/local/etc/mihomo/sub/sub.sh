#!/bin/sh
# 订阅拉取与配置更新脚本
# 本脚本由 sub_lib.sh 提供能力、锁与 rules-apply 共用。

#################### 初始化 ####################
Server_Dir=$(cd "$(dirname "$0")" && pwd)
SUB_LIB="${MIHOMO_SUB_LIB:-$Server_Dir/sub_lib.sh}"

if [ ! -f "$SUB_LIB" ]; then
    echo "错误：未找到订阅函数库 $SUB_LIB" >&2
    exit 4
fi
. "$SUB_LIB"

ENV_MIHOMO_URL="${mihomo_URL:-}"
ENV_MIHOMO_SECRET="${mihomo_secret:-}"
[ -f "$Server_Dir/env" ] && . "$Server_Dir/env"
[ -n "$ENV_MIHOMO_URL" ] && mihomo_URL="$ENV_MIHOMO_URL"
[ -n "$ENV_MIHOMO_SECRET" ] && mihomo_secret="$ENV_MIHOMO_SECRET"

Conf_Dir="${MIHOMO_CONF_DIR:-$(cd "$Server_Dir/.." && pwd)}"
Temp_Dir="${MIHOMO_TEMP_DIR:-$Server_Dir/temp}"
Clash_Dir="${MIHOMO_DIR:-/usr/local/etc/mihomo}"
ATOMIC_UPDATER="${MIHOMO_ATOMIC_UPDATER:-/usr/local/opnsense/scripts/OPNsense/Mihomo/atomic_config_updater.sh}"
SECRET_MANAGER="${MIHOMO_SECRET_MANAGER:-/usr/local/opnsense/scripts/OPNsense/Mihomo/secret_manager.sh}"
LOCK_DIR="${MIHOMO_LOCK_DIR:-/var/run/mihomo-sub.lock}"
TEMPLATE_FILE="${MIHOMO_TEMPLATE_FILE:-$Server_Dir/template_config.yaml}"

TMP_RAW=""
TMP_PROXIES=""
TMP_NAMES=""
TMP_STRATEGY=""
TMP_FINAL=""
mkdir -p "$Conf_Dir" "$Temp_Dir"

command -v jq >/dev/null 2>&1 || {
  echo "缺少 jq 命令，请先安装"
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "缺少 curl 命令，请先安装。"
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  echo "缺少 openssl 命令，请先安装。"
  exit 1
}

cleanup_tmp_files() {
    [ -n "$TMP_RAW" ] && rm -f "$TMP_RAW"
    [ -n "$TMP_PROXIES" ] && rm -f "$TMP_PROXIES"
    [ -n "$TMP_NAMES" ] && rm -f "$TMP_NAMES"
    [ -n "$TMP_STRATEGY" ] && rm -f "$TMP_STRATEGY"
    [ -n "$TMP_FINAL" ] && rm -f "$TMP_FINAL"
    rm -f "$Conf_Dir/config.clean.yaml" "$Conf_Dir/config.new.yaml"
    mihomo_lib_lock_release
}

trap cleanup_tmp_files EXIT INT TERM

# 锁机制（使用 sub_lib.sh 提供的函数）
if ! mihomo_lib_lock_acquire; then
    _lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    echo "错误：订阅任务已在运行，请勿重复执行。"
    [ -n "$_lock_pid" ] && echo "当前锁持有进程 PID: $_lock_pid"
    exit 9
fi

# mihomo订阅地址校验（仅允许 https，杜绝明文传输订阅凭据）
[ -z "$mihomo_URL" ] && {
    echo "错误：未设置 mihomo_URL 环境变量"
    mihomo_lib_status_write "failed" 0 "" "未设置 mihomo_URL 环境变量"
    exit 1
}
URL_SCHEME_CHECK=$(printf "%s" "$mihomo_URL" | tr '[:upper:]' '[:lower:]')
case "$URL_SCHEME_CHECK" in
    https://*) ;;
    http://*)
        echo "错误：订阅地址禁止使用 http://（订阅凭据会明文传输），请使用 https://"
        mihomo_lib_status_write "failed" 0 "" "订阅地址禁止使用 http://"
        exit 1
        ;;
    *)
        echo "错误：mihomo_URL 必须以 https:// 开头"
        mihomo_lib_status_write "failed" 0 "" "mihomo_URL 必须以 https:// 开头"
        exit 1
        ;;
esac

# 安全密钥
if [ -n "$mihomo_secret" ]; then
    Secret="$mihomo_secret"
elif [ -x "$SECRET_MANAGER" ]; then
    Secret="$("$SECRET_MANAGER" get 2>/dev/null || true)"
fi
[ -z "$Secret" ] && Secret=$(openssl rand -hex 32)
export mihomo_secret="$Secret"

# URL 脱敏函数（供本地及测试兼容调用）
mask_url() {
    mihomo_lib_mask_url "$1"
}

#################### 预清理临时文件 ####################
find "$Temp_Dir" -type f -exec rm -f {} \; 2>/dev/null

TMP_RAW=$(mktemp "$Temp_Dir/clash_config.XXXXXX") || {
    echo "创建临时文件失败：TMP_RAW"
    mihomo_lib_status_write "failed" 0 "" "创建临时文件失败"
    exit 1
}
TMP_PROXIES=$(mktemp "$Temp_Dir/proxies.XXXXXX") || {
    echo "创建临时文件失败：TMP_PROXIES"
    mihomo_lib_status_write "failed" 0 "" "创建临时文件失败"
    exit 1
}
TMP_FINAL=$(mktemp "$Temp_Dir/config.XXXXXX") || {
    echo "创建临时文件失败：TMP_FINAL"
    mihomo_lib_status_write "failed" 0 "" "创建临时文件失败"
    exit 1
}

#################### 下载配置 ####################
# 如果配置了私有 CUSTOM_SUBCONVERTER 则使用自建 subconverter 进行转换，否则直接下载原生 Clash/Mihomo YAML 订阅
if [ -n "${CUSTOM_SUBCONVERTER:-}" ]; then
    ENCODED_URL=$(printf "%s" "$mihomo_URL" | jq -s -R -r @uri)
    API_URL="${CUSTOM_SUBCONVERTER}?target=clash&url=${ENCODED_URL}&udp=true&clash.dns=true&list=false"
    TARGET_URL="$API_URL"
    DISPLAY_URL="$(mihomo_lib_mask_url "$CUSTOM_SUBCONVERTER") [custom subconverter]"
else
    TARGET_URL="$mihomo_URL"
    DISPLAY_URL="$(mihomo_lib_mask_url "$mihomo_URL")"
fi

echo ""
echo "尝试不使用代理从：$DISPLAY_URL 下载配置..."
if curl -fSL -sS --retry 3 -m 120 --connect-timeout 15 -o "$TMP_RAW" "$TARGET_URL"; then
    echo "下载成功：$TMP_RAW"
else
    echo "下载失败，尝试通过 SOCKS5 代理 127.0.0.1:7891 下载配置..."
    if curl -fSL -sS --retry 2 -m 120 --connect-timeout 15 --socks5-hostname 127.0.0.1:7891 -o "$TMP_RAW" "$TARGET_URL"; then
        echo "下载成功：$TMP_RAW"
    else
        echo "下载失败：$DISPLAY_URL"
        echo "请检查网络连接或 mihomo 是否运行并监听 127.0.0.1:7891"
        mihomo_lib_status_write "failed" 0 "" "下载订阅失败（直连与 SOCKS5 均失败）"
        exit 2
    fi
fi

if [ ! -s "$TMP_RAW" ]; then
    echo "下载结果为空，订阅内容无效。"
    mihomo_lib_status_write "failed" 0 "" "下载结果为空"
    exit 1
fi

RAW_SIZE=$(wc -c < "$TMP_RAW" | tr -d ' ')
echo "下载文件大小: ${RAW_SIZE} 字节"

if head -n 20 "$TMP_RAW" | grep -Eiq '^(<!doctype html|<html|<head|<body)'; then
    echo "检测到返回内容为 HTML 页面，订阅可能失效或被拦截。"
    mihomo_lib_status_write "failed" 0 "" "订阅返回 HTML 页面"
    exit 1
fi

if ! grep -Eq '^[[:space:]]*proxies[[:space:]]*:' "$TMP_RAW"; then
    echo "下载结果缺少 proxies: 节点，订阅内容可能无效。"
    mihomo_lib_status_write "failed" 0 "" "订阅缺少 proxies 节点"
    exit 1
fi
echo ""

#################### 合成配置 ####################
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "缺少模板文件：$TEMPLATE_FILE"
    mihomo_lib_status_write "failed" 0 "" "缺少模板文件"
    exit 1
fi

# 提取代理节点
if ! mihomo_lib_extract_proxies "$TMP_RAW" "$TMP_PROXIES" || [ ! -s "$TMP_PROXIES" ]; then
    echo "提取代理节点失败，proxies 段为空。"
    mihomo_lib_status_write "failed" 0 "" "提取代理节点失败"
    exit 1
fi

NODE_COUNT=$(mihomo_lib_count_nodes "$TMP_PROXIES")
echo "提取节点数量: ${NODE_COUNT}"
if [ "${NODE_COUNT:-0}" -le 0 ] 2>/dev/null; then
    echo "提取到的代理节点数量为 0，停止应用。"
    mihomo_lib_status_write "failed" 0 "" "提取代理节点数量为 0"
    exit 1
fi

# 策略片段处理
STRATEGY_MODE="$(mihomo_lib_strategy_mode)"
STRATEGY_FALLBACK_MSG=""
TMP_STRATEGY=""
if [ "$STRATEGY_MODE" = "subscription" ]; then
    TMP_STRATEGY="$(mktemp "$Temp_Dir/strategy.XXXXXX")" || {
        echo "创建临时文件失败：TMP_STRATEGY"
        mihomo_lib_status_write "failed" "$NODE_COUNT" "" "创建策略临时文件失败"
        exit 1
    }
    if mihomo_lib_extract_strategy "$TMP_RAW" "$TMP_STRATEGY"; then
        export MIHOMO_STRATEGY_INPUT_FILE="$TMP_STRATEGY"
    else
        rm -f "$TMP_STRATEGY"
        TMP_STRATEGY=""
        export MIHOMO_STRATEGY_MODE="template"
        STRATEGY_FALLBACK_MSG="订阅缺少 proxy-groups 或 rules，已回退插件模板"
        echo "提示：$STRATEGY_FALLBACK_MSG" >&2
    fi
fi

# 合成配置
echo "合成配置..."
sleep 1
if ! mihomo_lib_compose "$TMP_PROXIES" "$TMP_FINAL"; then
    echo "合成配置失败。"
    mihomo_lib_status_write "failed" "$NODE_COUNT" "" "合成配置失败"
    exit 1
fi

COMPOSE_USED="${MIHOMO_COMPOSE_STRATEGY_USED:-template}"
COMPOSE_GROUPS="${MIHOMO_COMPOSE_STRATEGY_GROUPS:-0}"
COMPOSE_RULES="${MIHOMO_COMPOSE_STRATEGY_RULES:-0}"

if [ ! -s "$TMP_FINAL" ]; then
    echo "合成后的配置文件为空。"
    mihomo_lib_status_write "failed" "$NODE_COUNT" "" "合成后的配置文件为空" "$COMPOSE_USED" "$COMPOSE_GROUPS" "$COMPOSE_RULES"
    exit 1
fi

FINAL_SIZE=$(wc -c < "$TMP_FINAL" | tr -d ' ')
echo "合成配置大小: ${FINAL_SIZE} 字节"
echo "合成完成!"
echo ""

#################### 原子应用配置并重启 ####################
# 交由 atomic_config_updater：mihomo -t 校验通过才备份并原子替换 config.yaml，
# 校验失败时生产配置保持不变（坏订阅永远不会覆盖好配置）。
echo "应用配置..."
if [ -x "$ATOMIC_UPDATER" ]; then
    if ! "$ATOMIC_UPDATER" "$TMP_FINAL" reload; then
        echo "原子更新配置失败！生产配置保持不变。"
        mihomo_lib_status_write "failed" "$NODE_COUNT" "" "原子更新配置校验或替换失败" "$COMPOSE_USED" "$COMPOSE_GROUPS" "$COMPOSE_RULES"
        exit 1
    fi
else
    echo "错误：未找到原子更新脚本 $ATOMIC_UPDATER"
    mihomo_lib_status_write "failed" "$NODE_COUNT" "" "未找到原子更新脚本" "$COMPOSE_USED" "$COMPOSE_GROUPS" "$COMPOSE_RULES"
    exit 1
fi
echo ""

# D3 缓存一致性：原子更新成功后，持久化缓存并记录哈希
CACHE_HASH=$(mihomo_lib_cache_store "$TMP_PROXIES" 2>/dev/null || true)

STRATEGY_STORE_WARN=""
if [ "$COMPOSE_USED" = "subscription" ] && [ -n "$TMP_STRATEGY" ]; then
    if ! mihomo_lib_strategy_store "$TMP_STRATEGY"; then
        STRATEGY_STORE_WARN="（策略缓存写入失败）"
    fi
elif [ "$COMPOSE_USED" = "template" ] && [ "$STRATEGY_MODE" = "subscription" ]; then
    mihomo_lib_strategy_remove
fi

if [ "$COMPOSE_USED" = "subscription" ]; then
    MSG="订阅更新成功（策略：订阅自带，${COMPOSE_GROUPS} 个策略组 / ${COMPOSE_RULES} 条规则）"
else
    MSG="订阅更新成功（策略：插件模板）"
fi

if [ -n "$STRATEGY_FALLBACK_MSG" ]; then
    MSG="${MSG}；${STRATEGY_FALLBACK_MSG}"
fi
if [ -n "$STRATEGY_STORE_WARN" ]; then
    MSG="${MSG}${STRATEGY_STORE_WARN}"
fi

mihomo_lib_status_write "success" "$NODE_COUNT" "$CACHE_HASH" "$MSG" "$COMPOSE_USED" "$COMPOSE_GROUPS" "$COMPOSE_RULES"
echo "$MSG"

#################### 输出仪表盘信息 ####################
sleep 1
LAN_IP=$(
  ifconfig 2>/dev/null | awk '
    /^[[:alnum:]_.:-]+:/ {
      iface=$1
      sub(/:.*/, "", iface)
      skip=(iface ~ /^(lo|tun|pflog|pfsync|enc|gif|gre|stf|ovpn|wg)/)
      next
    }
    /inet / {
      ip=$2
      if (!skip &&
          ip != "127.0.0.1" &&
          ip !~ /^169\.254\./ &&
          ip ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)/) {
        print ip
        exit
      }
    }
  '
)

# 面板访问提示动态化（external-controller 绑定/端口可配置；0.0.0.0 归一为回环）
_API_ADDR="$(mihomo_lib_api_addr "$Conf_Dir/config.yaml" 2>/dev/null || true)"
case "$_API_ADDR" in
    *' '*) ;;
    *) _API_ADDR="127.0.0.1 9090" ;;
esac
_API_HOST="${_API_ADDR%% *}"
_API_PORT="${_API_ADDR##* }"

# 如果还是取不到，就给一个兜底提示
if [ -n "$LAN_IP" ]; then
  echo "面板访问（API 绑定 ${_API_HOST}:${_API_PORT}，非 LAN 地址时需 SSH 隧道）:"
  echo "  ssh -L ${_API_PORT}:${_API_HOST}:${_API_PORT} root@${LAN_IP}  然后本机打开 http://${_API_HOST}:${_API_PORT}/ui"
else
  echo "面板访问：未能自动获取 LAN/OPT1 地址，请手动 SSH 隧道 -L ${_API_PORT}:${_API_HOST}:${_API_PORT}"
fi

if [ -x "$SECRET_MANAGER" ]; then
    MASKED_SECRET="$("$SECRET_MANAGER" masked 2>/dev/null || true)"
    if [ -n "$MASKED_SECRET" ]; then
        echo "仪表盘访问密钥: ${MASKED_SECRET}"
    else
        echo "仪表盘访问密钥: 已配置"
    fi
else
    echo "仪表盘访问密钥: 已配置"
fi
echo ""

#################### 清理临时文件 ####################
cleanup_tmp_files
