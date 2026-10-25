#!/bin/sh
set -eu

echo "===> Running Secret Manager tests..."

TMP_TEST_DIR="$(mktemp -d /tmp/test-secret.XXXXXX)"
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

SECRET_MGR="src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/secret_manager.sh"

export MIHOMO_SECRET_FILE="$TMP_TEST_DIR/secret.key"
export MIHOMO_CONFIG_FILE="$TMP_TEST_DIR/config.yaml"
export MIHOMO_TEMPLATE_FILE="$TMP_TEST_DIR/template_config.yaml"
export MIHOMO_ENV_FILE="$TMP_TEST_DIR/env"
# 与 sub.sh 同一把锁的路径变量，测试用临时目录避免碰 /var/run
export MIHOMO_LOCK_DIR="$TMP_TEST_DIR/sub.lock"

echo "secret: \"\"" > "$MIHOMO_CONFIG_FILE"
# env 与生产一致：+POST_INSTALL 保证存在（sample 兜底）
printf "mihomo_URL='https://bing.com'\nmihomo_secret=''\n" > "$MIHOMO_ENV_FILE"

# Test 1: Generate high-entropy secret
echo "--> Test 1: Generating secret..."
sh -n "$SECRET_MGR" || { echo "FAIL: secret_manager syntax error"; exit 1; }
SECRET_OUT="$(sh "$SECRET_MGR" generate)"
if [ -d "$MIHOMO_LOCK_DIR" ]; then
    echo "FAIL: lock dir not released after generate"; exit 1
fi
echo "  [PASS] Generation output: $SECRET_OUT"

# Test 2: Masking logic
echo "--> Test 2: Checking masked display..."
MASKED="$(sh "$SECRET_MGR" masked)"
echo "  [PASS] Masked output: $MASKED"

# Test 3: Set custom secret via b64 (the configd-safe transport)
echo "--> Test 3: Setting custom secret (b64)..."
CUSTOM_SECRET="my-Secret.~#%+=:;!?,*-_@^42"
B64_PAYLOAD="b64:$(printf '%s' "$CUSTOM_SECRET" | base64)"
SET_OUT="$(sh "$SECRET_MGR" set "$B64_PAYLOAD")"
case "$SET_OUT" in
    OK*) echo "  [PASS] Set output: $SET_OUT" ;;
    *) echo "FAIL: set did not return OK: $SET_OUT"; exit 1 ;;
esac
STORED="$(cat "$MIHOMO_SECRET_FILE")"
if [ "$STORED" != "$CUSTOM_SECRET" ]; then
    echo "FAIL: secret.key mismatch: $STORED"; exit 1
fi
echo "  [PASS] secret.key matches input"
if ! grep -qF "secret: \"$CUSTOM_SECRET\"" "$MIHOMO_CONFIG_FILE"; then
    echo "FAIL: config.yaml secret not updated"; exit 1
fi
printf 'secret: ""\n' > "$MIHOMO_TEMPLATE_FILE"
SET_OUT="$(sh "$SECRET_MGR" set "$B64_PAYLOAD")"
if ! grep -qF "secret: \"$CUSTOM_SECRET\"" "$MIHOMO_TEMPLATE_FILE"; then
    echo "FAIL: template secret not updated"; exit 1
fi
if ! grep -qF "mihomo_secret='$CUSTOM_SECRET'" "$MIHOMO_ENV_FILE"; then
    echo "FAIL: env secret not updated"; exit 1
fi
echo "  [PASS] config.yaml / template / env all synced"

# Test 4: rejection cases
echo "--> Test 4: Rejection cases..."
if sh "$SECRET_MGR" set "$CUSTOM_SECRET" >/dev/null 2>&1; then
    echo "FAIL: plain (non-b64) argument must be rejected"; exit 1
fi
echo "  [PASS] plain argument rejected"
SHORT_B64="b64:$(printf '%s' 'abc' | base64)"
if sh "$SECRET_MGR" set "$SHORT_B64" >/dev/null 2>&1; then
    echo "FAIL: too-short secret must be rejected"; exit 1
