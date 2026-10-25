#!/bin/sh
set -eu

# api_bind_manager.sh - external-controller 绑定地址/端口的校验、事务化渲染与生效断言
# 设计文档：docs/DESIGN-lan-api.md v3.2（§2.1 校验 / §2.2 事务与断言 / §2.2.0 secret 门禁）
#
# 用法：
#   api_bind_manager.sh apply <bind> <port> [config] [template]   # 面板/configd 路径
#   api_bind_manager.sh reconcile                                 # do_start/POST_INSTALL 路径
#   api_bind_manager.sh --probe [config]                          # 输出归一化后的 "host port"
#
# 环境变量覆盖（生产默认为 /usr/local 安装路径；测试用临时目录）：
#   MIHOMO_API_CONF / MIHOMO_API_TEMPLATE / MIHOMO_SECRET_FILE / MIHOMO_SECRET_MANAGER
#   MIHOMO_SERVICE_MANAGER / MIHOMO_LOCK_DIR / MIHOMO_PANEL_STATE_FILE / MIHOMO_API_ALERT_FILE
#   MIHOMO_API_IFCONFIG / MIHOMO_API_SOCKSTAT / MIHOMO_API_PGREP
#   MIHOMO_API_ASSERT_TIMEOUT（秒，默认 15）/ MIHOMO_API_LOCK_WAIT（秒，默认 15 = 5s×3）
#
# 注意：POSIX sh 无局部变量，各函数使用独立前缀，避免覆盖 apply 的 bind/port/旧值。

CONF="${MIHOMO_API_CONF:-/usr/local/etc/mihomo/config.yaml}"
TEMPLATE="${MIHOMO_API_TEMPLATE:-/usr/local/etc/mihomo/sub/template_config.yaml}"
SECRET_FILE="${MIHOMO_SECRET_FILE:-/usr/local/etc/mihomo/secret.key}"
SECRET_MANAGER="${MIHOMO_SECRET_MANAGER:-/usr/local/opnsense/scripts/OPNsense/Mihomo/secret_manager.sh}"
SERVICE_MANAGER="${MIHOMO_SERVICE_MANAGER:-/usr/local/opnsense/scripts/OPNsense/Mihomo/service_manager.sh}"
LOCK_DIR="${MIHOMO_LOCK_DIR:-/var/run/mihomo-sub.lock}"
PANEL_STATE="${MIHOMO_PANEL_STATE_FILE:-/var/db/os-mihomo/panel-state.env}"
ALERT_FILE="${MIHOMO_API_ALERT_FILE:-/var/db/os-mihomo/api-bind.alert}"
IFCONFIG_CMD="${MIHOMO_API_IFCONFIG:-ifconfig}"
SOCKSTAT_CMD="${MIHOMO_API_SOCKSTAT:-sockstat}"
PGREP_CMD="${MIHOMO_API_PGREP:-pgrep}"
ASSERT_TIMEOUT="${MIHOMO_API_ASSERT_TIMEOUT:-15}"
LOCK_WAIT="${MIHOMO_API_LOCK_WAIT:-15}"
case "$LOCK_WAIT" in
    ''|*[!0-9]*) LOCK_WAIT=15 ;;
esac

LOCK_HELD=0

err() {
    # configd 只回传 stdout：失败摘要必须同时写两路
    printf 'error: %s\n' "$*"
    printf 'error: %s\n' "$*" >&2
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

# 与 secret_manager.sh / sub_lib.sh 的订阅锁逐字节同语义：mkdir + pid + 陈旧锁清理
api_bind_lock_try() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=1
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi
    _lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$_lock_pid" ] && ! kill -0 "$_lock_pid" 2>/dev/null; then
        echo "警告：发现陈旧锁（持有者 PID $_lock_pid 已不存在），自动清理后重试。" >&2
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            LOCK_HELD=1
            printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
            return 0
        fi
    fi
    return 1
}

# 短等待：默认 5s×3；reconcile 与 apply 共用，busy 由调用方决定退出语义
api_bind_lock_acquire() {
    _lock_waited=0
    while ! api_bind_lock_try; do
        if [ "$_lock_waited" -ge "$LOCK_WAIT" ]; then
            return 1
        fi
        sleep 5
        _lock_waited=$((_lock_waited + 5))
    done
    return 0
}

api_bind_lock_release() {
    if [ "${LOCK_HELD:-0}" = "1" ]; then
        rm -f "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        LOCK_HELD=0
    fi
}

