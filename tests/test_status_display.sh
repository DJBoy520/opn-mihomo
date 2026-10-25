#!/bin/sh
set -eu

# os-mihomo 状态传输层与内核运行时模式显示语义测试
# 运行状态独立页已在 1.3.0 后下线，显示语义由常规设置页「概览」Tab 承载
# 从仓库根运行：sh tests/test_status_display.sh

echo "===> Running status display semantic tests..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

STATUS_PY="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/system_status.py"
STATUS_VOLT="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/status.volt"
INDEX_VOLT="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/index.volt"
PAGE_CTRL="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/StatusController.php"
STATUS_CTRL="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/StatusController.php"
SVC_MGR="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/service_manager.sh"

TMP_DIR="$(mktemp -d /tmp/test-status-display.XXXXXX)"
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

[ -f "$STATUS_PY" ] || fail "missing system_status.py"
[ -f "$INDEX_VOLT" ] || fail "missing index.volt"
[ -f "$STATUS_CTRL" ] || fail "missing Api/StatusController.php"
[ -f "$SVC_MGR" ] || fail "missing service_manager.sh"

# 运行状态独立页已下线：模板与页面级控制器都不应再存在
if [ -e "$STATUS_VOLT" ]; then
    fail "status.volt must be removed (运行状态已并入常规设置概览)"
fi
if [ -e "$PAGE_CTRL" ]; then
    fail "页面级 StatusController.php must be removed (菜单项已下线)"
fi
if grep -q '<Status VisibleName=' "$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/mvc/app/models/OPNsense/Mihomo/Menu/Menu.xml"; then
    fail "Menu.xml must not keep the 运行状态 entry"
fi

# ---------------------------------------------------------------------------
echo "--> Test 1: Python 编译测试（拷贝至 /tmp 编译，严禁在 src 树内跑 python）..."
cp -f "$STATUS_PY" "$TMP_DIR/system_status.py"
python3 -m py_compile "$TMP_DIR/system_status.py" || fail "system_status.py py_compile failed"
pass "system_status.py compiled clean in /tmp"

# ---------------------------------------------------------------------------
echo "--> Test 2: system_status.py 静态断言..."
# 常量断言
grep -q 'TRANSPORT_MODE_FILE = "/var/db/os-mihomo/transport-mode"' "$STATUS_PY" || \
    fail "system_status.py missing TRANSPORT_MODE_FILE constant"
grep -q 'HEV_TUN_DEVICE = "tun0"' "$STATUS_PY" || \
    fail "system_status.py missing HEV_TUN_DEVICE constant"

# tun0 与 UP+RUNNING 探测逻辑断言
grep -q 'HEV_TUN_DEVICE' "$STATUS_PY" || fail "system_status.py does not reference HEV_TUN_DEVICE"
grep -q 'UP' "$STATUS_PY" && grep -q 'RUNNING' "$STATUS_PY" || \
    fail "system_status.py missing UP + RUNNING check logic"
grep -q 'transport_mode' "$STATUS_PY" || fail "system_status.py missing transport_mode in output"
grep -q 'tun_kind' "$STATUS_PY" || fail "system_status.py missing tun_kind in output"

pass "system_status.py contains TRANSPORT_MODE_FILE, HEV_TUN_DEVICE, UP+RUNNING logic, and new schema fields"

# ---------------------------------------------------------------------------
echo "--> Test 3: 概览 Tab（index.volt）显示语义断言..."
# 接入方式徽章：透明代理 / 仅代理 / 直连 三分支
grep -q 'data\.transport_mode === .transparent.' "$INDEX_VOLT" || \
    fail "index.volt missing data.transport_mode === 'transparent' branch"
grep -q '透明代理' "$INDEX_VOLT" || \
    fail "index.volt missing 透明代理 badge"
grep -q '仅代理' "$INDEX_VOLT" || \
    fail "index.volt missing 仅代理 badge"
grep -q '直连' "$INDEX_VOLT" || \
    fail "index.volt missing 直连 badge"

# TUN 三态：UP / DOWN / SOCKS（SOCKS 走 label-default，不得标红）
grep -q "data\.tun_status === 'UP'" "$INDEX_VOLT" || \
    fail "index.volt missing data.tun_status === 'UP' check"
grep -q "data\.tun_status === 'DOWN'" "$INDEX_VOLT" || \
    fail "index.volt missing data.tun_status === 'DOWN' check"
