#!/bin/sh
set -eu

# service_manager.sh - Mihomo 7-State Lifecycle State Machine Manager
# States: DISABLED, STARTING, RUNNING, DEGRADED, STOPPING, STOPPED, FAILED
# Modes: PROXY, TRANSPARENT, DIRECT

STATE_FILE="/var/run/mihomo_state.json"
STATE_DB_DIR="/var/db/os-mihomo"
STATE_DB_FILE="${STATE_DB_DIR}/state.json"

NAME="mihomo"
BIN="/usr/local/bin/mihomo"
CONF_DIR="/usr/local/etc/mihomo"
CONF_FILE="${CONF_DIR}/config.yaml"
PID_FILE="/var/run/mihomo.pid"
LOG_FILE="/var/log/mihomo.log"
TUN_DEV="tun_mihomo"
API_TIMEOUT=30

# 传输层与面板状态：transport_manager.sh 维护 transport-mode（模式意图），
# PHP 面板把 LAN 暴露开关写入 panel-state.env
TRANSPORT_MGR="/usr/local/opnsense/scripts/OPNsense/Mihomo/transport_manager.sh"
API_BIND_MGR="/usr/local/opnsense/scripts/OPNsense/Mihomo/api_bind_manager.sh"
SUB_LIB_FILE="${MIHOMO_SUB_LIB:-/usr/local/etc/mihomo/sub/sub_lib.sh}"
TRANSPORT_MODE_FILE="/var/db/os-mihomo/transport-mode"
PANEL_STATE="/var/db/os-mihomo/panel-state.env"

mkdir -p /var/run "${STATE_DB_DIR}" 2>/dev/null || true

get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S"
}

set_state() {
    _state="$1"
    _mode="$2"
    _pid="$3"
    _msg="$4"
    _ts="$(get_timestamp)"

    _pid_json="null"
    if [ -n "${_pid}" ] && [ "${_pid}" != "null" ]; then
        _pid_json="${_pid}"
    fi

    # Escape quotes in message if needed
    _msg_escaped="$(printf '%s' "${_msg}" | sed 's/"/\\"/g')"

    _json=$(cat <<EOF
{
  "state": "${_state}",
  "mode": "${_mode}",
  "pid": ${_pid_json},
  "last_change": "${_ts}",
  "message": "${_msg_escaped}"
}
EOF
)
    printf '%s\n' "${_json}" > "${STATE_FILE}.tmp"
    mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
    cp -f "${STATE_FILE}" "${STATE_DB_FILE}" 2>/dev/null || true
}

get_current_pid() {
    if [ -f "${PID_FILE}" ]; then
        _dpid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [ -n "${_dpid}" ] && kill -0 "${_dpid}" 2>/dev/null; then
            _mpid="$(pgrep -P "${_dpid}" mihomo 2>/dev/null | head -n 1 || true)"
            if [ -n "${_mpid}" ] && kill -0 "${_mpid}" 2>/dev/null; then
                echo "${_mpid}"
                return 0
            fi
            echo "${_dpid}"
            return 0
        fi
    fi
    _cpid="$(pgrep -f "${BIN} -d ${CONF_DIR}" 2>/dev/null | head -n 1 || true)"
    if [ -n "${_cpid}" ] && kill -0 "${_cpid}" 2>/dev/null; then
        echo "${_cpid}"
        return 0
    fi
    echo ""
}

cleanup_routing_and_pf() {
    # Destroy TUN interface if exists
    if ifconfig "${TUN_DEV}" >/dev/null 2>&1; then
        ifconfig "${TUN_DEV}" destroy 2>/dev/null || true
    fi

    # Clear stale routes if added
    # Mihomo strict-route/auto-route usually cleans up on normal stop, but on crash or failure ensure fallback
    # In OPNsense, DIRECT mode is normal default gateway routing without TUN
}

# external-controller 探测地址（§2.3 配置驱动）：优先复用 sub_lib.sh 的
# mihomo_lib_api_addr；库缺失时用本地同语义解析兜底（0.0.0.0 → 127.0.0.1）。
api_addr_now() {
    if [ -r "${SUB_LIB_FILE}" ]; then
        _addr="$( . "${SUB_LIB_FILE}" 2>/dev/null; mihomo_lib_api_addr "${CONF_FILE}" 2>/dev/null || true )"
    else
        _addr="$(awk '
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
                  p[2] ~ /^[0-9]+$/ &&
                  (p[2] + 0) >= 1 && (p[2] + 0) <= 65535) {
                  print p[1], p[2]
                  found = 1
              }
              exit
          }
        ' "${CONF_FILE}" 2>/dev/null || true)"
        if [ -z "${_addr}" ]; then
            _addr="127.0.0.1 9090"
        else
            _addr_host="${_addr% *}"
            if [ "${_addr_host}" = "0.0.0.0" ]; then
                _addr="127.0.0.1 ${_addr#* }"
            fi
        fi
    fi
    case "${_addr}" in
        *' '*) printf '%s\n' "${_addr}" ;;
        *) printf '127.0.0.1 9090\n' ;;
    esac
}