# 原始解析（不做 0.0.0.0 归一化）：回滚与负向断言必须看到真实旧绑定
api_bind_parse_raw() {
    _pr_conf="$1"
    [ -r "$_pr_conf" ] || return 1
    awk '
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
              p[2] ~ /^[0-9]+$/) {
              split(p[1], o, ".")
              if (o[1] <= 255 && o[2] <= 255 && o[3] <= 255 && o[4] <= 255 &&
                  (p[2] + 0) >= 1 && (p[2] + 0) <= 65535) {
                  print p[1], p[2]
                  found = 1
              }
          }
          exit
      }
    ' "$_pr_conf" 2>/dev/null
}

# 探测归一化（与 sub_lib.sh 的 mihomo_lib_api_addr 同语义）：0.0.0.0 → 127.0.0.1，
# 解析失败回落 127.0.0.1 9090 并告警
api_bind_probe() {
    _pb_conf="${1:-$CONF}"
    _pb_raw="$(api_bind_parse_raw "$_pb_conf" || true)"
    if [ -z "$_pb_raw" ]; then
        warn "无法从 $_pb_conf 解析 external-controller，回退 127.0.0.1 端口 9090"
        printf '%s %s\n' "127.0.0.1" "9090"
        return 0
    fi
    _pb_host="${_pb_raw% *}"
    _pb_port="${_pb_raw#* }"
    if [ "$_pb_host" = "0.0.0.0" ]; then
        _pb_host="127.0.0.1"
    fi
    printf '%s %s\n' "$_pb_host" "$_pb_port"
}

api_bind_valid_ipv4() {
    case "$1" in
        ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
        *.*.*.*) ;;
        *) return 1 ;;
    esac
    _ip_saved_ifs="$IFS"
    IFS=.
    set -- $1
    IFS="$_ip_saved_ifs"
    [ "$#" -eq 4 ] || return 1
    for _ip_octet in "$@"; do
        case "$_ip_octet" in
            ''|*[!0-9]*) return 1 ;;
        esac
        if [ "$_ip_octet" -gt 255 ] 2>/dev/null; then
            return 1
        fi
    done
    return 0
}

api_bind_valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] || return 1
    if [ "$1" -lt 1024 ] 2>/dev/null; then
        return 1
    fi
    if [ "$1" -gt 65535 ] 2>/dev/null; then
        return 1
    fi
    return 0
}

# 本机地址核验：按字段精确匹配，杜绝 grep 子串把 inet6/netmask 误当 inet
api_bind_is_local() {
    "$IFCONFIG_CMD" -a 2>/dev/null | awk -v addr="$1" '
        $1 == "inet" && $2 == addr { found = 1 }
        END { exit !found }
    '
}

api_bind_validate() {
    _vb_bind="$1"
    _vb_port="$2"
    if ! api_bind_valid_ipv4 "$_vb_bind"; then
        err "非法绑定地址：$_vb_bind（必须是合法 IPv4 点分十进制）"
        return 1
    fi
    if [ "$_vb_bind" != "0.0.0.0" ] && [ "$_vb_bind" != "127.0.0.1" ]; then
        if ! api_bind_is_local "$_vb_bind"; then
            err "绑定地址 $_vb_bind 不是本机已分配地址（ifconfig -a 中无 inet $_vb_bind）"
            return 1
        fi
    fi
    if ! api_bind_valid_port "$_vb_port"; then
        err "非法端口：$_vb_port（允许范围 1024-65535）"
        return 1
    fi
    case "$_vb_port" in
        1053|7890|7891)
            err "端口 $_vb_port 属于 mihomo 内部保留端口（deny-list: 1053/7890/7891）"
            return 1
            ;;
    esac
    return 0
}

api_bind_secret_value() {
    # 与 secret_manager.sh 的 extract_secret_from_config 同口径：只取实际值，不认 secret.key
    sed -n 's/^secret:[[:space:]]*["'\'']*\([^"'\'']*\)["'\'']*.*/\1/p' "$1" 2>/dev/null | head -n 1
}

api_bind_run_secret_manager() {
    [ -f "$SECRET_MANAGER" ] || return 1
    if [ -x "$SECRET_MANAGER" ]; then
        "$SECRET_MANAGER" "$@"
    else
        sh "$SECRET_MANAGER" "$@"
    fi
}

