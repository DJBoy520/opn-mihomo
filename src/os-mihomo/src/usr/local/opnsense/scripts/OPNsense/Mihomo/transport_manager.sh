#!/bin/sh
set -eu

# transport_manager.sh - 透明代理传输层管理栈
# 用法：transport_manager.sh {enable|disable|flush|status|recover|hev-sync}
# 管理 mihomo-transport PF anchor 与 hev-socks5-tunnel (tun0) 状态
# enable/disable/flush/recover/hev-sync 互斥（mkdir 锁，等待上限 60 秒）

ANCHOR="mihomo-transport"
MODE_FILE="/var/db/os-mihomo/transport-mode"
PF_TEMPLATE="/usr/local/etc/mihomo/pf-transport.conf"
RENDER="/usr/local/opnsense/scripts/OPNsense/Mihomo/transport_render.php"
PROBE="/usr/local/opnsense/scripts/OPNsense/Mihomo/transport_probe.php"
ACTIVE="/var/db/os-mihomo/pf-transport.active.conf"
HEV_RC="/usr/local/etc/rc.d/mihomo_hev"
HEV_CONF="/usr/local/etc/mihomo/hev.yaml"
HEV_SAMPLE="/usr/local/etc/mihomo/hev.yaml.sample"
PHP="/usr/local/bin/php"
CONF_FILE="/usr/local/etc/mihomo/config.yaml"

TUN_DEV="${MIHOMO_TUN_DEV:-tun0}"
HEV_PIDFILE="/var/run/mihomo_hev.pid"

# 传输层互斥锁：复用 secret_manager.sh / sub_lib.sh 的 mkdir + pid 协议。
# disable 与 recover/enable 交错会留下 anchor 已装载但 mode=proxy 的自愈不了残留。
TRANSPORT_LOCK_DIR="${MIHOMO_TRANSPORT_LOCK_DIR:-/var/run/mihomo-transport.lock}"
TRANSPORT_LOCK_HELD=0
TRANSPORT_LOCK_WAIT=60

# 单次尝试占锁；目录已存在时只有持有者 PID 确已消失才按陈旧锁回收
transport_lock_try() {
    if mkdir "${TRANSPORT_LOCK_DIR}" 2>/dev/null; then
        TRANSPORT_LOCK_HELD=1
        printf '%s\n' "$$" > "${TRANSPORT_LOCK_DIR}/pid" 2>/dev/null || true
        return 0
    fi
    _lock_pid="$(cat "${TRANSPORT_LOCK_DIR}/pid" 2>/dev/null || true)"
    if [ -n "${_lock_pid}" ] && ! kill -0 "${_lock_pid}" 2>/dev/null; then
        echo "警告：发现陈旧传输层锁（持有者 PID ${_lock_pid} 已不存在），自动清理后重试。" >&2
        rm -rf "${TRANSPORT_LOCK_DIR}"
        if mkdir "${TRANSPORT_LOCK_DIR}" 2>/dev/null; then
            TRANSPORT_LOCK_HELD=1
            printf '%s\n' "$$" > "${TRANSPORT_LOCK_DIR}/pid" 2>/dev/null || true
            return 0
        fi
    fi
    return 1
}

# 锁等待上限 60 秒；超时报错退出，绝不无锁继续
transport_lock_acquire() {
    _waited=0
    while ! transport_lock_try; do
        if [ "${_waited}" -ge "${TRANSPORT_LOCK_WAIT}" ]; then
            echo "错误：另一传输层操作正在进行（等待锁 ${TRANSPORT_LOCK_DIR} 超过 ${TRANSPORT_LOCK_WAIT} 秒）" >&2
            return 1
        fi
        sleep 1
        _waited=$((_waited + 1))
    done
    return 0
}

transport_lock_release() {
    if [ "${TRANSPORT_LOCK_HELD:-0}" = "1" ]; then
        rm -f "${TRANSPORT_LOCK_DIR}/pid" 2>/dev/null || true
        rmdir "${TRANSPORT_LOCK_DIR}" 2>/dev/null || true
        TRANSPORT_LOCK_HELD=0
    fi
}

