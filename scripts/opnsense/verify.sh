#!/bin/sh
# mihomo 迁移后验证（只读检查 + 出站连通性测试）
# 用法: sh verify.sh [订阅已配置后可加 fakeip]
#   无参数 = 基础体检；带 fakeip 参数时额外验证 1053 的 fake-ip 行为
# 退出码：0=全部关键项通过，1=存在关键失败
set -u

PASS=0
FAIL=0
CRITICAL_FAIL=0

# external-controller 端口解析（§2.3）：0.0.0.0 归一化为回环；解析失败用默认值
CONFIG_FILE=/usr/local/etc/mihomo/config.yaml
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

ok()   { PASS=$((PASS+1));   echo "[PASS] $1"; }
bad()  { FAIL=$((FAIL+1));  echo "[FAIL] $1"; [ "${2:-no}" = "critical" ] && CRITICAL_FAIL=1; }
info() { echo "[INFO] $1"; }

# 1. DNS 前置：AdGuardHome 必须在 :53
if sockstat -4 -l 2>/dev/null | grep -q 'AdGuardHom.*\*:53'; then
    ok "AdGuardHome 监听 *:53"
else
    bad "AdGuardHome 未监听 :53（LAN DNS 生命线）" critical
fi

# 2. mihomo 三个监听：1053(DNS) / 7891(socks) / API（端口由 config.yaml 解析）
M_PIDS="$(pgrep -f '/usr/local/bin/mihomo' | head -1 || true)"
if [ -n "${M_PIDS}" ]; then
    ok "mihomo 进程运行 (pid ${M_PIDS})"
else
    bad "mihomo 进程不存在" critical
fi

for spec in "1053 DNS" "7891 socks" "${API_PORT} api"; do
    _p="${spec%% *}"
    _n="${spec#* }"
    _line="$(sockstat -l 2>/dev/null | grep "mihomo" | grep ":${_p} " | head -1 || true)"
    if [ -n "${_line}" ]; then
        ok "mihomo ${_n} 监听 :${_p}"
    else
        bad "mihomo ${_n} 未监听 :${_p}" critical
    fi
done

# 3. 传输层：tun0 与 xray anchor 规则必须原样在位
if ifconfig tun0 >/dev/null 2>&1; then
    ok "tun0 接口 UP"
else
    bad "tun0 接口不存在" critical
fi
ANCHOR_LINES="$(pfctl -a xray-proxy -sr 2>/dev/null | wc -l | tr -d ' ')"
if [ "${ANCHOR_LINES}" -gt 0 ] 2>/dev/null; then
    ok "PF anchor xray-proxy 规则在位（${ANCHOR_LINES} 条）"
else
    bad "PF anchor xray-proxy 为空（LAN 流量将走直连/WAN）" critical
fi

# 4. 解析链路：1053 可应答
DNS_CMD=""
command -v drill >/dev/null 2>&1 && DNS_CMD="drill"
command -v dig >/dev/null 2>&1 && [ -z "${DNS_CMD}" ] && DNS_CMD="dig"
if [ -n "${DNS_CMD}" ]; then
    if [ "${DNS_CMD}" = "drill" ]; then
        drill @127.0.0.1 -p 1053 taobao.com >/tmp/.v-dns 2>&1 && RCODE=0 || RCODE=1
    else
        dig @127.0.0.1 -p 1053 taobao.com +time=3 +tries=1 >/tmp/.v-dns 2>&1 && RCODE=0 || RCODE=1
    fi
    [ "${RCODE}" -eq 0 ] && ok "1053 可应答（taobao.com）" || bad "1053 无应答" critical
    rm -f /tmp/.v-dns
else
    info "无 drill/dig，跳过 1053 应答检查（可用 python3 /usr/local/opnsense/scripts/system/query_dns.py）"
fi

# 5. 出站：直连 + 经 7891 的代理连通
if curl -s -o /dev/null -m 10 -w '%{http_code}' https://www.baidu.com 2>/dev/null | grep -qE '^[23]'; then
    ok "国内直连正常（baidu.com）"
else
    bad "国内直连异常" critical
fi
if curl -s -o /dev/null -m 15 --socks5-hostname 127.0.0.1:7891 -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null | grep -qE '^(204|2|3)'; then
    ok "经 mihomo:7891 代理出站正常（gstatic 204）"
else
    bad "经 mihomo:7891 代理出站失败（节点未配置或不可用）"
fi

# 6. fake-ip 行为（订阅配置后验证）
if [ "${1:-}" = "fakeip" ] && [ -n "${DNS_CMD}" ]; then
    if [ "${DNS_CMD}" = "drill" ]; then
        drill @127.0.0.1 -p 1053 openai.com 2>/dev/null | grep -oE '198\.18\.[0-9]+\.[0-9]+' | head -1
    else
        dig @127.0.0.1 -p 1053 openai.com +short 2>/dev/null | grep -oE '198\.18\.[0-9]+\.[0-9]+' | head -1
    fi
    if [ -n "${_fip:-}" ] || drill @127.0.0.1 -p 1053 openai.com 2>/dev/null | grep -qE '198\.18\.' || dig @127.0.0.1 -p 1053 openai.com +short 2>/dev/null | grep -qE '198\.18\.'; then
        ok "fake-ip 生效（openai.com → 198.18.0.0/15）"
    else
        bad "fake-ip 未生效（geolocation-!cn 域名未返回 198.18 地址）"
    fi
fi

# 7. 服务状态机
configctl mihomo status 2>/dev/null | head -5 || true

echo ""
echo "== 汇总: PASS=${PASS} FAIL=${FAIL} =="
[ "${CRITICAL_FAIL}" -eq 0 ] || exit 1
exit 0