grep -q "other: { text: 'SOCKS', cls: 'label-default' }" "$INDEX_VOLT" || \
    fail "index.volt SOCKS branch must use label-default"
grep -q "id=\"ov_tun\"" "$INDEX_VOLT" || fail "index.volt missing #ov_tun"
grep -q "id=\"ov_api\"" "$INDEX_VOLT" || fail "index.volt missing #ov_api"

# 服务未运行不得沿用 danger 语义显示 SOCKS 模式
if grep -q "核心生命周期" "$INDEX_VOLT"; then
    fail "index.volt must not contain '核心生命周期' subtitle (R1)"
fi

# 内核模式运行时控件（原状态页能力并入概览）
grep -q 'id="ov_core_mode_select"' "$INDEX_VOLT" || fail "index.volt missing #ov_core_mode_select"
grep -q 'id="btn_core_mode_apply"' "$INDEX_VOLT" || fail "index.volt missing #btn_core_mode_apply"
grep -q 'id="core_mode_msg"' "$INDEX_VOLT" || fail "index.volt missing #core_mode_msg"
grep -q 'id="core_mode_config"' "$INDEX_VOLT" || fail "index.volt missing #core_mode_config"
grep -q '配置默认' "$INDEX_VOLT" || fail "index.volt missing '配置默认' label"
grep -q '内核模式' "$INDEX_VOLT" || fail "index.volt missing '内核模式' label"

# 运行指标（吸收原运行状态页 KPI）
for id in ov_uptime ov_memory ov_pid ov_versions; do
    grep -q "id=\"$id\"" "$INDEX_VOLT" || fail "index.volt missing #$id"
done

# 轮询逻辑断言（5000ms 且包含 getMode 与 getMihomoStatus）
grep -q '5000' "$INDEX_VOLT" || fail "index.volt missing 5000ms polling interval"
grep -q 'getMihomoStatus' "$INDEX_VOLT" || fail "index.volt missing getMihomoStatus call"
grep -q 'getMode' "$INDEX_VOLT" || fail "index.volt missing getMode call"
grep -q 'setMode' "$INDEX_VOLT" || fail "index.volt missing setMode call"

pass "index.volt 概览承载接入方式、TUN/API 徽章、内核模式运行时切换与运行指标"

# ---------------------------------------------------------------------------
echo "--> Test 4: StatusController.php 静态契约断言..."
grep -q 'function getModeAction' "$STATUS_CTRL" || fail "StatusController.php missing getModeAction"
grep -q 'function setModeAction' "$STATUS_CTRL" || fail "StatusController.php missing setModeAction"
grep -q 'PATCH' "$STATUS_CTRL" || fail "StatusController.php must use PATCH for setMode"
grep -q '204' "$STATUS_CTRL" || fail "StatusController.php must treat HTTP 204 as success"
grep -q -- '-K' "$STATUS_CTRL" || fail "StatusController.php must use curl -K for secret"
grep -q 'tempnam' "$STATUS_CTRL" || fail "StatusController.php must use tempnam"
grep -q '0600' "$STATUS_CTRL" || fail "StatusController.php must chmod 0600 for curl config"
grep -q 'finally' "$STATUS_CTRL" || fail "StatusController.php must use finally to clean up secret file"

# 流式读取断言
grep -q 'fopen' "$STATUS_CTRL" || fail "StatusController.php must use fopen"
grep -q 'fgets' "$STATUS_CTRL" || fail "StatusController.php must use fgets"
if grep -E '([^a-zA-Z0-9_]file|^file)\(|file_get_contents\(' "$STATUS_CTRL"; then
    fail "StatusController.php must not use file() or file_get_contents()"
fi
if grep -q "'1\.0\.9'" "$STATUS_CTRL"; then
    fail "StatusController.php must not hardcode '1.0.9'"
fi
grep -q 'UNKNOWN' "$STATUS_CTRL" || fail "StatusController.php RUNNING default mode must be UNKNOWN"

pass "StatusController.php satisfies streaming, secret safety, PATCH, and 200/204 contract"

# ---------------------------------------------------------------------------
echo "--> Test 5: service_manager.sh 状态模式写入断言..."
if grep -E 'set_state "(RUNNING|DEGRADED)" "PROXY"' "$SVC_MGR"; then
    fail "service_manager.sh must not hardcode PROXY in set_state RUNNING/DEGRADED"