# §2.2.0：非回环绑定前，config.yaml 的实际 secret 必须非空。
# 此门禁在取锁之前执行；secret_manager 自带同一把锁，此时本进程未持锁，无死锁。
api_bind_secret_gate() {
    _sg_bind="$1"
    _sg_conf="$2"
    if [ "$_sg_bind" = "127.0.0.1" ]; then
        return 0
    fi
    _sg_secret="$(api_bind_secret_value "$_sg_conf" || true)"
    if [ -n "$_sg_secret" ]; then
        return 0
    fi
    if [ -s "$SECRET_FILE" ]; then
        _sg_b64="$(base64 < "$SECRET_FILE" 2>/dev/null | tr -d ' \n\r\t' || true)"
        if [ -n "$_sg_b64" ]; then
            # 让 secret_manager 与本次渲染目标保持同一组文件
            export MIHOMO_SECRET_FILE="$SECRET_FILE"
            export MIHOMO_CONFIG_FILE="$_sg_conf"
            export MIHOMO_TEMPLATE_FILE="$TEMPLATE"
            if api_bind_run_secret_manager set "b64:$_sg_b64" >/dev/null 2>&1; then
                _sg_secret="$(api_bind_secret_value "$_sg_conf" || true)"
            fi
        fi
    fi
    if [ -z "$_sg_secret" ]; then
        err "拒绝渲染非回环绑定 $_sg_bind：config.yaml 的 secret 为空（mihomo 只认 config.yaml 中的实际 secret）"
        return 1
    fi
    return 0
}

api_bind_run_service_manager() {
    [ -f "$SERVICE_MANAGER" ] || return 1
    if [ -x "$SERVICE_MANAGER" ]; then
        "$SERVICE_MANAGER" "$@"
    else
        sh "$SERVICE_MANAGER" "$@"
    fi
}

# 单文件渲染 + 写后校验；行缺失时先补末行换行再追加，绝不产生半截 YAML
api_bind_render_file() {
    _rf_file="$1"
    _rf_line="$2"
    if grep -q '^external-controller:' "$_rf_file" 2>/dev/null; then
        if sed -i '' -e "s/^external-controller:.*/$_rf_line/" "$_rf_file" 2>/dev/null; then
            :
        elif sed -i -e "s/^external-controller:.*/$_rf_line/" "$_rf_file" 2>/dev/null; then
            :
        else
            return 1
        fi
    else
        if [ -s "$_rf_file" ] && [ -n "$(tail -c 1 "$_rf_file")" ]; then
            printf '\n' >> "$_rf_file" || return 1
        fi
        printf '%s\n' "$_rf_line" >> "$_rf_file" || return 1
    fi
    grep -q -x -F "$_rf_line" "$_rf_file" 2>/dev/null || return 1
    return 0
}

# 单次监听探测：sockstat -l -p（不带 -4），按 mihomo 进程与 bind 精确匹配
api_bind_probe_listening() {
    _pl_host="$1"
    _pl_port="$2"
    _pl_out="$("$SOCKSTAT_CMD" -l -p "$_pl_port" 2>/dev/null || true)"
    [ -n "$_pl_out" ] || return 1
    printf '%s\n' "$_pl_out" | awk -v want="$_pl_host:$_pl_port" -v h="$_pl_host" -v p="$_pl_port" '
        ($1 == "mihomo" || $2 == "mihomo") {
            for (i = 1; i <= NF; i++) {
                if ($i == want) { found = 1 }
                if (h == "0.0.0.0" && ($i == "*:" p || $i == "0.0.0.0:" p)) { found = 1 }
            }
        }
        END { exit !found }
    '
}

# 有界轮询双向断言：期望绑定出现 + 旧绑定消失（绑定/端口变化时）
api_bind_assert_transition() {
    _at_want_host="$1"
    _at_want_port="$2"
    _at_old_host="$3"
    _at_old_port="$4"
    _at_timeout="$ASSERT_TIMEOUT"
    case "$_at_timeout" in
        ''|*[!0-9]*) _at_timeout=15 ;;
    esac
    if [ "$_at_timeout" -lt 1 ] 2>/dev/null; then
        _at_timeout=1
    fi
    _at_tries=$((_at_timeout * 2))
    _at_i=0
    while [ "$_at_i" -lt "$_at_tries" ]; do
        if api_bind_probe_listening "$_at_want_host" "$_at_want_port"; then
            if [ -z "$_at_old_host" ]; then
                return 0
            fi
            if [ "$_at_old_host" = "$_at_want_host" ] && [ "$_at_old_port" = "$_at_want_port" ]; then
                return 0
            fi
            if ! api_bind_probe_listening "$_at_old_host" "$_at_old_port"; then
                return 0
            fi
        fi
        sleep 0.5
        _at_i=$((_at_i + 1))
    done
    return 1
}

