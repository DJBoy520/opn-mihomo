#!/bin/sh
set -eu

# api-bind v1.0.8 功能测试（docs/DESIGN-lan-api.md v3.2）
# 从仓库根运行：sh tests/test_api_bind.sh
# 本机（CI/Linux）没有 ifconfig/sockstat/pgrep 语义，全部用临时 mock 注入；
# 生产路径由 api_bind_manager.sh 的默认值覆盖。

echo "===> Running api-bind tests..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

API_MGR="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/api_bind_manager.sh"
SUB_LIB="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub_lib.sh"
SECRET_MGR="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/secret_manager.sh"
STATUS_PY="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/system_status.py"

TMP_DIR="$(mktemp -d /tmp/test-api-bind.XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*"
    exit 1
}

pass() {
    echo "  [PASS] $*"
}

[ -x "$API_MGR" ] || [ -f "$API_MGR" ] || fail "missing api_bind_manager.sh"
sh -n "$API_MGR" || fail "api_bind_manager.sh syntax error"

# ---- mocks ----
printf '#!/bin/sh\nexit 1\n' > "$TMP_DIR/not-running"
printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/running"
cat > "$TMP_DIR/ifconfig" <<'EOF'
#!/bin/sh
echo 'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384'
echo '	inet 127.0.0.1 netmask 0xff000000'
echo 'em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500'
echo '	inet 192.168.50.2 netmask 0xffffff00 broadcast 192.168.50.255'
echo '	inet6 2001:db8::10.9.9.9 prefixlen 64'
echo '	inet 10.9.9.90 netmask 0xffffff00'
EOF
cat > "$TMP_DIR/sockstat-old" <<'EOF'
#!/bin/sh
port=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -p) shift; port="$1" ;;
    esac
    shift
done
case "$port" in
    9090) echo "root mihomo 111 3 tcp4 127.0.0.1:9090 *:*" ;;
esac
exit 0
EOF
cat > "$TMP_DIR/svc-fail-once" <<EOF
#!/bin/sh
n=0
if [ -f "$TMP_DIR/svc.cnt" ]; then
    n="\$(cat "$TMP_DIR/svc.cnt")"
fi
n=\$((n + 1))
printf '%s\n' "\$n" > "$TMP_DIR/svc.cnt"
if [ "\$n" -le 1 ]; then
    exit 1
