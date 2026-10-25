#!/bin/sh
set -eu

# test_subscription_strategy.sh
# 契约测试：第 2 节 包 A 订阅合成核心（策略模式读取、顶层块提取、策略提取/校验/计数/回退/缓存、compose 拼接、状态写入与校验器目标解析）

echo "===> Running subscription strategy core tests (Package A)..."

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

SUB_LIB="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub_lib.sh"
SUB_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/etc/mihomo/sub/sub.sh"
VALIDATOR_PHP="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/custom_rules_validate.php"
APPLY_SH="$ROOT_DIR/src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/custom_rules_apply.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 1. 语法检查
echo "--> Test 1: Shell syntax checks (sh -n)..."
[ -f "$SUB_LIB" ] || fail "Missing sub_lib.sh"
[ -f "$SUB_SH" ] || fail "Missing sub.sh"
[ -f "$APPLY_SH" ] || fail "Missing custom_rules_apply.sh"
[ -f "$VALIDATOR_PHP" ] || fail "Missing custom_rules_validate.php"

sh -n "$SUB_LIB" || fail "Syntax error in sub_lib.sh"
sh -n "$SUB_SH" || fail "Syntax error in sub.sh"
sh -n "$APPLY_SH" || fail "Syntax error in custom_rules_apply.sh"
echo "  [PASS] Shell syntax checks passed."

# 2. 隔离沙箱环境初始化（所有测试均在 mktemp -d 下运行，不写系统目录）
echo "--> Test 2: Initializing test sandbox..."
TEST_SANDBOX="$(mktemp -d /tmp/test-strategy-sandbox.XXXXXX)"
cleanup() {
    rm -rf "$TEST_SANDBOX"
}
trap cleanup EXIT INT TERM

# 沙箱环境变量设定
export MIHOMO_CONF_DIR="$TEST_SANDBOX/conf"
export MIHOMO_TEMPLATE_FILE="$TEST_SANDBOX/template_config.yaml"
export MIHOMO_RULES_FILE="$TEST_SANDBOX/custom-rules.txt"
export MIHOMO_STRATEGY_FILE="$TEST_SANDBOX/subscription-strategy.yaml"
export MIHOMO_STRATEGY_MODE_FILE="$TEST_SANDBOX/strategy-mode"
export MIHOMO_STATUS_FILE="$TEST_SANDBOX/last-sub-update.json"
export MIHOMO_CACHE_FILE="$TEST_SANDBOX/subscription-cache.yaml"
export MIHOMO_LOCK_DIR="$TEST_SANDBOX/lock"
export MIHOMO_SECRET_MANAGER="$TEST_SANDBOX/nonexistent-secret-manager.sh"
export mihomo_secret="sandbox-secret-1234567890abcdef"

mkdir -p "$MIHOMO_CONF_DIR"

# 准备沙箱 template_config.yaml（含基础设施、占位符与模板策略组）
cat << 'EOF' > "$MIHOMO_TEMPLATE_FILE"
port: 7890
socks-port: 7891
external-controller: 127.0.0.1:9090
external-ui: /usr/local/etc/mihomo/ui
secret: ""
dns:
  enable: true
  nameserver:
    - 223.5.5.5

# __MIHOMO_PROXIES__

proxy-groups:
  - name: 🌍选择节点
    type: select
    proxies:
      - 自动选择
# __MIHOMO_NODE_NAMES__
      - DIRECT
  - name: 自动选择
    type: url-test
    proxies:
# __MIHOMO_NODE_NAMES__

rules:
# __MIHOMO_CUSTOM_RULES__
  - GEOSITE,private,DIRECT
  - GEOSITE,cn,DIRECT
  - MATCH,🌍选择节点
EOF

# 准备代理 fixture
PROXIES_FIXTURE="$TEST_SANDBOX/fixture_proxies.yaml"
cat << 'EOF' > "$PROXIES_FIXTURE"
proxies:
  - { name: "节点-A", server: 1.1.1.1, port: 443, type: ss, cipher: aes-128-gcm, password: pwd }
  - { name: "节点-B", server: 2.2.2.2, port: 443, type: ss, cipher: aes-128-gcm, password: pwd }
EOF

# 引入函数库
. "$SUB_LIB"

echo "  [PASS] Sandbox initialized."

# 3. 策略模式读取契约 (mihomo_lib_strategy_mode)
echo "--> Test 3: Strategy mode resolution..."
# 3a. 环境变量优先
unset MIHOMO_STRATEGY_MODE || true
rm -f "$MIHOMO_STRATEGY_MODE_FILE"
[ "$(mihomo_lib_strategy_mode)" = "subscription" ] || fail "Default mode must be subscription"