# 回滚失败时落盘告警，并把手工恢复指引写到 stdout（configd 只回传 stdout）
api_bind_write_alert() {
    _wa_reason="$1"
    _wa_old_host="$2"
    _wa_old_port="$3"
    _wa_conf_bak="$4"
    _wa_tmpl_bak="$5"
    mkdir -p "$(dirname "$ALERT_FILE")" 2>/dev/null || true
    {
        printf 'time: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"
        printf 'reason: %s\n' "$_wa_reason"
        printf 'old_bind: %s\n' "${_wa_old_host:-unknown}:${_wa_old_port:-unknown}"
        printf 'config: %s\n' "$CONF"
        printf 'template: %s\n' "$TEMPLATE"
        printf 'backup_config: %s\n' "$_wa_conf_bak"
        printf 'backup_template: %s\n' "$_wa_tmpl_bak"
        printf 'manual: 把两份文件的 external-controller 改回旧值后执行 %s reload\n' "$SERVICE_MANAGER"
    } > "$ALERT_FILE" 2>/dev/null || true
    chmod 0600 "$ALERT_FILE" 2>/dev/null || true
}

# 回滚：恢复两文件 -> reload -> 复用双向断言；任一步失败则写告警并给出手工指引
api_bind_rollback() {
    _rb_reason="$1"
    _rb_conf_bak="$2"
    _rb_tmpl_bak="$3"
    _rb_old_host="$4"
    _rb_old_port="$5"
    _rb_new_host="$6"
    _rb_new_port="$7"

    err "$_rb_reason"
    _rb_restored=1
    if cp -p "$_rb_conf_bak" "$CONF" 2>/dev/null && cmp -s "$CONF" "$_rb_conf_bak"; then
        :
    else
        _rb_restored=0
    fi
    if cp -p "$_rb_tmpl_bak" "$TEMPLATE" 2>/dev/null && cmp -s "$TEMPLATE" "$_rb_tmpl_bak"; then
        :
    else
        _rb_restored=0
    fi
    chmod 0600 "$CONF" "$TEMPLATE" 2>/dev/null || true

    if [ "$_rb_restored" -eq 1 ] && [ -n "$_rb_old_host" ]; then
        if "$PGREP_CMD" -x mihomo >/dev/null 2>&1; then
            if ! api_bind_run_service_manager reload; then
                _rb_restored=0
            fi
            if [ "$_rb_restored" -eq 1 ] && ! api_bind_assert_transition "$_rb_old_host" "$_rb_old_port" "$_rb_new_host" "$_rb_new_port"; then
                _rb_restored=0
            fi
        fi
    fi

    if [ "$_rb_restored" -eq 1 ]; then
        if [ -n "$_rb_old_host" ]; then
            err "已回滚为 ${_rb_old_host}:${_rb_old_port}"
        else
            err "已回滚（旧配置无 external-controller 行）"
        fi
        rm -f "$_rb_conf_bak" "$_rb_tmpl_bak" 2>/dev/null || true
        return 1
    fi

    api_bind_write_alert "自动回滚失败（${_rb_reason}）" "$_rb_old_host" "$_rb_old_port" "$_rb_conf_bak" "$_rb_tmpl_bak"
    err "自动回滚失败！请手工恢复：将 $CONF 与 $TEMPLATE 的 external-controller 改回 ${_rb_old_host}:${_rb_old_port}，再执行 $SERVICE_MANAGER reload"
    err "备份文件保留：$_rb_conf_bak / $_rb_tmpl_bak；告警文件：$ALERT_FILE"
    return 1
}

