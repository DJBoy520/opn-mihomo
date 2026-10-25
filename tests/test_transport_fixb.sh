#!/bin/sh
set -eu

echo "===> Running transport fixB gate checks (loopback ACL + hev credential sync + e2e probe)..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
SUB_LIB="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub_lib.sh"
TMGR="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/transport_manager.sh"
PROBE="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/transport_probe.php"
HEV_SAMPLE="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/hev.yaml.sample"

fail() {
    echo "FAIL: $1"
    exit 1
}

# 1. 语法门禁
echo "--> Test 1: shell syntax..."
sh -n "$SUB_LIB" || fail "sub_lib.sh shell syntax error"
sh -n "$TMGR" || fail "transport_manager.sh shell syntax error"
echo "  [PASS] shell syntax verified."

# 2. sub_lib.sh LAN 暴露收窄分支必须始终保留回环（fixB 核心断言）
echo "--> Test 2: sub_lib.sh LAN exposure keeps loopback in lan-allowed-ips..."
grep -A10 'in_lan_ips = 1' "$SUB_LIB" | grep -q '127\.0\.0\.1/32' \
    || fail "sub_lib.sh lan-allowed-ips narrowing missing 127.0.0.1/32 (transparent hev loopback would be cut)"
grep -A10 'in_lan_ips = 1' "$SUB_LIB" | grep -q '::1/128' \
    || fail "sub_lib.sh lan-allowed-ips narrowing missing ::1/128"
echo "  [PASS] loopback entries asserted in LAN exposure branch."

# 3. transport_manager.sh 必须有 hev 凭证同步函数且在 enable 中调用（重启路径 + 全新安装路径）
echo "--> Test 3: transport_manager.sh hev_sync_auth definition & call sites..."
grep -q '^hev_sync_auth()' "$TMGR" || fail "hev_sync_auth() missing"
_TMGR_CALLS="$(grep -c 'hev_sync_auth' "$TMGR")"
[ "${_TMGR_CALLS}" -ge 3 ] || fail "hev_sync_auth invoked fewer than 2 times (definition+2 call sites): got ${_TMGR_CALLS}"
echo "  [PASS] hev_sync_auth defined and called on both enable paths."

# 4. 端到端探针接线：probe 文件存在、被 status 引用、php 可用时语法过检
echo "--> Test 4: transport_probe.php wiring..."
[ -f "$PROBE" ] || fail "transport_probe.php missing"
grep -q 'transport_probe.php' "$TMGR" || fail "transport_manager.sh status does not invoke transport_probe.php"
if command -v php >/dev/null 2>&1; then
    php -l "$PROBE" >/dev/null || fail "transport_probe.php PHP syntax error"
fi
grep -q 'SOCKS probe' "$PROBE" || fail "probe output contract missing"
# 鉴权块解析必须接受空值键行 `authentication:`（(.+) 会漏掉块式配置导致探针假阴性）
grep -qF 'authentication:\s*(.*)' "$PROBE" || fail "probe authentication regex must match empty key line (use (.*) not (.+))"
# 空值键行必须进入块解析（inAuth=true），仅 flow 空列表 `[]` 才结束
grep -A8 "\\\$val === '\\[\\]'" "$PROBE" | grep -q 'inAuth = true' \
    || fail "probe must start block parsing on empty authentication key (inAuth = true)"
echo "  [PASS] probe present, wired into status, output contract verified."

# 5. hev.yaml.sample 必须注明凭证由 transport_manager 管理（防再次手工分叉）
echo "--> Test 5: hev.yaml.sample credential ownership note..."
grep -q 'transport_manager' "$HEV_SAMPLE" || fail "hev.yaml.sample missing credential ownership note"
echo "  [PASS] sample documents managed credentials."

# 6. 功能测试：从 transport_manager.sh 提取 fixB awk 哨兵段，对样例文件真实执行
#    （测的就是将要部署的代码，不内嵌副本防漂移）
echo "--> Test 6: functional run of fixB awk blocks extracted from source..."
_WORK="$(mktemp -d)"
trap 'rm -rf "$_WORK"' EXIT
sed -n '/fixB-awk-inject-begin/,/fixB-awk-inject-end/p' "$TMGR" > "$_WORK/inject.txt"
sed -n '/fixB-awk-strip-begin/,/fixB-awk-strip-end/p' "$TMGR" > "$_WORK/strip.txt"
grep -q 'awk' "$_WORK/inject.txt" || fail "inject awk block not extractable"
grep -q 'awk' "$_WORK/strip.txt" || fail "strip awk block not extractable"

# 在函数内 eval 提取片段：片段带 `|| { ...; return 0; }`，必须处于函数上下文
run_block() {
    eval "$(cat "$1")"
}

# 6a. inject：sample（无凭证）+ authentication → 应新增 username/password 且保留原字段
printf 'socks5:\n  address: 127.0.0.1\n  port: 7891\n  udp: %sudp%s\nmisc:\n  log-level: warn\n' "'" "'" > "$_WORK/hev_in"
_auth_pair='mihomo:s3cret!'
HEV_CONF="$_WORK/hev_in"
_tmp_hev="$_WORK/hev_out"
run_block "$_WORK/inject.txt"
grep -q 'username: mihomo' "$_WORK/hev_out" || fail "inject awk did not add username"
grep -q 'password: s3cret!' "$_WORK/hev_out" || fail "inject awk did not add password (value after first colon)"
grep -q 'address: 127.0.0.1' "$_WORK/hev_out" || fail "inject awk lost existing socks5 fields"
grep -q 'log-level: warn' "$_WORK/hev_out" || fail "inject awk lost content outside socks5 block"

# 6b. inject：已有旧凭证 → 原地更新且不重复
printf 'socks5:\n  address: 127.0.0.1\n  username: old\n  password: oldpass\n  port: 7891\n' > "$_WORK/hev_in2"
_auth_pair='mihomo:newpass'
HEV_CONF="$_WORK/hev_in2"
_tmp_hev="$_WORK/hev_out2"
run_block "$_WORK/inject.txt"
[ "$(grep -c 'username:' "$_WORK/hev_out2")" -eq 1 ] || fail "inject awk duplicated username"
grep -q 'password: newpass' "$_WORK/hev_out2" || fail "inject awk did not update stale password"
grep -q 'oldpass' "$_WORK/hev_out2" && fail "inject awk left stale password behind"
echo "  [PASS] inject awk: fresh insert + in-place update verified."

# 6c. strip：无 authentication → 凭证必须被清除且其余字段保留
printf 'socks5:\n  address: 127.0.0.1\n  username: mihomo\n  password: x\n  port: 7891\n' > "$_WORK/hev_in3"
HEV_CONF="$_WORK/hev_in3"
_tmp_hev="$_WORK/hev_out3"
run_block "$_WORK/strip.txt"
grep -q 'username' "$_WORK/hev_out3" && fail "strip awk left username behind"
grep -q 'password' "$_WORK/hev_out3" && fail "strip awk left password behind"
grep -q 'address: 127.0.0.1' "$_WORK/hev_out3" || fail "strip awk lost socks5 fields"
grep -q 'port: 7891' "$_WORK/hev_out3" || fail "strip awk lost socks5 port"
echo "  [PASS] strip awk removes stale credentials cleanly."

echo "===> All transport fixB gate checks PASSED."