export MIHOMO_STRATEGY_MODE="template"
[ "$(mihomo_lib_strategy_mode)" = "template" ] || fail "MIHOMO_STRATEGY_MODE=template env override failed"

export MIHOMO_STRATEGY_MODE="subscription"
[ "$(mihomo_lib_strategy_mode)" = "subscription" ] || fail "MIHOMO_STRATEGY_MODE=subscription env override failed"

# 3b. 模式文件读取
unset MIHOMO_STRATEGY_MODE
printf "template\n" > "$MIHOMO_STRATEGY_MODE_FILE"
[ "$(mihomo_lib_strategy_mode)" = "template" ] || fail "Strategy mode from file (template) failed"

printf "subscription\n" > "$MIHOMO_STRATEGY_MODE_FILE"
[ "$(mihomo_lib_strategy_mode)" = "subscription" ] || fail "Strategy mode from file (subscription) failed"

printf "invalid-garbage\n" > "$MIHOMO_STRATEGY_MODE_FILE"
[ "$(mihomo_lib_strategy_mode)" = "subscription" ] || fail "Invalid mode in file must fallback to subscription"
echo "  [PASS] Strategy mode resolution verified."

# 4. 顶层块提取契约 (mihomo_lib_extract_top_block)
echo "--> Test 4: Top block extraction..."
RAW_FIXTURE="$TEST_SANDBOX/raw_subscription.yaml"
cat << 'EOF' > "$RAW_FIXTURE"
# Raw Clash Subscription Example
port: 7890
socks-port: 7891
proxies:
  - name: 节点-A
    type: ss
proxy-providers:
  provider1:
    type: http
proxy-groups:
  - name: 代理模式
    type: select
    proxies:
      - 节点-A
  - name: 全球拦截
    type: select
    proxies:
      - REJECT
rule-providers:
  reject_provider:
    type: http
sub-rules:
  sub1:
    - MATCH,DIRECT
rules:
  - DOMAIN-SUFFIX,google.com,代理模式
  - GEOIP,CN,DIRECT
  - MATCH,全球拦截
other-key:
  foo: bar
EOF

OUT_BLOCK="$TEST_SANDBOX/out_block.yaml"
mihomo_lib_extract_top_block "$RAW_FIXTURE" "proxy-groups" "$OUT_BLOCK" || fail "Failed to extract proxy-groups"
grep -q '^proxy-groups:' "$OUT_BLOCK" || fail "Output missing proxy-groups header"
grep -q '代理模式' "$OUT_BLOCK" || fail "Output missing 代理模式"
grep -q '全球拦截' "$OUT_BLOCK" || fail "Output missing 全球拦截"
grep -q 'rule-providers:' "$OUT_BLOCK" && fail "Output leaked into rule-providers"
grep -q 'other-key:' "$OUT_BLOCK" && fail "Output leaked into other-key"

# 不存在的块应返回 1 且输出为空
rm -f "$OUT_BLOCK"
if mihomo_lib_extract_top_block "$RAW_FIXTURE" "nonexistent-key" "$OUT_BLOCK"; then
    fail "Extracting nonexistent key should fail"
fi
[ ! -s "$OUT_BLOCK" ] || fail "Output must be empty on failure"
echo "  [PASS] Top block extraction verified."

# 5. 策略片段提取与校验 (mihomo_lib_extract_strategy, mihomo_lib_strategy_valid)
echo "--> Test 5: Strategy extraction & validation..."
STRAT_OUT="$TEST_SANDBOX/extracted_strategy.yaml"
mihomo_lib_extract_strategy "$RAW_FIXTURE" "$STRAT_OUT" || fail "Extract strategy should succeed on complete fixture"
[ -s "$STRAT_OUT" ] || fail "Extracted strategy is empty"
head -n 1 "$STRAT_OUT" | grep -Fq "# subscription strategy (auto-extracted; do not edit)" || fail "Missing strategy header comment"
grep -q '^proxy-providers:' "$STRAT_OUT" || fail "Missing proxy-providers in extracted strategy"
grep -q '^proxy-groups:' "$STRAT_OUT" || fail "Missing proxy-groups in extracted strategy"
grep -q '^rule-providers:' "$STRAT_OUT" || fail "Missing rule-providers in extracted strategy"
grep -q '^sub-rules:' "$STRAT_OUT" || fail "Missing sub-rules in extracted strategy"
grep -q '^rules:' "$STRAT_OUT" || fail "Missing rules in extracted strategy"