fi
grep -q 'TRANSPARENT' "$SVC_MGR" || fail "service_manager.sh missing TRANSPARENT branch"
grep -q '# Modes: PROXY, TRANSPARENT, DIRECT' "$SVC_MGR" || fail "service_manager.sh Modes comment not updated"
pass "service_manager.sh correctly uses transport_mode_now for RUNNING/DEGRADED and supports TRANSPARENT"

# ---------------------------------------------------------------------------
echo "--> Test 6: 零硬编码守卫（相关文件均无 :9090）..."
for f in "$STATUS_PY" "$INDEX_VOLT" "$STATUS_CTRL"; do
    if grep -q ":9090" "$f"; then
        fail "$f contains literal :9090"
    fi
done
pass "Status display related files have zero :9090 literals"

# ---------------------------------------------------------------------------
echo "--> Test 7: PATH mock ifconfig 与三态行为断言..."
MOCK_BIN="$TMP_DIR/mock_bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/ifconfig" <<'EOF'
#!/bin/sh
dev="$1"
case "$dev" in
    tun_mihomo)
        if [ "${MOCK_TUN_MIHOMO:-down}" = "up" ]; then
            echo "tun_mihomo: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500"
            exit 0
        else
            exit 1
        fi
        ;;
    tun0)
        flags="${MOCK_TUN0_FLAGS:-UP,POINTOPOINT,RUNNING,MULTICAST}"
        if [ "${MOCK_TUN0_EXISTS:-yes}" = "yes" ]; then
            echo "tun0: flags=8051<${flags}> mtu 1500"
            exit 0
        else
            echo "ifconfig: interface tun0 does not exist" >&2
            exit 1
        fi
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$MOCK_BIN/ifconfig"

cat > "$MOCK_BIN/sockstat" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_BIN/sockstat"

# 准备测试驱动脚本并在 /tmp 执行
cat > "$TMP_DIR/runner.py" <<'PY'
import importlib.util
import json
import sys

sys.dont_write_bytecode = True