fi
exit 0
EOF
cat > "$TMP_DIR/svc-always-fail" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$TMP_DIR/svc-always-ok" <<'EOF'
#!/bin/sh
exit 0
EOF
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$SECRET_MGR" > "$TMP_DIR/secret_manager.sh"
chmod +x "$TMP_DIR"/*

export MIHOMO_API_CONF="$TMP_DIR/config.yaml"
export MIHOMO_API_TEMPLATE="$TMP_DIR/template.yaml"
export MIHOMO_SECRET_FILE="$TMP_DIR/secret.key"
export MIHOMO_LOCK_DIR="$TMP_DIR/sub.lock"
export MIHOMO_PANEL_STATE_FILE="$TMP_DIR/panel-state.env"
export MIHOMO_API_ALERT_FILE="$TMP_DIR/api-bind.alert"
export MIHOMO_API_IFCONFIG="$TMP_DIR/ifconfig"
export MIHOMO_API_PGREP="$TMP_DIR/not-running"
export MIHOMO_API_SOCKSTAT="$TMP_DIR/sockstat-old"
export MIHOMO_API_ASSERT_TIMEOUT=1
export MIHOMO_SECRET_MANAGER="$TMP_DIR/secret_manager.sh"
# secret_manager.sh 使用同一组文件（secret 门禁会调用它同步四处）
export MIHOMO_CONFIG_FILE="$MIHOMO_API_CONF"
export MIHOMO_TEMPLATE_FILE="$MIHOMO_API_TEMPLATE"
export MIHOMO_ENV_FILE="$TMP_DIR/env"

reset_files() {
    printf 'mixed-port: 7890\nexternal-controller: 127.0.0.1:9090\nsecret: "%s"\n' "test-secret-0123456789" > "$MIHOMO_API_CONF"
    cp -f "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE"
    rm -f "$MIHOMO_SECRET_FILE" "$MIHOMO_API_ALERT_FILE" "$TMP_DIR/svc.cnt"
    rm -f "$MIHOMO_LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$MIHOMO_LOCK_DIR" 2>/dev/null || true
    rm -f "$TMP_DIR"/*.api-bind.*.bak 2>/dev/null || true
}

probe_lib() {
    # $1 = conf path
    sh -c '. "$1"; mihomo_lib_api_addr "$2"' sh "$SUB_LIB" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "--> Test 1: mihomo_lib_api_addr 解析矩阵..."
reset_files
printf 'external-controller: 0.0.0.0:9090\n' > "$TMP_DIR/p1.yaml"
[ "$(probe_lib "$TMP_DIR/p1.yaml")" = "127.0.0.1 9090" ] || fail "0.0.0.0 not normalized"
printf 'external-controller: 192.168.1.10:12345\n' > "$TMP_DIR/p2.yaml"
[ "$(probe_lib "$TMP_DIR/p2.yaml")" = "192.168.1.10 12345" ] || fail "interface IP parse"
printf 'external-controller: "127.0.0.1:9093" # quoted\n' > "$TMP_DIR/p3.yaml"
[ "$(probe_lib "$TMP_DIR/p3.yaml")" = "127.0.0.1 9093" ] || fail "quoted parse"
printf 'external-controller: 192.168.1.10:9095 # inline comment\n' > "$TMP_DIR/p4.yaml"
[ "$(probe_lib "$TMP_DIR/p4.yaml")" = "192.168.1.10 9095" ] || fail "inline comment parse"
printf 'port: 7890\nsecret: "x"\n' > "$TMP_DIR/p5.yaml"
_probe_err="$(sh -c '. "$1"; mihomo_lib_api_addr "$2"' sh "$SUB_LIB" "$TMP_DIR/p5.yaml" 2>&1 >/dev/null || true)"
[ "$(probe_lib "$TMP_DIR/p5.yaml")" = "127.0.0.1 9090" ] || fail "missing line fallback"
printf '%s' "$_probe_err" | grep -q '回退' || fail "missing line did not warn on stderr"
printf 'external-controller: not-an-address\n' > "$TMP_DIR/p6.yaml"
[ "$(probe_lib "$TMP_DIR/p6.yaml")" = "127.0.0.1 9090" ] || fail "corrupt line fallback"
printf 'external-controller: 127.0.0.1:65536\n' > "$TMP_DIR/p7.yaml"
[ "$(probe_lib "$TMP_DIR/p7.yaml")" = "127.0.0.1 9090" ] || fail "out-of-range port fallback"
[ "$(probe_lib "$TMP_DIR/does-not-exist.yaml")" = "127.0.0.1 9090" ] || fail "missing file fallback"
pass "0.0.0.0 / 接口 IP / 回环 / 引号 / 注释 / 缺失 / 损坏"

# ---------------------------------------------------------------------------
echo "--> Test 2: apply 两态渲染 + 写后校验..."
reset_files
_out="$("$API_MGR" apply 0.0.0.0 9151 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE")"
case "$_out" in
    *"OK: api bind"*) : ;;
    *) fail "apply did not print OK: $_out" ;;
esac
grep -q -x -F 'external-controller: 0.0.0.0:9151' "$MIHOMO_API_CONF" || fail "config not rendered (0.0.0.0)"
grep -q -x -F 'external-controller: 0.0.0.0:9151' "$MIHOMO_API_TEMPLATE" || fail "template not rendered (0.0.0.0)"
_out="$("$API_MGR" apply 127.0.0.1 9151 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE")"
grep -q -x -F 'external-controller: 127.0.0.1:9151' "$MIHOMO_API_CONF" || fail "config not rendered (127.0.0.1)"
grep -q -x -F 'external-controller: 127.0.0.1:9151' "$MIHOMO_API_TEMPLATE" || fail "template not rendered (127.0.0.1)"
# 幂等：重复执行输出一致
_out2="$("$API_MGR" apply 127.0.0.1 9151 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE")"
[ "$_out" = "$_out2" ] || fail "apply is not idempotent: $_out vs $_out2"
# 行缺失时追加：末行无换行也不得拼接
printf 'port: 7891\nsecret: "test-secret-0123456789"' > "$MIHOMO_API_CONF"
printf 'port: 7891\nsecret: "test-secret-0123456789"' > "$MIHOMO_API_TEMPLATE"
"$API_MGR" apply 127.0.0.1 9152 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" >/dev/null
grep -q -x -F 'port: 7891' "$MIHOMO_API_CONF" || fail "append merged with previous line"
grep -q -x -F 'external-controller: 127.0.0.1:9152' "$MIHOMO_API_CONF" || fail "append missing line failed"
find "$TMP_DIR" -name '*.api-bind.*.bak' | grep -q . && fail "backup files not cleaned up"
pass "两态渲染、写后校验、幂等、缺行追加"

# ---------------------------------------------------------------------------
echo "--> Test 3: 本机地址核验（ifconfig 精确字段匹配）..."
reset_files
cp "$MIHOMO_API_CONF" "$TMP_DIR/before.yaml"
"$API_MGR" apply 192.168.50.2 9161 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" >/dev/null || \
    fail "local interface IP rejected"
_out="$("$API_MGR" apply 10.9.9.9 9161 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" 2>&1)" && \
    fail "unassigned address 10.9.9.9 accepted"
printf '%s' "$_out" | grep -q '不是本机已分配地址' || fail "missing reason for unassigned address"
_out="$("$API_MGR" apply 127.0.0.256 9161 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" 2>&1)" && \
    fail "malformed IPv4 accepted"
pass "接口 IP 通过、10.9.9.9 拒绝、inet6/掩码子串不误配"

# ---------------------------------------------------------------------------
echo "--> Test 4: 端口 deny-list 与范围..."
reset_files
cp "$MIHOMO_API_CONF" "$TMP_DIR/before.yaml"
for _p in 1023 1053 7890 7891 65536 0 abc; do
    if "$API_MGR" apply 127.0.0.1 "$_p" "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" >/dev/null 2>&1; then
        fail "port $_p must be rejected"
    fi
done
cmp -s "$MIHOMO_API_CONF" "$TMP_DIR/before.yaml" || fail "rejected ports modified config"
for _p in 1024 20573; do
    "$API_MGR" apply 127.0.0.1 "$_p" "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" >/dev/null || \
        fail "valid port $_p rejected"
done
pass "1023/1053/7890/7891/65536/0/abc 拒绝；1024/20573 通过"

# ---------------------------------------------------------------------------
echo "--> Test 5: secret 有效值门禁..."
reset_files
printf 'external-controller: 127.0.0.1:9090\nsecret: ""\n' > "$MIHOMO_API_CONF"
cp -f "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE"
_out="$("$API_MGR" apply 0.0.0.0 9171 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" 2>&1)" && \
    fail "non-loopback bind accepted with empty secret"
printf '%s' "$_out" | grep -q 'secret 为空' || fail "missing secret gate reason"
# 127.0.0.1 不受该门禁限制
"$API_MGR" apply 127.0.0.1 9171 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" >/dev/null || \
    fail "loopback bind must bypass secret gate"
# secret.key 有值 → 先同步四处再放行
printf 'external-controller: 127.0.0.1:9090\nsecret: ""\n' > "$MIHOMO_API_CONF"
cp -f "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE"
printf '%s' '0123456789abcdef0123456789abcdef' > "$MIHOMO_SECRET_FILE"
"$API_MGR" apply 0.0.0.0 9172 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" >/dev/null || \
    fail "secret.key sync path failed"
grep -q -F 'secret: "0123456789abcdef0123456789abcdef"' "$MIHOMO_API_CONF" || fail "config secret not synced"
grep -q -F 'secret: "0123456789abcdef0123456789abcdef"' "$MIHOMO_API_TEMPLATE" || fail "template secret not synced"
grep -q -x -F 'external-controller: 0.0.0.0:9172' "$MIHOMO_API_CONF" || fail "render after secret sync failed"
pass "空 secret 拒非回环、回环放行、secret.key 同步后放行"

# ---------------------------------------------------------------------------
echo "--> Test 6: 订阅锁复用（busy / 陈旧锁）..."
reset_files
mkdir -p "$MIHOMO_LOCK_DIR"
printf '%s\n' "$$" > "$MIHOMO_LOCK_DIR/pid"
_out="$(MIHOMO_API_LOCK_WAIT=0 "$API_MGR" apply 127.0.0.1 9173 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" 2>&1)" && \
    fail "apply must fail when lock is busy"
printf '%s' "$_out" | grep -q 'error: busy' || fail "busy did not report error: busy"
[ -d "$MIHOMO_LOCK_DIR" ] || fail "apply removed a live lock it does not own"
rm -rf "$MIHOMO_LOCK_DIR"
# 陈旧锁：持有者已死 → 自动清理并继续
sh -c 'exit 0' &
_dead_pid=$!
wait "$_dead_pid" 2>/dev/null || true
mkdir -p "$MIHOMO_LOCK_DIR"
printf '%s\n' "$_dead_pid" > "$MIHOMO_LOCK_DIR/pid"
MIHOMO_API_LOCK_WAIT=0 "$API_MGR" apply 127.0.0.1 9173 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" >/dev/null || \
    fail "stale lock not recovered"
[ -d "$MIHOMO_LOCK_DIR" ] && fail "lock not released after apply"
pass "busy -> error: busy / 陈旧锁自动清理 / 正常释放"

# ---------------------------------------------------------------------------
echo "--> Test 7: reconcile 语义（永不非 0）..."
reset_files
printf "MIHOMO_API_BIND='127.0.0.1'\nMIHOMO_API_PORT='9174'\n" > "$MIHOMO_PANEL_STATE_FILE"
"$API_MGR" reconcile >/dev/null || fail "reconcile failed on valid panel state"
grep -q -x -F 'external-controller: 127.0.0.1:9174' "$MIHOMO_API_CONF" || fail "reconcile did not converge config"
cp "$MIHOMO_API_CONF" "$TMP_DIR/before.yaml"
printf "MIHOMO_API_BIND='10.9.9.9'\nMIHOMO_API_PORT='9174'\n" > "$MIHOMO_PANEL_STATE_FILE"
"$API_MGR" reconcile >/dev/null || fail "reconcile must exit 0 on invalid bind"
cmp -s "$MIHOMO_API_CONF" "$TMP_DIR/before.yaml" || fail "failed reconcile modified config"
rm -f "$MIHOMO_PANEL_STATE_FILE"
_out="$("$API_MGR" reconcile)" || fail "reconcile must exit 0 without panel state"
printf '%s' "$_out" | grep -q '保持现状' || fail "reconcile without state should keep current config"
pass "有效状态收敛 / 非法状态 exit 0 / 无状态保持现状"

# ---------------------------------------------------------------------------
echo "--> Test 8a: reload 失败 -> 回滚..."
reset_files
export MIHOMO_API_PGREP="$TMP_DIR/running"
export MIHOMO_SERVICE_MANAGER="$TMP_DIR/svc-fail-once"
_out="$("$API_MGR" apply 0.0.0.0 9181 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" 2>&1)" && \
    fail "apply must fail when reload fails"
printf '%s' "$_out" | grep -q '已回滚为 127.0.0.1:9090' || fail "rollback summary missing: $_out"
grep -q -x -F 'external-controller: 127.0.0.1:9090' "$MIHOMO_API_CONF" || fail "config not rolled back"
grep -q -x -F 'external-controller: 127.0.0.1:9090' "$MIHOMO_API_TEMPLATE" || fail "template not rolled back"
find "$TMP_DIR" -name '*.api-bind.*.bak' | grep -q . && fail "backups kept after successful rollback"
pass "reload 失败 -> 恢复两文件 -> 回滚成功"

echo "--> Test 8b: 生效断言失败（负向/正向）-> 回滚..."
reset_files
export MIHOMO_SERVICE_MANAGER="$TMP_DIR/svc-always-ok"
export MIHOMO_API_ASSERT_TIMEOUT=1
_out="$("$API_MGR" apply 0.0.0.0 9182 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" 2>&1)" && \
    fail "apply must fail when assertion fails"
printf '%s' "$_out" | grep -q '生效断言失败' || fail "assertion failure reason missing: $_out"
printf '%s' "$_out" | grep -q '已回滚为 127.0.0.1:9090' || fail "rollback after assertion failure missing"
grep -q -x -F 'external-controller: 127.0.0.1:9090' "$MIHOMO_API_CONF" || fail "config not rolled back after assertion failure"
pass "断言失败 -> 回滚并复用双向断言"

echo "--> Test 8c: 回滚失败 -> 告警文件 + 手工指引..."
reset_files
export MIHOMO_SERVICE_MANAGER="$TMP_DIR/svc-always-fail"
_out="$("$API_MGR" apply 0.0.0.0 9183 "$MIHOMO_API_CONF" "$MIHOMO_API_TEMPLATE" 2>&1)" && \
    fail "apply must fail when rollback fails"
printf '%s' "$_out" | grep -q '自动回滚失败' || fail "rollback failure summary missing"
printf '%s' "$_out" | grep -q '手工恢复' || fail "manual recovery instruction missing"
[ -f "$MIHOMO_API_ALERT_FILE" ] || fail "alert file not written"
grep -q 'manual:' "$MIHOMO_API_ALERT_FILE" || fail "alert file missing manual instruction"
grep -q -x -F 'external-controller: 127.0.0.1:9090' "$MIHOMO_API_CONF" || fail "config not restored before alert"
pass "回滚失败 -> api-bind.alert + stdout 手工指引 + 文件恢复"

# ---------------------------------------------------------------------------
echo "--> Test 9: api_bind_manager --probe 归一化..."
reset_files
export MIHOMO_API_PGREP="$TMP_DIR/not-running"
printf 'external-controller: 0.0.0.0:9175\n' > "$TMP_DIR/probe.yaml"
[ "$("$API_MGR" --probe "$TMP_DIR/probe.yaml")" = "127.0.0.1 9175" ] || fail "probe did not normalize 0.0.0.0"
[ "$("$API_MGR" --probe "$TMP_DIR/missing.yaml" 2>/dev/null)" = "127.0.0.1 9090" ] || fail "probe fallback mismatch"
pass "0.0.0.0 -> 127.0.0.1；缺失 -> 默认回环"

# ---------------------------------------------------------------------------
echo "--> Test 10: system_status.py 解析与字段..."
python3 - "$STATUS_PY" "$TMP_DIR/status-conf.yaml" <<'PY' || fail "system_status.py parse/schema test failed"
import importlib.util
import json
import subprocess
import sys

sys.dont_write_bytecode = True

status_py, conf = sys.argv[1], sys.argv[2]
with open(conf, "w") as handle:
    handle.write("external-controller: 0.0.0.0:9188\nsecret: \"x\"\n")

spec = importlib.util.spec_from_file_location("mihomo_status", status_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.CONF_FILE = conf
host, port = mod.read_api_addr()
assert (host, port) == ("127.0.0.1", 9188), (host, port)

with open(conf, "w") as handle:
    handle.write("port: 7890\n")
host, port = mod.read_api_addr()
assert (host, port) == ("127.0.0.1", 9090), (host, port)

out = subprocess.run([sys.executable, status_py], stdout=subprocess.PIPE, check=True).stdout.decode()
data = json.loads(out)
assert "api_bind" in data and "api_port" in data, data
PY
pass "0.0.0.0 归一、缺失回退、JSON 含 api_bind/api_port"

# ---------------------------------------------------------------------------
echo "--> Test 11: 零连接字面量守卫..."
# 口径同任务书；work/ 是 gitignore 的构建产物，不属源码（已忽略）
_literal_hits="$(grep -rn "127.0.0.1:9090" "$ROOT_DIR/src" --include='*.sh' --include='*.py' 2>/dev/null | grep -v '/work/' || true)"
if [ -n "$_literal_hits" ]; then
    printf '%s\n' "$_literal_hits"
    fail "connection literal 127.0.0.1:9090 still present in src"
fi
pass "src/**/*.sh|py 无连接形态字面量"

# ---------------------------------------------------------------------------
echo "--> Test 12: §2.6 控制面/数据面解耦静态断言..."
SM_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/service_manager.sh"
WD_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/watchdog.sh"
grep -q 'keeping the service running' "$SM_SH" || fail "service_manager still kills service on API timeout"
if grep -q 'API failed to respond within' "$SM_SH"; then
    fail "service_manager still has the API-timeout fatal path"
fi
grep -q 'api_bind_manager' "$SM_SH" || fail "service_manager missing api-bind reconcile"
grep -q 'api_bind_manager' "$WD_SH" || fail "watchdog missing api-bind reconcile"
if grep -q 'trigger_failopen "Mihomo local API' "$WD_SH"; then
    fail "watchdog still fail-opens on API failure"
fi
grep -q 'port_listening 1053' "$WD_SH" || fail "watchdog data-plane DNS check removed"
pass "API 故障不再杀进程；数据面判据保留"

echo "===> api-bind tests PASSED!"