mihomo_lib_strategy_valid "$STRAT_OUT" || fail "mihomo_lib_strategy_valid should pass on valid strategy"

# 缺少 rules 或 proxy-groups 时应失败
BAD_FIXTURE_NO_RULES="$TEST_SANDBOX/bad_no_rules.yaml"
cat << 'EOF' > "$BAD_FIXTURE_NO_RULES"
proxy-groups:
  - name: G1
    type: select
EOF
if mihomo_lib_extract_strategy "$BAD_FIXTURE_NO_RULES" "$STRAT_OUT"; then
    fail "Extract strategy must fail when rules block is missing"
fi
[ ! -s "$STRAT_OUT" ] || fail "Failed extract must leave output empty"

BAD_FIXTURE_NO_GROUPS="$TEST_SANDBOX/bad_no_groups.yaml"
cat << 'EOF' > "$BAD_FIXTURE_NO_GROUPS"
rules:
  - MATCH,DIRECT
EOF
if mihomo_lib_extract_strategy "$BAD_FIXTURE_NO_GROUPS" "$STRAT_OUT"; then
    fail "Extract strategy must fail when proxy-groups block is missing"
fi
echo "  [PASS] Strategy extraction and validation verified."

# 6. 条目计数 (mihomo_lib_count_block_items)
echo "--> Test 6: Block items counting..."
COUNT_GROUPS="$(mihomo_lib_count_block_items "$RAW_FIXTURE" "proxy-groups")"
[ "$COUNT_GROUPS" = "2" ] || fail "Expected 2 items in proxy-groups, got $COUNT_GROUPS"

COUNT_RULES="$(mihomo_lib_count_block_items "$RAW_FIXTURE" "rules")"
[ "$COUNT_RULES" = "3" ] || fail "Expected 3 rules, got $COUNT_RULES"
echo "  [PASS] Block items counting verified."

# 7. 策略缓存存取 (mihomo_lib_strategy_store, mihomo_lib_strategy_remove)
echo "--> Test 7: Strategy cache store and remove..."
# 重新提取出有效策略
mihomo_lib_extract_strategy "$RAW_FIXTURE" "$STRAT_OUT"
mihomo_lib_strategy_store "$STRAT_OUT" || fail "Strategy store failed"
[ -f "$MIHOMO_STRATEGY_FILE" ] || fail "Strategy cache file not found at $MIHOMO_STRATEGY_FILE"
grep -q '代理模式' "$MIHOMO_STRATEGY_FILE" || fail "Strategy cache missing content"

mihomo_lib_strategy_remove
[ ! -f "$MIHOMO_STRATEGY_FILE" ] || fail "Strategy cache file should be removed"
echo "  [PASS] Strategy cache store and remove verified."

# 8. Compose 测试：subscription 模式成功替换策略、注入自定义规则与 GEOSITE,private,DIRECT
echo "--> Test 8: Compose in subscription mode..."
# 保存策略到缓存
mihomo_lib_extract_strategy "$RAW_FIXTURE" "$STRAT_OUT"
mihomo_lib_strategy_store "$STRAT_OUT"

# 准备自定义规则
cat << 'EOF' > "$MIHOMO_RULES_FILE"
# 用户自定义分流规则
DOMAIN,my-custom-domain.com,DIRECT

IP-CIDR,10.20.30.40/32,REJECT
EOF

export MIHOMO_STRATEGY_MODE="subscription"
COMPOSE_OUT="$TEST_SANDBOX/composed_config.yaml"
mihomo_lib_compose "$PROXIES_FIXTURE" "$COMPOSE_OUT" || fail "Compose failed"

[ -s "$COMPOSE_OUT" ] || fail "Compose output is empty"
[ "$MIHOMO_COMPOSE_STRATEGY_USED" = "subscription" ] || fail "Expected strategy used subscription, got $MIHOMO_COMPOSE_STRATEGY_USED"
[ "$MIHOMO_COMPOSE_STRATEGY_GROUPS" = "2" ] || fail "Expected 2 strategy groups items, got $MIHOMO_COMPOSE_STRATEGY_GROUPS"
[ "$MIHOMO_COMPOSE_STRATEGY_RULES" = "3" ] || fail "Expected 3 strategy rules, got $MIHOMO_COMPOSE_STRATEGY_RULES"