# API 监听探测：sockstat 不带 -4（tcp46 通配在 -4 下可能不可见），
# 只匹配本端口上的 mihomo 行；解析后的 0.0.0.0 已归一为回环，因此通配绑定也算就绪
api_listening() {
    _host="$1"
    _port="$2"
    _out="$(sockstat -l -p "${_port}" 2>/dev/null || true)"
    [ -n "${_out}" ] || return 1
    printf "%s\n" "${_out}" | awk -v want="${_host}:${_port}" -v p="${_port}" '
        $1 == "mihomo" || $2 == "mihomo" {
            for (i = 1; i <= NF; i++) {
                if ($i == want) found = 1
                if ($i == "*:" p || $i == "0.0.0.0:" p) found = 1
            }
        }
        END { exit !found }
    '
}

check_api_ready() {
    _elapsed=0
    _api_addr="$(api_addr_now)"
    _api_host="${_api_addr% *}"
    _api_port="${_api_addr#* }"
    while [ "${_elapsed}" -lt "${API_TIMEOUT}" ]; do
        if curl -s -m 2 "http://${_api_host}:${_api_port}" >/dev/null 2>&1; then
            return 0
        fi
        if api_listening "${_api_host}" "${_api_port}"; then
            return 0
        fi
        sleep 1
        _elapsed=$((_elapsed + 1))
    done
    return 1
}

check_tun_ready() {
    if ifconfig "${TUN_DEV}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# socks-core 模式判定：config.yaml 中 tun.enable 是否为 true
tun_enabled() {
    [ -f "${CONF_FILE}" ] || return 1
    awk '
        /^tun:[[:space:]]*$/ { in_tun=1; next }
        in_tun && /^[^[:space:]]/ { in_tun=0 }
        in_tun && /^[[:space:]]*enable:[[:space:]]*true/ { found=1; exit }
        END { exit !found }
    ' "${CONF_FILE}" 2>/dev/null
}

# 当前传输层模式（transport_manager.sh 维护）：文件缺失、读取失败或未知值一律按普通代理处理
transport_mode_now() {
    _tmode="$(cat "${TRANSPORT_MODE_FILE}" 2>/dev/null || true)"
    case "${_tmode}" in
        transparent) echo "transparent" ;;
        *) echo "proxy" ;;
    esac
}

# 面板“LAN 暴露”开关：panel-state.env 中 MIHOMO_LAN_EXPOSE=1 时为真，默认关闭
lan_expose_on() {
    MIHOMO_LAN_EXPOSE=0
    if [ -f "${PANEL_STATE}" ]; then
        . "${PANEL_STATE}" 2>/dev/null || true
    fi
    [ "${MIHOMO_LAN_EXPOSE:-0}" = "1" ]
}

# 传输层就绪检查：TUN 模式查 tun_mihomo；socks 模式按 LAN 暴露开关匹配 7891 的实际绑定地址
check_transport_ready() {
    if tun_enabled; then
        check_tun_ready
    elif lan_expose_on; then
        # LAN 暴露：bind-address 为 '*'，监听出现在 0.0.0.0 或 *（不同 sockstat 版本显示不同）
        sockstat -4 -l -p 7891 2>/dev/null | grep -q '0\.0\.0\.0:7891' && return 0
        sockstat -4 -l -p 7891 2>/dev/null | grep -q '\*:7891'
    else
        # 默认仅绑回环：必须看到 127.0.0.1:7891，不接受其它地址冒充当就绪
        sockstat -4 -l -p 7891 2>/dev/null | grep -q '127\.0\.0\.1:7891'
    fi
}

transport_name() {
    if tun_enabled; then
        echo "TUN"
    else
        echo "SOCKS"
    fi
}