# 检查当前父进程 SSH 会话是否存活
# PPID 为 1 (init/launchd) 或 0 时视为存活；否则 kill -0 探测
ssh_alive() {
    _ppid="${PPID:-1}"
    if [ "${_ppid}" -le 1 ] 2>/dev/null; then
        return 0
    fi
    kill -0 "${_ppid}" 2>/dev/null
}

# API 监听地址正则（§2.3 门禁级）：从 config.yaml 原始解析（不归一化），
# 0.0.0.0 → (\*|0.0.0.0):port；接口 IP → <bind>:port；127.0.0.1 → 仅回环。
# 解析失败回退到默认端口的三态匹配，避免门禁因配置文件暂不可读而误拒。
api_listen_regex() {
    _api_raw=""
    if [ -r "${CONF_FILE}" ]; then
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
              if (n == 2 && p[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
                  p[2] ~ /^[0-9]+$/ &&
                  (p[2] + 0) >= 1 && (p[2] + 0) <= 65535) {
                  print p[1], p[2]
                  found = 1
              }
              exit
          }
        ' "${CONF_FILE}" 2>/dev/null || true)"
    fi
    if [ -z "${_api_raw}" ]; then
        printf '%s\n' '(127\.0\.0\.1|\*|0\.0\.0\.0):9090([[:space:]]|$)'
        return 0
    fi
    _api_host="${_api_raw% *}"
    _api_port="${_api_raw#* }"
    if [ "${_api_host}" = "0.0.0.0" ]; then
        printf '%s\n' '(\*|0\.0\.0\.0):'"${_api_port}"'([[:space:]]|$)'
    else
        _api_host_re="$(printf '%s' "${_api_host}" | sed 's/\./\\./g')"
        printf '%s\n' "${_api_host_re}:${_api_port}([[:space:]]|$)"
    fi
}

# 检查 mihomo 关键服务健康状态（7891、1053、external-controller 监听）
mihomo_healthy() {
    # sockstat 不带 -4：tcp46 通配绑定在 -4 视图下可能缺失
    _sockstat="$(sockstat -l 2>/dev/null || true)"
    [ -n "${_sockstat}" ] || return 1
    printf "%s\n" "${_sockstat}" | grep -E -q "(127\.0\.0\.1|\*|0\.0\.0\.0):7891([[:space:]]|$)" || return 1
    printf "%s\n" "${_sockstat}" | grep -E -q "(127\.0\.0\.1|\*|0\.0\.0\.0):1053([[:space:]]|$)" || return 1
    _api_re="$(api_listen_regex)"
    printf "%s\n" "${_sockstat}" | grep -E -q "${_api_re}" || return 1
    return 0
}

# 统计 anchor 规则数，失败时安全返回 0
anchor_rule_count() {
    _rules="$(pfctl -a "${ANCHOR}" -sr 2>/dev/null || true)"
    if [ -z "${_rules}" ]; then
        echo 0
    else
        # grep -c 在无匹配时输出 0 且退出码非 0：|| true 防 set -e，避免再补一个 0
        _count="$(printf "%s\n" "${_rules}" | grep -c . || true)"
        echo "${_count:-0}"
    fi
}

# 检查 hev 守护进程是否存活
hev_running() {
    [ -f "${HEV_PIDFILE}" ] || return 1
    _hpid="$(cat "${HEV_PIDFILE}" 2>/dev/null || true)"
    [ -n "${_hpid}" ] || return 1
    kill -0 "${_hpid}" 2>/dev/null
}

# 检查 tun 设备是否存在
tun_ready() {
    ifconfig "${TUN_DEV}" >/dev/null 2>&1
}