fi
echo "  [PASS] too-short secret rejected"
DANGEROUS_B64="b64:$(printf '%s' 'safe$(dangerous)' | base64)"
if sh "$SECRET_MGR" set "$DANGEROUS_B64" >/dev/null 2>&1; then
    echo "FAIL: shell-metachar secret must be rejected"; exit 1
fi
if sh "$SECRET_MGR" set "b64:%$" >/dev/null 2>&1; then
    echo "FAIL: invalid base64 must be rejected"; exit 1
fi
echo "  [PASS] metachar/invalid-b64 rejected (secret.key untouched)"
if [ "$(cat "$MIHOMO_SECRET_FILE")" != "$CUSTOM_SECRET" ]; then
    echo "FAIL: rejected attempts must not modify secret.key"; exit 1
fi

# Test 5: env 缺失 mihomo_secret 行时自动补写（历史 env 可能没有该行）
echo "--> Test 5: missing env line is appended..."
grep -v "^mihomo_secret=" "$MIHOMO_ENV_FILE" > "$MIHOMO_ENV_FILE.tmp" || true
mv "$MIHOMO_ENV_FILE.tmp" "$MIHOMO_ENV_FILE"
grep -q "^mihomo_secret=" "$MIHOMO_ENV_FILE" && { echo "FAIL: setup did not remove the line"; exit 1; }
SET_OUT="$(sh "$SECRET_MGR" set "$B64_PAYLOAD")"
case "$SET_OUT" in
    OK*) : ;;
    *) echo "FAIL: set after env-line removal: $SET_OUT"; exit 1 ;;
esac
if ! grep -qF "mihomo_secret='$CUSTOM_SECRET'" "$MIHOMO_ENV_FILE"; then
    echo "FAIL: mihomo_secret line not appended"; exit 1
fi
echo "  [PASS] mihomo_secret line appended to env"

# Test 6: 文件末尾无换行时，set 追加补写不得与上一行拼接（M3）
echo "--> Test 6: set on files without trailing newline..."
SECRET_6="trailing-newline-check-0123456789ab"
B64_6="b64:$(printf '%s' "$SECRET_6" | base64)"
printf 'port: 9090\nexternal-controller: 127.0.0.1:9090' > "$MIHOMO_CONFIG_FILE"
printf "mihomo_URL='https://bing.com'" > "$MIHOMO_ENV_FILE"
SET_OUT="$(sh "$SECRET_MGR" set "$B64_6")"
case "$SET_OUT" in
    OK*) : ;;
    *) echo "FAIL: set on newline-less files: $SET_OUT"; exit 1 ;;
esac
if ! grep -qxF 'external-controller: 127.0.0.1:9090' "$MIHOMO_CONFIG_FILE"; then
    echo "FAIL: config.yaml last line was merged with the appended secret"; exit 1
fi
if ! grep -qF "secret: \"$SECRET_6\"" "$MIHOMO_CONFIG_FILE"; then
    echo "FAIL: secret not appended to config.yaml"; exit 1
fi
if ! grep -qxF "mihomo_URL='https://bing.com'" "$MIHOMO_ENV_FILE"; then
    echo "FAIL: env last line was merged with the appended secret"; exit 1
fi
if ! grep -qF "mihomo_secret='$SECRET_6'" "$MIHOMO_ENV_FILE"; then
    echo "FAIL: secret not appended to env"; exit 1
fi
echo "  [PASS] newline-less files keep structure and receive secret"

# Test 7: 短密钥脱敏不得泄露前缀；长度 >=32 才显示前 4 字符（M5）
echo "--> Test 7: masked output for short/long secrets..."
SHORT_SECRET="short-secret-1234"
sh "$SECRET_MGR" set "b64:$(printf '%s' "$SHORT_SECRET" | base64)" >/dev/null
MASKED_SHORT="$(sh "$SECRET_MGR" masked)"
EXPECT_ALL_STARS="$(printf '%40s' '' | tr ' ' '*')"
if [ "$MASKED_SHORT" != "$EXPECT_ALL_STARS" ]; then
    echo "FAIL: short secret masked output must be 40 stars only: $MASKED_SHORT"; exit 1