api_bind_apply() {
    _bind="$1"
    _port="$2"

    api_bind_validate "$_bind" "$_port" || return 1
    api_bind_secret_gate "$_bind" "$CONF" || return 1

    if [ ! -f "$CONF" ]; then
        err "配置文件不存在：$CONF（拒绝创建残缺 YAML）"
        return 1
    fi
    if [ ! -f "$TEMPLATE" ]; then
        err "订阅模板不存在：$TEMPLATE（拒绝创建残缺 YAML）"
        return 1
    fi

    trap 'api_bind_lock_release' EXIT INT TERM
    if ! api_bind_lock_acquire; then
        err "busy"
        return 1
    fi

    # 锁内读取旧值与差异标记：与 sub.sh / secret_manager 保持同一写入时序
    _old="$(api_bind_parse_raw "$CONF" || true)"
    _old_host=""
    _old_port=""
    if [ -n "$_old" ]; then
        _old_host="${_old% *}"
        _old_port="${_old#* }"
    fi
    _line="external-controller: ${_bind}:${_port}"
    _conf_needed=0
    _tmpl_needed=0
    grep -q -x -F "$_line" "$CONF" 2>/dev/null || _conf_needed=1
    grep -q -x -F "$_line" "$TEMPLATE" 2>/dev/null || _tmpl_needed=1

    _conf_bak="${CONF}.api-bind.$$.bak"
    _tmpl_bak="${TEMPLATE}.api-bind.$$.bak"
    if ! cp -p "$CONF" "$_conf_bak" 2>/dev/null || ! chmod 0600 "$_conf_bak" 2>/dev/null; then
        rm -f "$_conf_bak" 2>/dev/null || true
        err "无法为 $CONF 创建 0600 事务备份"
        return 1
    fi
    if ! cp -p "$TEMPLATE" "$_tmpl_bak" 2>/dev/null || ! chmod 0600 "$_tmpl_bak" 2>/dev/null; then
        rm -f "$_conf_bak" "$_tmpl_bak" 2>/dev/null || true
        err "无法为 $TEMPLATE 创建 0600 事务备份"
        return 1
    fi

    if ! api_bind_render_file "$CONF" "$_line"; then
        api_bind_rollback "写入 config.yaml 失败（写后校验未通过）" "$_conf_bak" "$_tmpl_bak" \
            "$_old_host" "$_old_port" "$_bind" "$_port" || true
        return 1
    fi
    if ! api_bind_render_file "$TEMPLATE" "$_line"; then
        api_bind_rollback "写入订阅模板失败（写后校验未通过）" "$_conf_bak" "$_tmpl_bak" \
            "$_old_host" "$_old_port" "$_bind" "$_port" || true
        return 1
    fi

    if [ "$_conf_needed" -eq 1 ] && "$PGREP_CMD" -x mihomo >/dev/null 2>&1; then
        if ! api_bind_run_service_manager reload; then
            api_bind_rollback "mihomo reload 失败" "$_conf_bak" "$_tmpl_bak" \
                "$_old_host" "$_old_port" "$_bind" "$_port" || true
            return 1
        fi
        if ! api_bind_assert_transition "$_bind" "$_port" "$_old_host" "$_old_port"; then
            api_bind_rollback "生效断言失败（期望 ${_bind}:${_port}，旧 ${_old_host}:${_old_port} 未消失）" \
                "$_conf_bak" "$_tmpl_bak" "$_old_host" "$_old_port" "$_bind" "$_port" || true
            return 1
        fi
    fi

    rm -f "$_conf_bak" "$_tmpl_bak" 2>/dev/null || true
    printf 'OK: api bind %s:%s\n' "$_bind" "$_port"
    return 0
}

# do_start / POST_INSTALL 路径：读 panel-state 收敛；任何失败都只告警，永不非 0 退出
api_bind_reconcile() {
    _rc_bind=""
    _rc_port=""
    if [ -f "$PANEL_STATE" ]; then
        MIHOMO_API_BIND=""
        MIHOMO_API_PORT=""
        . "$PANEL_STATE" 2>/dev/null || true
        _rc_bind="${MIHOMO_API_BIND:-}"
        _rc_port="${MIHOMO_API_PORT:-}"
    fi
    if [ -z "$_rc_bind" ] || [ -z "$_rc_port" ]; then
        # 无面板状态（升级前遗留）：保持 config.yaml 现状，绝不静默收窄或重置
        printf 'OK: api bind（panel-state 未配置绑定，保持现状）\n'
        return 0
    fi
    _rc_rc=0
    if [ -x "$0" ]; then
        "$0" apply "$_rc_bind" "$_rc_port" || _rc_rc=$?
    else
        sh "$0" apply "$_rc_bind" "$_rc_port" || _rc_rc=$?
    fi
    if [ "$_rc_rc" -ne 0 ]; then
        warn "api bind reconcile 失败（${_rc_bind}:${_rc_port}），保持现有配置继续运行"
    fi
    return 0
}

case "${1:-}" in
    apply)
        if [ "$#" -lt 3 ]; then
            err "usage: $0 apply <bind> <port> [config] [template]"
            exit 1
        fi
        if [ -n "${4:-}" ]; then
            CONF="$4"
        fi
        if [ -n "${5:-}" ]; then
            TEMPLATE="$5"
        fi
        api_bind_apply "$2" "$3" || exit 1
        ;;
    reconcile)
        api_bind_reconcile
        ;;
    --probe|probe)
        api_bind_probe "${2:-$CONF}"
        ;;
    *)
        echo "usage: $0 {apply <bind> <port> [config] [template]|reconcile|--probe [config]}" >&2
        exit 1
        ;;
esac