do_start() {
    # Check if disabled
    if [ -f /etc/rc.conf.d/mihomo ]; then
        . /etc/rc.conf.d/mihomo
        if [ "${mihomo_enable:-YES}" = "NO" ] || [ "${mihomo_enable:-YES}" = "no" ]; then
            set_state "DISABLED" "DIRECT" null "Mihomo is disabled in rc.conf.d"
            echo "Mihomo is disabled in rc.conf.d."
            return 0
        fi
    fi

    # Check sing-box conflict
    if service sing-box status >/dev/null 2>&1; then
        set_state "FAILED" "DIRECT" null "Refusing to start: sing-box is running"
        echo "Refusing to start mihomo: sing-box is already running."
        return 1
    fi

    # 1. Already running? (先于配置校验：磁盘上配置损坏时不得破坏健康运行中的实例)
    if [ -f "${PID_FILE}" ]; then
        _old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [ -n "${_old_pid}" ] && kill -0 "${_old_pid}" 2>/dev/null; then
            echo "Mihomo is already running with PID ${_old_pid}."
            do_healthcheck
            return 0
        fi
        rm -f "${PID_FILE}"
    fi

    # 2. API 绑定收敛（§2.4：panel-state → config.yaml/template）
    # 失败仅告警：本文件 set -eu，必须用 if ! 包裹；reconcile 自身也保证不非 0
    if [ -x "${API_BIND_MGR}" ]; then
        if ! "${API_BIND_MGR}" reconcile; then
            echo "Warning: api bind reconcile failed; keeping current configuration." >&2
        fi
    fi

    # 3. Config validation
    if [ ! -f "${CONF_FILE}" ]; then
        cleanup_routing_and_pf
        set_state "FAILED" "DIRECT" null "Configuration file not found: ${CONF_FILE}"
        echo "Configuration file not found: ${CONF_FILE}"
        return 1
    fi

    if ! "${BIN}" -t -d "${CONF_DIR}" -f "${CONF_FILE}" >> "${LOG_FILE}" 2>&1; then
        cleanup_routing_and_pf
        set_state "FAILED" "DIRECT" null "Configuration validation failed"
        echo "Mihomo configuration validation failed."
        return 1
    fi

    # 3. Set STARTING
    set_state "STARTING" "DIRECT" null "Service is starting"

    if tun_enabled && ifconfig "${TUN_DEV}" >/dev/null 2>&1; then
        ifconfig "${TUN_DEV}" destroy 2>/dev/null || true
    fi

    # 3. Start background daemon
    touch "${LOG_FILE}"
    /usr/sbin/daemon -P "${PID_FILE}" -f -o "${LOG_FILE}" -t "${NAME}:daemon" "${BIN}" -d "${CONF_DIR}/"

    # 4. Check process PID
    sleep 1
    _pid="$(get_current_pid)"
    if [ -z "${_pid}" ]; then
        cleanup_routing_and_pf
        set_state "FAILED" "DIRECT" null "Daemon failed to spawn Mihomo process"
        echo "Mihomo failed to start (process missing)."
        return 1
    fi

    # 5. Check API ready (30s timeout)
    # §2.6 控制面/数据面解耦：API 不可达不再终止服务（绑定可变后 API 死 != 核心死，
    # 误杀会连带 1053 DNS 失效）。失败时按 panel-state reconcile 并再重载一次；
    # 仍失败则保持运行，由数据面（socks/DNS）判据决定状态。
    _api_ok=1
    if ! check_api_ready; then
        _api_ok=0
        echo "Warning: Mihomo API did not respond within ${API_TIMEOUT}s; keeping the service running (data plane is authoritative)." >&2
        if [ -x "${API_BIND_MGR}" ]; then
            "${API_BIND_MGR}" reconcile >/dev/null 2>&1 || true
        fi
        # 进程仍存活才重载；进程已退出时 do_reload 会回调 do_start（防递归）
        if [ -n "$(get_current_pid)" ]; then
            do_reload >/dev/null 2>&1 || true
        fi
        if check_api_ready; then
            _api_ok=1
        else
            echo "Warning: API still unresponsive after api-bind reconcile; mihomo stays running (socks/DNS unaffected)." >&2
        fi
    fi

    # 6. Transport check (TUN 模式查 tun_mihomo；socks-core 模式查 7891 监听)
    if ! check_transport_ready; then
        set_state "DEGRADED" "DIRECT" "${_pid}" "Transport ($(transport_name)) is DOWN"
        echo "Warning: Mihomo started but transport ($(transport_name)) is not detected."
        return 0
    fi

    # 7. Health check passed -> RUNNING / (PROXY | TRANSPARENT)（API DOWN 但数据面 UP 也保持运行并告警）
    _tmode="$(transport_mode_now)"
    [ "${_tmode}" = "transparent" ] || _tmode="proxy"
    _mode="PROXY"
    [ "${_tmode}" = "transparent" ] && _mode="TRANSPARENT"

    if [ "${_api_ok}" -eq 1 ]; then
        set_state "RUNNING" "${_mode}" "${_pid}" "Service is healthy and operating in ${_mode} mode ($(transport_name))"
        echo "Mihomo started successfully (PID ${_pid}, mode ${_mode}, transport $(transport_name))."
    else
        set_state "RUNNING" "${_mode}" "${_pid}" "Data plane UP ($(transport_name)); API unresponsive, kept running per §2.6"
        echo "Warning: Mihomo is running with transport $(transport_name) UP but API DOWN; service kept alive." >&2
    fi

    # 8. 透明代理模式：健康通过后幂等重挂 transport anchor；
    #    传输层失败不改变服务状态（保持 RUNNING），由 watchdog 兜底重试
    if [ "$(transport_mode_now)" = "transparent" ] && [ -x "${TRANSPORT_MGR}" ]; then
        "${TRANSPORT_MGR}" enable || echo "Warning: transparent transport re-enable failed; mihomo stays RUNNING, watchdog will retry." >&2
    fi
    return 0
}