status_py = sys.argv[1]
spec = importlib.util.spec_from_file_location("status_mod", status_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mode = sys.argv[2]
conf_path = sys.argv[3]
mode_file = sys.argv[4]

mod.CONF_FILE = conf_path
mod.TRANSPORT_MODE_FILE = mode_file

data = mod.collect()
print(json.dumps(data))
PY

TEST_CONF="$TMP_DIR/config.yaml"
TEST_MODE_FILE="$TMP_DIR/transport-mode"

# 场景 1: mihomo自带 tun.enable: true -> tun_kind="mihomo-tun", tun_status 取决于 tun_up()
printf 'tun:\n  enable: true\n' > "$TEST_CONF"
printf 'transparent\n' > "$TEST_MODE_FILE"

OUT1="$(PATH="$MOCK_BIN:$PATH" MOCK_TUN_MIHOMO=up python3 "$TMP_DIR/runner.py" "$STATUS_PY" "case1" "$TEST_CONF" "$TEST_MODE_FILE")"
echo "$OUT1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["tun_status"] == "UP", d
assert d["tun_kind"] == "mihomo-tun", d
assert d["transport_mode"] == "transparent", d
' || fail "Scene 1a (mihomo-tun UP) failed: $OUT1"

OUT1_DOWN="$(PATH="$MOCK_BIN:$PATH" MOCK_TUN_MIHOMO=down python3 "$TMP_DIR/runner.py" "$STATUS_PY" "case1_down" "$TEST_CONF" "$TEST_MODE_FILE")"
echo "$OUT1_DOWN" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["tun_status"] == "DOWN", d
assert d["tun_kind"] == "mihomo-tun", d
' || fail "Scene 1b (mihomo-tun DOWN) failed: $OUT1_DOWN"
pass "Scene 1: mihomo config tun: enable=true -> mihomo-tun (UP/DOWN)"

# 场景 2: mihomo tun false, transport_mode="transparent" -> tun_kind="hev-tun", 探测 tun0
printf 'tun:\n  enable: false\n' > "$TEST_CONF"
printf 'transparent\n' > "$TEST_MODE_FILE"

# 2a: tun0 具备 UP + RUNNING
OUT2_UP="$(PATH="$MOCK_BIN:$PATH" MOCK_TUN0_EXISTS=yes MOCK_TUN0_FLAGS="UP,POINTOPOINT,RUNNING,MULTICAST" python3 "$TMP_DIR/runner.py" "$STATUS_PY" "case2_up" "$TEST_CONF" "$TEST_MODE_FILE")"
echo "$OUT2_UP" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["tun_status"] == "UP", d
assert d["tun_kind"] == "hev-tun", d
assert d["transport_mode"] == "transparent", d
' || fail "Scene 2a (hev-tun UP+RUNNING) failed: $OUT2_UP"

# 2b: tun0 仅有 UP 缺 RUNNING
OUT2_NO_RUNNING="$(PATH="$MOCK_BIN:$PATH" MOCK_TUN0_EXISTS=yes MOCK_TUN0_FLAGS="UP,POINTOPOINT,MULTICAST" python3 "$TMP_DIR/runner.py" "$STATUS_PY" "case2_no_running" "$TEST_CONF" "$TEST_MODE_FILE")"
echo "$OUT2_NO_RUNNING" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["tun_status"] == "DOWN", d
assert d["tun_kind"] == "hev-tun", d
' || fail "Scene 2b (hev-tun UP but not RUNNING) failed: $OUT2_NO_RUNNING"

# 2c: tun0 不存在
OUT2_NO_DEV="$(PATH="$MOCK_BIN:$PATH" MOCK_TUN0_EXISTS=no python3 "$TMP_DIR/runner.py" "$STATUS_PY" "case2_no_dev" "$TEST_CONF" "$TEST_MODE_FILE")"
echo "$OUT2_NO_DEV" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["tun_status"] == "DOWN", d
assert d["tun_kind"] == "hev-tun", d
' || fail "Scene 2c (hev-tun no device) failed: $OUT2_NO_DEV"
pass "Scene 2: transport_mode=transparent -> hev-tun (UP requires both UP and RUNNING)"

# 场景 3: transport_mode != "transparent" (proxy / 缺失 / 垃圾值) -> tun_status="SOCKS", tun_kind="none"
printf 'tun:\n  enable: false\n' > "$TEST_CONF"
printf 'proxy\n' > "$TEST_MODE_FILE"

OUT3_PROXY="$(PATH="$MOCK_BIN:$PATH" python3 "$TMP_DIR/runner.py" "$STATUS_PY" "case3_proxy" "$TEST_CONF" "$TEST_MODE_FILE")"
echo "$OUT3_PROXY" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["tun_status"] == "SOCKS", d
assert d["tun_kind"] == "none", d
assert d["transport_mode"] == "proxy", d
' || fail "Scene 3a (proxy) failed: $OUT3_PROXY"

printf 'invalid_garbage_mode\n' > "$TEST_MODE_FILE"
OUT3_GARBAGE="$(PATH="$MOCK_BIN:$PATH" python3 "$TMP_DIR/runner.py" "$STATUS_PY" "case3_garbage" "$TEST_CONF" "$TEST_MODE_FILE")"
echo "$OUT3_GARBAGE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["tun_status"] == "SOCKS", d
assert d["tun_kind"] == "none", d
assert d["transport_mode"] == "proxy", d
' || fail "Scene 3b (garbage value -> proxy) failed: $OUT3_GARBAGE"

rm -f "$TEST_MODE_FILE"
OUT3_MISSING="$(PATH="$MOCK_BIN:$PATH" python3 "$TMP_DIR/runner.py" "$STATUS_PY" "case3_missing" "$TEST_CONF" "$TEST_MODE_FILE")"
echo "$OUT3_MISSING" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["tun_status"] == "SOCKS", d
assert d["tun_kind"] == "none", d
assert d["transport_mode"] == "proxy", d
' || fail "Scene 3c (missing file -> proxy) failed: $OUT3_MISSING"
pass "Scene 3: non-transparent / missing / garbage -> tun_status=SOCKS, tun_kind=none, transport_mode=proxy"

# ---------------------------------------------------------------------------
echo "--> Test 8: 契约检验（单行 JSON、异常输出 {}、退出码 0）..."
OUT_EXEC="$(python3 -c '
import subprocess, sys
res = subprocess.run([sys.executable, sys.argv[1]], stdout=subprocess.PIPE, check=True)
sys.stdout.write(res.stdout.decode())
' "$STATUS_PY")"
[ "$(printf '%s\n' "$OUT_EXEC" | wc -l | tr -d ' ')" -eq 1 ] || fail "system_status.py output is not a single line"
echo "$OUT_EXEC" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert isinstance(d, dict), "Not a dict"
' || fail "system_status.py did not emit valid JSON dict"
pass "system_status.py single line JSON and exit 0 contract verified"

echo "===> status display semantic tests PASSED!"
