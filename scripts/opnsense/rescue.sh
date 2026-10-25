#!/bin/sh
# mihomo 迁移一键救援/回退（在 OPNsense 上以 root 运行）
# 用法: sh rescue.sh r0|r1|r2|status [-y]
#   r0     = 回到 xray 现状（停 mihomo → hev 上游改回 10808 → 重启 hev/tun0 → 起 xray_proxy → 确保 anchor 规则在位）
#   r1     = 仅停 mihomo（LAN DNS 由 AdGuardHome fallback 自动兜底；境外断，国内不受影响）
#   r2     = 触发 mihomo fail-open（进程级故障旁路）
#   status = 快速体检（端口/接口/anchor 归属）
# -y 跳过交互确认（供脚本化调用）
set -eu

ACTION="${1:-status}"
YFLAG="${2:-}"
HEV_CONF="/usr/local/etc/xray-proxy/hev-socks5-tunnel.yml"
ANCHOR_FILE="/usr/local/etc/pf.anchors/xray-proxy"
CONFIG_FILE="/usr/local/etc/mihomo/config.yaml"
TRANSPORT_MGR="/usr/local/opnsense/scripts/OPNsense/Mihomo/transport_manager.sh"

# external-controller 端口解析（§2.3）：解析失败按默认 9090 展示
API_PORT=9090
if [ -r "$CONFIG_FILE" ]; then
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
          if (n == 2 && p[2] ~ /^[0-9]+$/ && (p[2] + 0) >= 1 && (p[2] + 0) <= 65535) {
              print p[2]
              found = 1
          }
          exit
      }
    ' "$CONFIG_FILE" 2>/dev/null || true)"
    if [ -n "$_api_raw" ]; then
        API_PORT="$_api_raw"
    fi
fi

confirm() {
    [ "${YFLAG}" = "-y" ] && return 0
    printf '确认执行 %s？输入 yes 继续: ' "$1"
    read -r _ans
    [ "${_ans}" = "yes" ]
}

swap_hev_port() {
    _from="$1"
    _to="$2"
    if [ ! -f "${HEV_CONF}" ]; then
        echo "ERROR: xray hev 配置不存在: ${HEV_CONF}" >&2
        return 1
    fi
    cp -p "${HEV_CONF}" "${HEV_CONF}.bak-rescue-$(date +%H%M%S)"
    sed -i '' "s/^  port: ${_from}$/  port: ${_to}/" "${HEV_CONF}" 2>/dev/null ||
        sed -i "s/^  port: ${_from}$/  port: ${_to}/" "${HEV_CONF}"
    # sed 无匹配也会以 0 退出；必须回读确认端口确实改了，否则后续 hev 仍指向死端口
    if ! grep -q "^  port: ${_to}$" "${HEV_CONF}"; then
        echo "ERROR: 未能在 ${HEV_CONF} 中确认上游端口已改为 ${_to}（原端口 ${_from} 可能不存在），请手工修正；已保留备份。" >&2
        return 1
    fi
}

case "${ACTION}" in
    r0)
        confirm "回退到 xray（mihomo 将停止，代理核心切回 xray:10808）" || exit 1
        echo "==> 拆除 mihomo 透明代理传输层（只动 mihomo-transport anchor）"
        if [ -x "$TRANSPORT_MGR" ]; then
            "$TRANSPORT_MGR" disable >/dev/null 2>&1 || true
        fi
        echo "==> 停止 mihomo"
        service mihomo stop >/dev/null 2>&1 || true
        pkill -TERM -f '/usr/local/bin/mihomo' 2>/dev/null || true
        # mihomo-only 机器没有 xray 配置：保留已停止 mihomo 的状态，不碰 hev/tun0/xray
        if [ ! -f "${HEV_CONF}" ]; then
            echo "==> xray 配置缺失（${HEV_CONF} 不存在），仅停 mihomo；hev/tun0/xray 未改动。"
            exit 0
        fi
        echo "==> hev 上游 7891 → 10808"
        swap_hev_port 7891 10808
        echo "==> 重启 hev 隧道（tun0 重建；hev rc.d pidfile 不可信，tun0 未起则 pkill 兜底重启）"
        service hev_socks5_tunnel restart >/dev/null 2>&1 || true
        sleep 2
        if ! ifconfig tun0 >/dev/null 2>&1; then
            pkill -f hev-socks5-tunnel 2>/dev/null || true
            sleep 1
            service hev_socks5_tunnel start >/dev/null 2>&1 || true
            sleep 2
        fi
        echo "==> 启动 xray_proxy"
        service xray_proxy start >/dev/null 2>&1 || true
        sleep 3
        if ! pfctl -a xray-proxy -sr 2>/dev/null | grep -q .; then
            echo "==> anchor 为空，手动装载 ${ANCHOR_FILE}"
            pfctl -a xray-proxy -f "${ANCHOR_FILE}" 2>/dev/null || true
        fi
        echo "==> r0 完成。验证: ifconfig tun0 / pfctl -a xray-proxy -sr"
        ;;
    r1)
        confirm "仅停止 mihomo（境内与 DNS 不受影响，境外暂停）" || exit 1
        service mihomo stop || true
        echo "==> r1 完成。LAN DNS 由 AdGuardHome fallback 自动兜底。"
        ;;
    r2)
        confirm "触发 mihomo fail-open 旁路" || exit 1
        configctl mihomo failopen "manual rescue" || true
        echo "==> r2 完成。"
        ;;
    status)
        echo "== 端口归属 =="
        sockstat -l | grep -E ":(53|1053|7891|${API_PORT}|10808) " || true
        echo "== 隧道接口 =="
        ifconfig tun0 >/dev/null 2>&1 && echo "tun0 UP" || echo "tun0 DOWN"
        ifconfig tun_mihomo >/dev/null 2>&1 && echo "tun_mihomo UP" || echo "tun_mihomo 不存在（socks 模式正常）"
        echo "== xray anchor 规则数 =="
        pfctl -a xray-proxy -sr 2>/dev/null | wc -l
        echo "== mihomo 状态 =="
        configctl mihomo status 2>/dev/null || true
        ;;
    *)
        echo "用法: $0 r0|r1|r2|status [-y]" >&2
        exit 64
        ;;
esac
