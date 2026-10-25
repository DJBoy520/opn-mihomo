#!/bin/sh
# OPNsense mihomo 迁移前备份（只读采集，不修改任何系统状态）
# 用法: sh backup.sh   （root 运行；产物在 /root/backup-<时间戳>/）
set -eu

TS="$(date +%Y%m%d-%H%M%S)"
DIR="/root/backup-${TS}"
mkdir -p "${DIR}"

echo "==> 备份到 ${DIR}"
cp -p /conf/config.xml "${DIR}/config.xml"

pfctl -sr > "${DIR}/pf-rules.txt" 2>/dev/null || true
pfctl -sn > "${DIR}/pf-nat.txt" 2>/dev/null || true
pfctl -sA > "${DIR}/pf-anchors.txt" 2>/dev/null || true
pfctl -a xray-proxy -sr > "${DIR}/pf-anchor-xray-proxy.txt" 2>/dev/null || true
netstat -rn > "${DIR}/routes.txt" 2>/dev/null || true
sysrc -a > "${DIR}/rc-conf.txt" 2>/dev/null || true
sockstat -46 -l > "${DIR}/sockstat.txt" 2>/dev/null || true
ps -axo pid,ppid,command > "${DIR}/processes.txt" 2>/dev/null || true

[ -d /usr/local/etc/xray-proxy ] && cp -a /usr/local/etc/xray-proxy "${DIR}/xray-proxy" || true
[ -f /usr/local/etc/pf.anchors/xray-proxy ] && cp -p /usr/local/etc/pf.anchors/xray-proxy "${DIR}/" || true
[ -f /usr/local/AdGuardHome/AdGuardHome.yaml ] && cp -p /usr/local/AdGuardHome/AdGuardHome.yaml "${DIR}/" || true
[ -f /var/unbound/unbound.conf ] && cp -p /var/unbound/unbound.conf "${DIR}/" || true
[ -f /var/dhcpd/etc/dhcpd.conf ] && cp -p /var/dhcpd/etc/dhcpd.conf "${DIR}/" || true
[ -f /usr/local/etc/xray-proxy/hev-socks5-tunnel.yml ] && cp -p /usr/local/etc/xray-proxy/hev-socks5-tunnel.yml "${DIR}/" || true

chmod 700 "${DIR}"
find "${DIR}" -type f -exec chmod 600 {} +

echo "==> 备份完成: ${DIR}"
ls -la "${DIR}"