do_stop_internal() {
    _stopped=0

    if [ -f "${PID_FILE}" ]; then
        _daemon_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [ -n "${_daemon_pid}" ] && kill -0 "${_daemon_pid}" 2>/dev/null; then
            _child_pids="$(pgrep -P "${_daemon_pid}" mihomo 2>/dev/null || true)"
            if [ -n "${_child_pids}" ]; then
                kill ${_child_pids} 2>/dev/null || true
            fi
            kill "${_daemon_pid}" 2>/dev/null || true
            _stopped=1

            for _ in 1 2 3 4 5 6 7 8 9 10; do
                _still_running=0
                if kill -0 "${_daemon_pid}" 2>/dev/null; then
                    _still_running=1
                fi
                for _p in ${_child_pids}; do
                    if kill -0 "${_p}" 2>/dev/null; then
                        _still_running=1
                        break
                    fi
                done
                [ "${_still_running}" -eq 0 ] && break
                sleep 1
            done

            if kill -0 "${_daemon_pid}" 2>/dev/null; then
                kill -KILL "${_daemon_pid}" 2>/dev/null || true
            fi
            for _p in ${_child_pids}; do
                if kill -0 "${_p}" 2>/dev/null; then
                    kill -KILL "${_p}" 2>/dev/null || true
                fi
            done
        fi
    fi

    _extra_pids="$(pgrep -f "${BIN} -d ${CONF_DIR}" 2>/dev/null || true)"
    if [ -n "${_extra_pids}" ]; then
        kill ${_extra_pids} 2>/dev/null || true
        _stopped=1
        sleep 1
        for _p in ${_extra_pids}; do
            if kill -0 "${_p}" 2>/dev/null; then
                kill -KILL "${_p}" 2>/dev/null || true
            fi
        done
    fi

    rm -f "${PID_FILE}"
    return 0
}

do_stop() {
    _curr_pid="$(get_current_pid)"
    set_state "STOPPING" "DIRECT" "${_curr_pid:-null}" "Service is stopping"

    # 透明代理模式：停机前先临时拆除传输层（flush 只拆 anchor+hev、不改模式意图），
    # 防 route-to 指向即将关闭的 7891（死端口黑洞）；重启后 do_start 仍按 transparent 幂等重挂
    if [ "$(transport_mode_now)" = "transparent" ] && [ -x "${TRANSPORT_MGR}" ]; then
        "${TRANSPORT_MGR}" flush || true
    fi

    do_stop_internal
    cleanup_routing_and_pf

    set_state "STOPPED" "DIRECT" null "Service is stopped"
    echo "Mihomo stopped."
    return 0
}

do_restart() {
    do_stop
    sleep 1
    do_start
}

do_reload() {
    _pid="$(get_current_pid)"
    if [ -z "${_pid}" ]; then
        echo "Mihomo is not running, starting instead."
        do_start
        return $?
    fi

    # Validate config before reload
    if ! "${BIN}" -t -d "${CONF_DIR}" -f "${CONF_FILE}" >> "${LOG_FILE}" 2>&1; then
        echo "Config reload aborted: configuration validation failed."
        return 1
    fi

    # Send SIGHUP or use External Controller API reload if available
    # Mihomo reloads config on SIGHUP
    if kill -HUP "${_pid}" 2>/dev/null; then
        echo "Sent SIGHUP to Mihomo (PID ${_pid})."
        sleep 1
        # SIGHUP 送达不代表配置已生效：以健康探测结果作为 reload 的真实结果。
        # 本文件 set -eu，必须用 || 承接，否则非 0 会直接退出而跳过 return
        do_healthcheck || return $?
        return 0
    else
        echo "Failed to send SIGHUP, restarting."
        do_restart
    fi
}