# hev.yaml 与 config.yaml authentication 双向同步（fixB）
# config.yaml 存在 authentication → 首条 "user:pass" 写入 hev.yaml socks5.username/password
# config.yaml 无 authentication → 清除 hev.yaml 中的 username/password
# （hev 固定从 127.0.0.1 拨入 mihomo，两侧凭证不一致会被 ACL/鉴权静默掐断）
# 返回 0=hev.yaml 未变化，1=已更新（调用方据此重启 hev）
hev_sync_auth() {
    [ -f "${HEV_CONF}" ] || return 0

    _auth_pair=""
    if [ -r "${CONF_FILE}" ]; then
        _auth_pair="$(awk '
            /^[[:space:]]*authentication:/ {
                if ($0 ~ /\[\]/) { exit }
                in_auth = 1
                next
            }
            in_auth && /^[^[:space:]#-]/ { exit }
            in_auth && /^[[:space:]]*-[[:space:]]*/ {
                line = $0
                sub(/^[[:space:]]*-[[:space:]]*/, "", line)
                sub(/[[:space:]]+#.*$/, "", line)
                gsub(/"/, "", line)
                gsub(/[[:space:]]+$/, "", line)
                if (line != "") {
                    print line
                    exit
                }
            }
        ' "${CONF_FILE}" 2>/dev/null || true)"
    fi

    _tmp_hev="$(mktemp "${HEV_CONF}.sync.XXXXXX" 2>/dev/null || true)"
    [ -n "${_tmp_hev}" ] || return 0

    if [ -n "${_auth_pair}" ]; then
        # fixB-awk-inject-begin
        MIHOMO_HEV_AUTH_VAL="${_auth_pair}" awk '
            BEGIN {
                v = ENVIRON["MIHOMO_HEV_AUTH_VAL"]
                n = index(v, ":")
                u = (n > 1) ? substr(v, 1, n - 1) : v
                p = (n > 1) ? substr(v, n + 1) : ""
                in5 = 0
                buf = ""
                emitted = 0
            }
            function flush5() {
                if (!emitted) {
                    printf "  username: %s\n  password: %s\n", u, p
                    emitted = 1
                }
                printf "%s", buf
                buf = ""
            }
            /^[^[:space:]]/ {
                if (in5) {
                    flush5()
                }
                in5 = ($0 ~ /^socks5:/) ? 1 : 0
                print
                next
            }
            in5 && /^[[:space:]]*(username|password):[[:space:]]*/ { next }
            in5 {
                buf = buf $0 "\n"
                next
            }
            { print }
            END {
                if (in5) {
                    flush5()
                }
            }
        ' "${HEV_CONF}" > "${_tmp_hev}" || { rm -f "${_tmp_hev}"; return 0; }
        # fixB-awk-inject-end
    else
        # fixB-awk-strip-begin
        awk '
            /^[^[:space:]]/ {
                in5 = ($0 ~ /^socks5:/) ? 1 : 0
            }
            in5 && /^[[:space:]]*(username|password):[[:space:]]*/ { next }
            { print }
        ' "${HEV_CONF}" > "${_tmp_hev}" || { rm -f "${_tmp_hev}"; return 0; }
        # fixB-awk-strip-end
    fi

    if cmp -s "${_tmp_hev}" "${HEV_CONF}"; then
        rm -f "${_tmp_hev}"
        return 0
    fi
    chmod 600 "${_tmp_hev}" 2>/dev/null || true
    mv -f "${_tmp_hev}" "${HEV_CONF}"
    return 1
}

# 渲染并校验 PF 规则集
render_rules() {
    if [ ! -x "${PHP}" ] || [ ! -f "${RENDER}" ]; then
        echo "错误：PHP 解释器 (${PHP}) 或渲染脚本 (${RENDER}) 不可用" >&2
        return 1
    fi

    _tmp_active="${ACTIVE}.tmp.$$"
    rm -f "${_tmp_active}"

    if ! "${PHP}" "${RENDER}" rules > "${_tmp_active}" 2>/dev/null; then
        echo "错误：规则渲染执行失败" >&2
        rm -f "${_tmp_active}"
        return 1
    fi

    # 校验：文件非空
    if [ ! -s "${_tmp_active}" ]; then
        echo "错误：渲染出的规则集为空" >&2
        rm -f "${_tmp_active}"
        return 1
    fi

    # 校验：必须包含 route-to 规则
    if ! grep -q "route-to" "${_tmp_active}"; then
        echo "错误：渲染出的规则集缺少 route-to 规则" >&2
        rm -f "${_tmp_active}"
        return 1
    fi

    # 校验：严禁包含以 block 或 reject 开头的行（防锁死管理员）
    if grep -Eiq '^[[:space:]]*(block|reject)([[:space:]]|$)' "${_tmp_active}"; then
        echo "错误：渲染出的规则集包含禁止的 block/reject 规则" >&2
        rm -f "${_tmp_active}"
        return 1
    fi

    chmod 600 "${_tmp_active}"
    mv -f "${_tmp_active}" "${ACTIVE}"
    return 0
}

# 写入模式标记文件（原子更新）
set_mode() {
    _mode="$1"
    mkdir -p /var/db/os-mihomo 2>/dev/null || true
    _tmp_mode="${MODE_FILE}.tmp.$$"
    printf "%s\n" "${_mode}" > "${_tmp_mode}"
    chmod 600 "${_tmp_mode}" 2>/dev/null || true
    mv -f "${_tmp_mode}" "${MODE_FILE}"
}

# disable 流程（幂等，任何情况下都 exit 0）
do_disable() {
    # 1. 清空 anchor 规则集，绝不碰主规则集
    # pfctl -a mihomo-transport
    pfctl -a "${ANCHOR}" -F all 2>/dev/null || true

    # 2. 停止 hev 守护进程
    if [ -x "${HEV_RC}" ]; then
        "${HEV_RC}" stop 2>/dev/null || true
    fi

    # 3. 清理已激活的规则文件
    rm -f "${ACTIVE}"

    # 4. 记录模式为 proxy
    set_mode "proxy"

    echo "透明代理传输层已禁用 (普通代理模式)"
    exit 0
}

# flush 流程（幂等，任何情况下都 exit 0）
# 与 disable 的唯一区别：不改写 MODE_FILE。模式文件表达的是面板/模型的意图，
# service_manager 停机与 watchdog fail-open 用 flush 拆传输层后，
# do_start / recover 仍能按 transparent 意图幂等重挂。
do_flush() {
    pfctl -a "${ANCHOR}" -F all 2>/dev/null || true
    if [ -x "${HEV_RC}" ]; then
        "${HEV_RC}" stop 2>/dev/null || true
    fi
    rm -f "${ACTIVE}"
    echo "透明代理传输层已临时拆除 (模式意图保留)"
    exit 0
}

# enable 流程（顺序严格执行）
do_enable() {
    # 步骤 1：记录模式意图为 transparent（原子写入）
    set_mode "transparent"

    # 步骤 1.5：hev.yaml 凭证与 config.yaml authentication 同步（fixB，幂等）。
    # 覆盖 restart/恢复路径：hev 已在运行而凭证过期（secret 轮换、重组后）时，
    # 重启 hev 使同步后的凭证生效；tun0 随之重建，由下方全流程重新等待就绪。
    _hev_changed=0
    hev_sync_auth || _hev_changed=1
    if [ "${_hev_changed}" = "1" ] && hev_running; then
        "${HEV_RC}" restart >/dev/null 2>&1 || true
        sleep 1
    fi

    # 步骤 2：幂等短路检查
    _cur_rules="$(anchor_rule_count)"
    if [ "${_cur_rules}" -gt 0 ] && hev_running && tun_ready; then
        echo "透明代理传输层已处于启用状态"
        exit 0
    fi

    # 步骤 3：mihomo 健康门禁（失败退出但不回滚 MODE_FILE，待 recover 修复）
    if ! mihomo_healthy; then
        echo "错误：mihomo 核心服务健康门禁未通过 (7891/1053/external-controller 监听未就绪)" >&2
        exit 1
    fi

    # 步骤 4：初始化并启动 hev
    if [ ! -f "${HEV_CONF}" ]; then
        if [ -f "${HEV_SAMPLE}" ]; then
            cp -f "${HEV_SAMPLE}" "${HEV_CONF}"
            chmod 600 "${HEV_CONF}"
        else
            echo "错误：找不到 hev 配置文件模板 ${HEV_SAMPLE}" >&2
            exit 1
        fi
    fi

    # fixB：hev.yaml 就绪后同步凭证（覆盖全新安装路径：sample 装入后立刻回写）
    hev_sync_auth || true

    kldload if_tun 2>/dev/null || true

    if [ ! -x "${HEV_RC}" ]; then
        echo "错误：找不到可执行的 ${HEV_RC}" >&2
        exit 1
    fi

    if ! "${HEV_RC}" start; then
        echo "错误：启动 hev 服务失败" >&2
        exit 1
    fi

    # 步骤 5：轮询 tun 接口就绪，最长 10 秒
    _wait=0
    _tun_ok=0
    while [ "${_wait}" -lt 10 ]; do
        if tun_ready; then
            _tun_ok=1
            break
        fi
        sleep 1
        _wait=$((_wait + 1))
    done

    if [ "${_tun_ok}" -ne 1 ]; then
        echo "错误：等待虚拟网卡 ${TUN_DEV} 就绪超时" >&2
        "${HEV_RC}" stop 2>/dev/null || true
        exit 1
    fi

    # 步骤 6：渲染规则并检查 SSH 存活
    if ! render_rules; then
        echo "错误：生成 PF 传输层规则失败" >&2
        "${HEV_RC}" stop 2>/dev/null || true
        exit 1
    fi

    if ! ssh_alive; then
        echo "警告：检测到 SSH 会话断开，立即执行回滚" >&2
        do_disable
        exit 1
    fi

    # 步骤 7：加载规则到 anchor 并验证加载结果
    # pfctl -a mihomo-transport
    if ! pfctl -a "${ANCHOR}" -f "${ACTIVE}"; then
        echo "错误：加载 PF 规则到 anchor ${ANCHOR} 失败" >&2
        do_disable
        exit 1
    fi

    _loaded_rules="$(anchor_rule_count)"
    if [ "${_loaded_rules}" -le 0 ]; then
        echo "错误：anchor ${ANCHOR} 加载后规则集为空，立即回滚" >&2
        do_disable
        exit 1
    fi

    # 步骤 8：最终 SSH 存活断言
    if ! ssh_alive; then
        echo "警告：加载规则后 SSH 探测失败，安全回滚" >&2
        do_disable
        exit 1
    fi

    # 输出启用成功摘要
    _lan_info=""
    if [ -x "${PHP}" ] && [ -f "${RENDER}" ]; then
        _lan_info="$("${PHP}" "${RENDER}" lan-net 2>/dev/null || true)"
    fi
    echo "透明代理传输层启用成功 [TUN: ${TUN_DEV}, 网段: ${_lan_info:-LAN}, 规则数: ${_loaded_rules}]"
    exit 0
}

# recover 流程
do_recover() {
    # 1. 检查 MODE_FILE 是否为 transparent
    _mode="unknown"
    if [ -f "${MODE_FILE}" ]; then
        _mode="$(cat "${MODE_FILE}" 2>/dev/null || echo "unknown")"
    fi

    if [ "${_mode}" != "transparent" ]; then
        exit 0
    fi

    # 2. 健康判据必须三者齐备：hev 进程存活 + tun 设备在 + anchor 有规则。
    #    只看规则数时，hev 崩溃或 tun0 消失而 anchor 仍挂着，LAN 流量会被
    #    route-to 送进死接口（transport_probe 走 127.0.0.1 完全看不出来）。
    _cur_rules="$(anchor_rule_count)"
    if [ "${_cur_rules}" -gt 0 ] && hev_running && tun_ready; then
        exit 0
    fi

    # 3. tun 消失但 hev 进程仍在：rc.d start 会因 pidfile 存活而短路，无法重建
    #    tun0，先重启一次 hev，使下面的 enable 一次收敛。
    if hev_running && ! tun_ready && [ -x "${HEV_RC}" ]; then
        "${HEV_RC}" restart >/dev/null 2>&1 || true
        sleep 1
    fi

    # 4. 三者不齐：mihomo 核心健康就走 enable 补挂（enable 内部会启动 hev、
    #    重建 tun0 并重新装载 anchor）；核心不健康时保持直连，由 watchdog 处理。
    if mihomo_healthy; then
        do_enable >/dev/null 2>&1 || true
    fi

    exit 0
}

# hev-sync 流程：面板/外部轮换 secret 后同步 hev.yaml 凭证。
# 凭证只在 hev 启动时读取，因此 hev 正在运行就必须重启才生效；未运行只写文件。
do_hev_sync() {
    if [ ! -f "${HEV_CONF}" ]; then
        echo "hev.yaml 不存在，跳过凭证同步（透明代理尚未初始化）"
        exit 0
    fi
    hev_sync_auth || true
    if ! hev_running; then
        echo "hev 未运行，凭证已写入 hev.yaml（下次启动生效）"
        exit 0
    fi
    if [ ! -x "${HEV_RC}" ]; then
        echo "错误：找不到可执行的 ${HEV_RC}，无法重启 hev 使新凭证生效" >&2
        exit 1
    fi
    if ! "${HEV_RC}" restart >/dev/null 2>&1; then
        echo "错误：hev 凭证已同步但重启失败，当前进程仍使用旧凭证" >&2
        exit 1
    fi
    echo "hev 凭证已同步并重启生效"
    exit 0
}

# status 流程
do_status() {
    _mode="unknown"
    if [ -f "${MODE_FILE}" ]; then
        _mode="$(cat "${MODE_FILE}" 2>/dev/null || echo "unknown")"
    fi

    _rule_cnt="$(anchor_rule_count)"

    _hev_pid="-"
    if [ -f "${HEV_PIDFILE}" ]; then
        _hpid="$(cat "${HEV_PIDFILE}" 2>/dev/null || true)"
        if [ -n "${_hpid}" ] && kill -0 "${_hpid}" 2>/dev/null; then
            _hev_pid="${_hpid}"
        fi
    fi

    _tun_status="down"
    if tun_ready; then
        _tun_status="up"
    fi

    printf "Mode: %s\n" "${_mode}"
    printf "Anchor rules: %s\n" "${_rule_cnt}"
    printf "HEV PID: %s\n" "${_hev_pid}"
    printf "TUN (%s): %s\n" "${TUN_DEV}" "${_tun_status}"

    # 端到端数据面探针（fixB）：组件全绿 ≠ 链路可用（ACL/鉴权掐断时上方仍全绿）。
    # hev 与 LAN 客户端共用 127.0.0.1:7891 入口，探针通过即代表 ACL/鉴权/核心全通。
    _probe_out=""
    if [ -x "${PHP}" ] && [ -f "${PROBE}" ]; then
        _probe_out="$("${PHP}" "${PROBE}" 2>/dev/null || true)"
    fi
    printf "%s\n" "${_probe_out:-SOCKS probe: unknown (probe unavailable)}"
    exit 0
}

# 写操作全程持锁；do_enable 回滚时内部调用 do_disable，锁只在调度层加，
# 避免嵌套加锁自死锁。status 只读不加锁。
with_transport_lock() {
    trap 'transport_lock_release' EXIT INT TERM
    if ! transport_lock_acquire; then
        exit 1
    fi
    "$@"
}

case "${1:-status}" in
    enable)
        with_transport_lock do_enable
        ;;
    disable)
        with_transport_lock do_disable
        ;;
    flush)
        with_transport_lock do_flush
        ;;
    status)
        do_status
        ;;
    recover)
        with_transport_lock do_recover
        ;;
    hev-sync)
        with_transport_lock do_hev_sync
        ;;
    *)
        echo "Usage: $0 {enable|disable|flush|status|recover|hev-sync}"
        exit 1
        ;;
esac