fi
case "$MASKED_SHORT" in
    *shor*) echo "FAIL: masked output leaks short-secret prefix"; exit 1 ;;
esac
LONG_SECRET="0123456789abcdef0123456789abcdef"
sh "$SECRET_MGR" set "b64:$(printf '%s' "$LONG_SECRET" | base64)" >/dev/null
MASKED_LONG="$(sh "$SECRET_MGR" masked)"
EXPECT_PREFIXED="0123$(printf '%36s' '' | tr ' ' '*')"
if [ "$MASKED_LONG" != "$EXPECT_PREFIXED" ]; then
    echo "FAIL: 32-char secret masked output wrong: $MASKED_LONG"; exit 1
fi
echo "  [PASS] short secret fully masked, long secret shows 4-char prefix"

# Test 8: config.yaml 行内注释时 get/masked 提取纯密钥（M4）
echo "--> Test 8: config fallback extraction with inline comment..."
rm -f "$MIHOMO_SECRET_FILE"
printf 'secret: "cmtkey123" # inline comment\n' > "$MIHOMO_CONFIG_FILE"
GOT_SECRET="$(sh "$SECRET_MGR" get)"
if [ "$GOT_SECRET" != "cmtkey123" ]; then
    echo "FAIL: inline comment leaked into extracted secret: $GOT_SECRET"; exit 1
fi
MASKED_CMT="$(sh "$SECRET_MGR" masked)"
if [ "$MASKED_CMT" != "$EXPECT_ALL_STARS" ]; then
    echo "FAIL: masked from commented config line wrong: $MASKED_CMT"; exit 1
fi
echo "  [PASS] inline comment stripped by get and masked"

# Test 9: 写操作占用/释放与 sub.sh 同一把锁，陈旧锁可自动清理（M1）
echo "--> Test 9: subscription lock acquire/release..."
sh "$SECRET_MGR" set "$B64_6" >/dev/null
if [ -d "$MIHOMO_LOCK_DIR" ]; then
    echo "FAIL: lock dir not released after set"; exit 1
fi
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
mkdir -p "$MIHOMO_LOCK_DIR"
printf '%s\n' "$DEAD_PID" > "$MIHOMO_LOCK_DIR/pid"
SET_OUT="$(sh "$SECRET_MGR" set "$B64_6")"
case "$SET_OUT" in
    OK*) : ;;
    *) echo "FAIL: set did not recover from stale lock: $SET_OUT"; exit 1 ;;
esac
if [ -d "$MIHOMO_LOCK_DIR" ]; then
    echo "FAIL: lock dir not released after stale-lock recovery"; exit 1
fi
# 只读命令不参与加锁：锁被活进程持有时也应立即返回且不破坏锁
mkdir -p "$MIHOMO_LOCK_DIR"
printf '%s\n' "$$" > "$MIHOMO_LOCK_DIR/pid"
READ_START="$(date +%s)"
MASKED_READONLY="$(sh "$SECRET_MGR" masked)"
READ_ELAPSED=$(( $(date +%s) - READ_START ))
rm -rf "$MIHOMO_LOCK_DIR"
if [ "$READ_ELAPSED" -gt 2 ]; then
    echo "FAIL: read-only masked waited on the subscription lock"; exit 1
fi
if [ -z "$MASKED_READONLY" ] || [ "$MASKED_READONLY" = "NOT_CONFIGURED" ]; then
    echo "FAIL: masked returned no value while lock was held"; exit 1
fi
echo "  [PASS] lock acquired, released, stale lock recovered, read-only path unlocked"

# Test 10: 安装初始化轮换策略——16 字符、[A-Za-z0-9]、必含大写/小写/数字
echo "--> Test 10: generated secret policy (16 chars, upper+lower+digit)..."
# 禁止对无限源 /dev/urandom 直接重定向后流式截断（BSD tr locale 陷阱 + pkg
# 环境下挂死 pipe_read，均 2026-10-24 VM 实锤）；必须先 head -c 有限读取
if grep -E "tr -dc .*< */dev/urandom" "$SECRET_MGR" | grep -q .; then
    echo "FAIL: unbounded /dev/urandom redirect into tr (hang class); use head -c first"; exit 1