do_healthcheck() {
    _pid="$(get_current_pid)"
    if [ -z "${_pid}" ]; then
        if [ -f /etc/rc.conf.d/mihomo ]; then
            . /etc/rc.conf.d/mihomo
            if [ "${mihomo_enable:-YES}" = "NO" ] || [ "${mihomo_enable:-YES}" = "no" ]; then
                set_state "DISABLED" "DIRECT" null "Mihomo is disabled"
                echo "Mihomo is disabled."
                return 0
            fi
        fi
        set_state "STOPPED" "DIRECT" null "Mihomo is stopped"
        echo "Mihomo is stopped."
        return 1
    fi

    _tun_ok=0
    _api_ok=0

    # 端口探测复用 check_transport_ready：socks 模式下按 LAN 暴露开关匹配
    # 0.0.0.0/*:7891（开）或 127.0.0.1:7891（关）
    if check_transport_ready; then
        _tun_ok=1
    fi

    _api_addr="$(api_addr_now)"
    _api_host="${_api_addr% *}"
    _api_port="${_api_addr#* }"
    if curl -s -m 2 "http://${_api_host}:${_api_port}" >/dev/null 2>&1 || \
       api_listening "${_api_host}" "${_api_port}"; then
        _api_ok=1
    fi

    _tmode="$(transport_mode_now)"
    [ "${_tmode}" = "transparent" ] || _tmode="proxy"
    _mode="PROXY"
    [ "${_tmode}" = "transparent" ] && _mode="TRANSPARENT"

    if [ "${_tun_ok}" -eq 1 ] && [ "${_api_ok}" -eq 1 ]; then
        set_state "RUNNING" "${_mode}" "${_pid}" "Healthy ($(transport_name) UP, API UP)"
        echo "Mihomo is running (PID ${_pid}, $(transport_name) UP, API UP)."
        return 0
    elif [ "${_tun_ok}" -eq 1 ] && [ "${_api_ok}" -eq 0 ]; then
        set_state "DEGRADED" "${_mode}" "${_pid}" "Degraded ($(transport_name) UP, API DOWN)"
        echo "Mihomo is degraded (PID ${_pid}, $(transport_name) UP, API DOWN)."
        return 0
    elif [ "${_tun_ok}" -eq 0 ] && [ "${_api_ok}" -eq 1 ]; then
        set_state "DEGRADED" "DIRECT" "${_pid}" "Degraded ($(transport_name) DOWN, API UP)"
        echo "Mihomo is degraded (PID ${_pid}, $(transport_name) DOWN, API UP)."
        return 0
    else
        set_state "FAILED" "DIRECT" "${_pid}" "Unhealthy ($(transport_name) DOWN, API DOWN)"
        echo "Mihomo is unhealthy (PID ${_pid}, $(transport_name) DOWN, API DOWN)."
        return 1
    fi
}

do_status() {
    _pid="$(get_current_pid)"
    if [ -f "${STATE_FILE}" ]; then
        cat "${STATE_FILE}"
        echo ""
    fi

    if [ -n "${_pid}" ]; then
        echo "${NAME} is running as pid ${_pid}."
        return 0
    else
        echo "${NAME} is not running."
        return 1
    fi
}

do_failopen() {
    _reason="${2:-Emergency Fail-Open triggered}"
    _curr_pid="$(get_current_pid)"
    echo "==> Triggering Fail-Open bypass: ${_reason}"
    
    # 1. Terminate any stuck/zombie processes
    do_stop_internal || true

    # 2. 透明代理模式：停机后临时拆除传输层（flush 保留模式意图，健康恢复后 recover 可重挂），
    #    恢复直连（防 route-to 打向死端口）
    if [ "$(transport_mode_now)" = "transparent" ] && [ -x "${TRANSPORT_MGR}" ]; then
        "${TRANSPORT_MGR}" flush || true
    fi

    # 3. Cleanup TUN device & routing
    cleanup_routing_and_pf
    
    # 4. Mark state as FAILED in DIRECT fallback mode
    set_state "FAILED" "DIRECT" null "Fail-Open activated: ${_reason}"
    echo "Fail-Open completed. State: FAILED, Mode: DIRECT."
    return 0
}

case "${1:-status}" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_restart
        ;;
    reload)
        do_reload
        ;;
    healthcheck)
        do_healthcheck
        ;;
    failopen)
        do_failopen "$@"
        ;;
    status)
        do_status
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|reload|status|healthcheck|failopen}"
        exit 1
        ;;
esac