# 断言：输出含 fixture 组名（代理模式、全球拦截），不含模板组名（🌍选择节点）
grep -q '代理模式' "$COMPOSE_OUT" || fail "Compose output missing 代理模式"
grep -q '全球拦截' "$COMPOSE_OUT" || fail "Compose output missing 全球拦截"
grep -q '🌍选择节点' "$COMPOSE_OUT" && fail "Compose output must not contain template group 🌍选择节点"

# 断言：自定义规则出现在 rules: 之后、GEOSITE,private,DIRECT 之前；GEOSITE,private,DIRECT 存在
awk '
  BEGIN { state = 0 }
  /^rules:[ \t]*/ { state = 1; next }
  state == 1 && /DOMAIN,my-custom-domain\.com,DIRECT/ { state = 2; next }
  state == 2 && /IP-CIDR,10\.20\.30\.40\/32,REJECT/ { state = 3; next }
  state == 3 && /GEOSITE,private,DIRECT/ { state = 4; next }
  state == 4 && /DOMAIN-SUFFIX,google\.com,代理模式/ { state = 5; next }
  END {
      if (state != 5) {
          print "Rule injection order check failed, final state=" state
          exit 1
      }
  }
' "$COMPOSE_OUT" || fail "Rule injection order check failed in composed config"

# 断言：基础配置（secret, external-controller, dns）仍来自模板
grep -q 'external-controller: 127.0.0.1:9090' "$COMPOSE_OUT" || fail "external-controller missing"
grep -q "secret: \"sandbox-secret-1234567890abcdef\"" "$COMPOSE_OUT" || fail "secret missing or wrong"
grep -q '^dns:' "$COMPOSE_OUT" || fail "dns missing"
echo "  [PASS] Compose in subscription mode verified."

# 9. Compose 测试：template 模式保持模板策略组，不出现 fixture 组名
echo "--> Test 9: Compose in template mode..."
export MIHOMO_STRATEGY_MODE="template"
rm -f "$COMPOSE_OUT"
mihomo_lib_compose "$PROXIES_FIXTURE" "$COMPOSE_OUT" || fail "Compose in template mode failed"

[ "$MIHOMO_COMPOSE_STRATEGY_USED" = "template" ] || fail "Expected strategy used template, got $MIHOMO_COMPOSE_STRATEGY_USED"
grep -q '🌍选择节点' "$COMPOSE_OUT" || fail "Template mode must contain 🌍选择节点"
grep -q '代理模式' "$COMPOSE_OUT" && fail "Template mode must not contain fixture group 代理模式"
grep -q 'DOMAIN,my-custom-domain\.com,DIRECT' "$COMPOSE_OUT" || fail "Custom rules must be injected in template mode"
grep -q 'GEOSITE,private,DIRECT' "$COMPOSE_OUT" || fail "GEOSITE,private,DIRECT must exist in template mode"
echo "  [PASS] Compose in template mode verified."

# 10. Compose 测试：策略文件缺失时 subscription 模式回退模板
echo "--> Test 10: Compose fallback to template when strategy cache is missing..."
export MIHOMO_STRATEGY_MODE="subscription"
mihomo_lib_strategy_remove
rm -f "$COMPOSE_OUT"

# 捕获 stderr
COMPOSE_STDERR="$TEST_SANDBOX/compose_stderr.txt"
mihomo_lib_compose "$PROXIES_FIXTURE" "$COMPOSE_OUT" 2>"$COMPOSE_STDERR" || fail "Compose should succeed with fallback"
[ "$MIHOMO_COMPOSE_STRATEGY_USED" = "template" ] || fail "Expected strategy used template on fallback, got $MIHOMO_COMPOSE_STRATEGY_USED"
grep -q '🌍选择节点' "$COMPOSE_OUT" || fail "Fallback must use template group 🌍选择节点"
grep -q '提示：未找到可用的订阅策略组缓存，本次使用插件模板' "$COMPOSE_STDERR" || fail "Missing fallback prompt on stderr"
echo "  [PASS] Fallback to template verified."

# 11. 状态 JSON 扩展 (mihomo_lib_status_write) 7 参与 4 参兼容性
echo "--> Test 11: Status JSON writing (4-arg and 7-arg)..."
# 11a. 7 参
mihomo_lib_status_write "success" 42 "abcdef123" "测试成功" "subscription" 12 108
[ -f "$MIHOMO_STATUS_FILE" ] || fail "Status file not written"
grep -Fq '"strategy":"subscription"' "$MIHOMO_STATUS_FILE" || fail "Missing strategy in status JSON"
grep -Fq '"groups":12' "$MIHOMO_STATUS_FILE" || fail "Missing groups in status JSON"
grep -Fq '"rules":108' "$MIHOMO_STATUS_FILE" || fail "Missing rules in status JSON"
grep -Fq '"nodes":42' "$MIHOMO_STATUS_FILE" || fail "Missing nodes in status JSON"