fi
grep -q "head -c 128 /dev/urandom" "$SECRET_MGR" || { echo "FAIL: finite urandom read missing"; exit 1; }
i=0
while [ "$i" -lt 10 ]; do
    sh "$SECRET_MGR" generate > /dev/null
    GEN="$(cat "$MIHOMO_SECRET_FILE")"
    [ "${#GEN}" -eq 16 ] || { echo "FAIL: generated length ${#GEN} != 16: $GEN"; exit 1; }
    _residue="$(printf '%s' "$GEN" | tr -d 'A-Za-z0-9')"
    [ -z "$_residue" ] || { echo "FAIL: charset outside [A-Za-z0-9]: $GEN"; exit 1; }
    printf '%s' "$GEN" | grep -q '[A-Z]' || { echo "FAIL: missing uppercase: $GEN"; exit 1; }
    printf '%s' "$GEN" | grep -q '[a-z]' || { echo "FAIL: missing lowercase: $GEN"; exit 1; }
    printf '%s' "$GEN" | grep -q '[0-9]' || { echo "FAIL: missing digit: $GEN"; exit 1; }
    i=$((i + 1))
done
echo "  [PASS] 10/10 generations meet 16-char upper+lower+digit policy"

# Test 11: 轮换联动 authentication 块（SOCKS 凭证与 API secret 同值，用户名保留）
echo "--> Test 11: rotation syncs authentication block password..."
cat > "$MIHOMO_CONFIG_FILE" <<'EOF'
socks-port: 7891
allow-lan: true
authentication:
  - "mihomo:oldpass"
  - "admin:oldpass"
  - "svc"
external-controller: 0.0.0.0:9090
secret: "oldpass"
mode: rule
EOF
LINE_BEFORE=$(grep -c "" "$MIHOMO_CONFIG_FILE")
sh "$SECRET_MGR" generate > /dev/null
GEN11="$(cat "$MIHOMO_SECRET_FILE")"
grep -qF "secret: \"$GEN11\"" "$MIHOMO_CONFIG_FILE" || { echo "FAIL: secret line not rotated"; exit 1; }
grep -qF '  - "mihomo:'"$GEN11"'"' "$MIHOMO_CONFIG_FILE" || { echo "FAIL: mihomo entry not rotated"; exit 1; }
grep -qF '  - "admin:'"$GEN11"'"' "$MIHOMO_CONFIG_FILE" || { echo "FAIL: admin entry username lost"; exit 1; }
grep -qF '  - "svc:'"$GEN11"'"' "$MIHOMO_CONFIG_FILE" || { echo "FAIL: colon-less entry not given user:pass"; exit 1; }
grep -qF '"mihomo:oldpass"' "$MIHOMO_CONFIG_FILE" && { echo "FAIL: stale password left behind"; exit 1; }
grep -qF 'allow-lan: true' "$MIHOMO_CONFIG_FILE" || { echo "FAIL: non-auth lines damaged"; exit 1; }
grep -qxF 'mode: rule' "$MIHOMO_CONFIG_FILE" || { echo "FAIL: block-end line damaged"; exit 1; }
LINE_AFTER=$(grep -c "" "$MIHOMO_CONFIG_FILE")
[ "$LINE_BEFORE" -eq "$LINE_AFTER" ] || { echo "FAIL: line count changed $LINE_BEFORE -> $LINE_AFTER"; exit 1; }
# 无 authentication 块的配置轮换必须零改动
printf 'socks-port: 7891\nsecret: "x"\n' > "$MIHOMO_CONFIG_FILE"
sh "$SECRET_MGR" set "b64:$(printf '%s' "$GEN11" | base64)" > /dev/null
grep -qxF 'socks-port: 7891' "$MIHOMO_CONFIG_FILE" || { echo "FAIL: no-auth config damaged by rotation"; exit 1; }
echo "  [PASS] authentication entries rewritten in place, non-auth content intact"

echo "===> Secret Manager tests PASSED 100%!"