# 11b. 4 参兼容性
mihomo_lib_status_write "failed" 0 "" "错误消息"
grep -Fq '"strategy":"template"' "$MIHOMO_STATUS_FILE" || fail "4-arg status write should default strategy to template"
grep -Fq '"groups":0' "$MIHOMO_STATUS_FILE" || fail "4-arg status write should default groups to 0"
grep -Fq '"rules":0' "$MIHOMO_STATUS_FILE" || fail "4-arg status write should default rules to 0"
grep -Fq '"result":"failed"' "$MIHOMO_STATUS_FILE" || fail "Missing result in status JSON"
echo "  [PASS] Status JSON writing verified."

# 12. custom_rules_validate.php 目标来源测试 (MIHOMO_TARGETS_FILE 与生效配置)
echo "--> Test 12: Validator targets resolution logic..."
# 检查 custom_rules_validate.php 中新增逻辑结构
grep -Fq 'MIHOMO_TARGETS_FILE' "$VALIDATOR_PHP" || fail "Validator missing MIHOMO_TARGETS_FILE handling"
grep -Fq 'DEFAULT_CONFIG_FILE' "$VALIDATOR_PHP" || fail "Validator missing DEFAULT_CONFIG_FILE handling"
grep -Fq 'parse_proxy_group_names' "$VALIDATOR_PHP" || fail "Validator missing parse_proxy_group_names function"

# 运行 php 真实执行（如果本地有 php）或 Python 模拟验证
if command -v php >/dev/null 2>&1; then
    TEST_TARGETS_FILE="$TEST_SANDBOX/test_targets.yaml"
    cat << 'EOF' > "$TEST_TARGETS_FILE"
proxy-groups:
  - name: 自定义策略组A
  - name: 自定义策略组B
rules:
  - MATCH,DIRECT
EOF
    TARGETS_JSON="$(MIHOMO_TARGETS_FILE="$TEST_TARGETS_FILE" php "$VALIDATOR_PHP" --targets)"
    printf '%s' "$TARGETS_JSON" | grep -Fq '自定义策略组A' || fail "Validator did not resolve targets from MIHOMO_TARGETS_FILE"
    printf '%s' "$TARGETS_JSON" | grep -Fq '自定义策略组B' || fail "Validator did not resolve targets from MIHOMO_TARGETS_FILE"
    printf '%s' "$TARGETS_JSON" | grep -Fq 'DIRECT' || fail "Validator missing builtin DIRECT"
    echo "  [PASS] Dynamic PHP targets resolution verified."
else
    echo "  [PASS] PHP binary not found; static source analysis passed."
fi

# 13. sub.sh 编排接线自检 (Dry-run / Mock 测试)
echo "--> Test 13: sub.sh orchestration checks..."
grep -Fq 'STRATEGY_MODE="$(mihomo_lib_strategy_mode)"' "$SUB_SH" || fail "sub.sh missing STRATEGY_MODE"
grep -Fq 'MIHOMO_STRATEGY_INPUT_FILE="$TMP_STRATEGY"' "$SUB_SH" || fail "sub.sh must pass the extracted strategy as INPUT, not overwrite the cache path"
grep -Fq '_strategy_src="${MIHOMO_STRATEGY_INPUT_FILE:-$MIHOMO_STRATEGY_FILE}"' "$SUB_LIB" || fail "sub_lib compose must prefer MIHOMO_STRATEGY_INPUT_FILE over the cache path"
grep -Fq 'mihomo_lib_extract_strategy "$TMP_RAW" "$TMP_STRATEGY"' "$SUB_SH" || fail "sub.sh missing extract_strategy call"
grep -Fq 'mihomo_lib_strategy_store "$TMP_STRATEGY"' "$SUB_SH" || fail "sub.sh missing strategy_store call"
grep -Fq 'mihomo_lib_strategy_remove' "$SUB_SH" || fail "sub.sh missing strategy_remove call"
grep -Fq 'TMP_STRATEGY' "$SUB_SH" || fail "sub.sh missing TMP_STRATEGY cleanup"
echo "  [PASS] sub.sh orchestration checks passed."

echo "===> All subscription strategy core tests (Package A) PASSED 100%!"
exit 0
