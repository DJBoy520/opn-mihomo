#!/bin/sh
set -eu

SECRET_FILE="${MIHOMO_SECRET_FILE:-/usr/local/etc/mihomo/secret.key}"
CONFIG_FILE="${MIHOMO_CONFIG_FILE:-/usr/local/etc/mihomo/config.yaml}"
TEMPLATE_FILE="${MIHOMO_TEMPLATE_FILE:-/usr/local/etc/mihomo/sub/template_config.yaml}"
ENV_FILE="${MIHOMO_ENV_FILE:-/usr/local/etc/mihomo/sub/env}"
HEV_CONF="${MIHOMO_HEV_CONF:-/usr/local/etc/mihomo/hev.yaml}"

# 写密钥必须与订阅更新互斥：sub.sh 启动时把旧密钥读进内存，数分钟下载结束后
# 再合成配置；期间改密钥会被旧值覆盖回写。这里复用 sub_lib.sh 的同一把锁
# （同一路径、同一 mkdir + pid 协议），不得另造锁文件。
MIHOMO_LOCK_DIR="${MIHOMO_LOCK_DIR:-/var/run/mihomo-sub.lock}"
LOCK_HELD=0

# 安装初始化轮换用密钥策略：16 字符，字符集 [A-Za-z0-9]，且保证至少各含
# 一个大写字母、小写字母与数字。不含特殊字符，保证 sed 替换、YAML 双引号、
# env 单引号三种落地语境均无需转义（与 is_safe_custom_secret 白名单兼容）。
generate_secret() {
    _pw=""
    _tries=0
    while [ "$_tries" -lt 100 ]; do
        # 有限读取模式，绝不对无限源用 `tr | head` 流式截断：BSD tr 在 UTF-8
        # locale 下把 urandom 当多字节流解码几乎不产出（2026-10-24 VM 实锤）；
        # 且 pkg 安装环境（stdio=/dev/null）下无限源+head 截断的管道曾挂死在
        # pipe_read。head -c 128 先定长消费 urandom，全链必然终止。
        _pw="$(LC_ALL=C head -c 128 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 16 || true)"
        [ "${#_pw}" -eq 16 ] || { _tries=$((_tries + 1)); continue; }
        printf '%s' "$_pw" | grep -q '[A-Z]' || { _tries=$((_tries + 1)); continue; }
        printf '%s' "$_pw" | grep -q '[a-z]' || { _tries=$((_tries + 1)); continue; }
        printf '%s' "$_pw" | grep -q '[0-9]' || { _tries=$((_tries + 1)); continue; }
        printf '%s\n' "$_pw"
        return 0
    done
    echo "error: generate_secret failed to produce a compliant 16-char secret after 100 tries" >&2
    return 1
}

# 单次尝试占锁，语义与 sub_lib.sh 的 mihomo_lib_lock_acquire 完全一致
# （含持有者 PID 已死的陈旧锁自动清理），保证与 sub.sh 看到同一把锁
subscription_lock_try() {
    if mkdir "$MIHOMO_LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=1
        printf '%s\n' "$$" > "$MIHOMO_LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi
    _lock_pid="$(cat "$MIHOMO_LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$_lock_pid" ] && ! kill -0 "$_lock_pid" 2>/dev/null; then
        echo "警告：发现陈旧锁（持有者 PID $_lock_pid 已不存在），自动清理后重试。" >&2
        rm -rf "$MIHOMO_LOCK_DIR"
        if mkdir "$MIHOMO_LOCK_DIR" 2>/dev/null; then
            LOCK_HELD=1
            printf '%s\n' "$$" > "$MIHOMO_LOCK_DIR/pid" 2>/dev/null || true
            return 0
        fi
    fi
    return 1
}

# 订阅更新可持续数分钟：每 5 秒重试，最多等 120 秒
subscription_lock_acquire() {
    _waited=0
    while ! subscription_lock_try; do
        if [ "$_waited" -ge 120 ]; then
            echo "error: subscription update in progress, try again later" >&2
            return 1
        fi
        sleep 5
        _waited=$((_waited + 5))
    done
    return 0
}

subscription_lock_release() {
    if [ "${LOCK_HELD:-0}" = "1" ]; then
        rm -f "$MIHOMO_LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$MIHOMO_LOCK_DIR" 2>/dev/null || true
        LOCK_HELD=0
    fi
}

# hev.yaml 凭证与 config.yaml authentication 同步，语义与 transport_manager.sh
# 的 hev_sync_auth 一致（有 authentication 写首条 user:pass，无则清除）。
# secret 轮换后若不同步，LAN 暴露下 hev 仍用旧口令拨入会被拒，
# 而 transport_probe 读 config.yaml 照样报 ok。文件不存在则跳过。
sync_hev_auth() {
    [ -f "$HEV_CONF" ] || return 0

    _hev_pair=""
    if [ -r "$CONFIG_FILE" ]; then
        _hev_pair="$(awk '
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
        ' "$CONFIG_FILE" 2>/dev/null || true)"
    fi

    _tmp_hev="$(mktemp "${HEV_CONF}.sync.XXXXXX" 2>/dev/null || true)"
    [ -n "$_tmp_hev" ] || return 0

    if [ -n "$_hev_pair" ]; then
        if ! MIHOMO_HEV_AUTH_VAL="$_hev_pair" awk '
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
        ' "$HEV_CONF" > "$_tmp_hev"; then
            echo "error: failed to sync hev credentials in $HEV_CONF" >&2
            rm -f "$_tmp_hev"
            return 1
        fi
    else
        if ! awk '
            /^[^[:space:]]/ {
                in5 = ($0 ~ /^socks5:/) ? 1 : 0
            }
            in5 && /^[[:space:]]*(username|password):[[:space:]]*/ { next }
            { print }
        ' "$HEV_CONF" > "$_tmp_hev"; then
            echo "error: failed to clear hev credentials in $HEV_CONF" >&2
            rm -f "$_tmp_hev"
            return 1
        fi
    fi

    chmod 600 "$_tmp_hev" 2>/dev/null || true
    if cmp -s "$_tmp_hev" "$HEV_CONF"; then
        rm -f "$_tmp_hev"
        return 0
    fi
    if ! mv -f "$_tmp_hev" "$HEV_CONF"; then
        echo "error: failed to replace $HEV_CONF after credential sync" >&2
        rm -f "$_tmp_hev"
        return 1
    fi
    if [ -n "$_hev_pair" ] && ! grep -qF "password: ${_hev_pair#*:}" "$HEV_CONF"; then
        echo "error: verification failed for hev credential sync in $HEV_CONF" >&2
        return 1
    fi
    return 0
}

# 新密钥落盘 secret.key 并同步 config.yaml / 订阅模板 / sub/env 三处
# （订阅重合成与外部面板登录读的都是这三处，缺一处都会回退旧值）
# 每个文件写完立即校验，任一失败报出文件名并退出，不做回滚。
apply_secret_files() {
    _new_secret="$1"

    # secret.key：同目录临时文件 + chmod 0600 + mv 原子替换，读取方不会看到半截
    _secret_dir="$(dirname "$SECRET_FILE")"
    if ! mkdir -p "$_secret_dir"; then
        echo "error: failed to create directory for $SECRET_FILE" >&2
        return 1
    fi
    _tmp_secret="$(mktemp "$_secret_dir/.secret.XXXXXX")" || {
        echo "error: failed to create temporary file for $SECRET_FILE" >&2
        return 1
    }
    if ! printf "%s" "$_new_secret" > "$_tmp_secret"; then
        rm -f "$_tmp_secret"
        echo "error: failed to write $SECRET_FILE" >&2
        return 1
    fi
    if ! chmod 0600 "$_tmp_secret"; then
        rm -f "$_tmp_secret"
        echo "error: failed to chmod 0600 $SECRET_FILE" >&2
        return 1
    fi
    if ! mv -f "$_tmp_secret" "$SECRET_FILE"; then
        rm -f "$_tmp_secret"
        echo "error: failed to replace $SECRET_FILE" >&2
        return 1
    fi
    if [ "$(cat "$SECRET_FILE")" != "$_new_secret" ]; then
        echo "error: verification failed for $SECRET_FILE" >&2
        return 1
    fi

    # secret 经 0600 临时 sed 脚本传递，避免明文出现在 sed 的 argv；
    # 注意 argv 里的 b64 参数仍可被本机 root 读到（见 decode_b64 注释）
    _sed_script="$(mktemp)" || {
        echo "error: failed to create temporary sed script" >&2
        return 1
    }
    if ! chmod 0600 "$_sed_script"; then
        rm -f "$_sed_script"
        echo "error: failed to chmod temporary sed script" >&2
        return 1
    fi

    for _f in "$CONFIG_FILE" "$TEMPLATE_FILE"; do
        [ -f "$_f" ] || continue
        if ! chmod 0600 "$_f"; then
            echo "error: failed to chmod 0600 $_f" >&2
            rm -f "$_sed_script"
            return 1
        fi
        if ! printf 's/^secret:.*/secret: "%s"/\n' "$_new_secret" > "$_sed_script"; then
            echo "error: failed to write temporary sed script" >&2
            rm -f "$_sed_script"
            return 1
        fi
        if sed -i '' -f "$_sed_script" "$_f" 2>/dev/null; then
            :
        elif sed -i -f "$_sed_script" "$_f" 2>/dev/null; then
            :
        else
            echo "error: failed to update $_f" >&2
            rm -f "$_sed_script"
            return 1
        fi
        # 行缺失时补写（YAML 顶级键，列 0 追加合法）；末行无换行时先补换行，
        # 否则新键会拼到上一行末尾，整份 YAML 失效
        if ! grep -q '^secret:' "$_f"; then
            if [ -s "$_f" ] && [ -n "$(tail -c 1 "$_f")" ]; then
                if ! printf '\n' >> "$_f"; then
                    echo "error: failed to append newline to $_f" >&2
                    rm -f "$_sed_script"
                    return 1
                fi
            fi
            if ! printf 'secret: "%s"\n' "$_new_secret" >> "$_f"; then
                echo "error: failed to append secret to $_f" >&2
                rm -f "$_sed_script"
                return 1
            fi
        fi
        if ! grep -qF "secret: \"$_new_secret\"" "$_f"; then
            echo "error: verification failed for $_f" >&2
            rm -f "$_sed_script"
            return 1
        fi
    done

    # authentication 块口令联动：LAN 暴露注入的 SOCKS 凭证与 API secret 同值
    # （sub_lib.sh compose 注入 - "user:<secret>"）。只改 config.yaml 的列表项
    # 密码段、保留用户名；模板不在此列（compose 会在下次重组合时读 env 注入新值）。
    # 原子替换，写失败不回滚（与上方文件同一策略），但绝不留下半截文件。
    if [ -f "$CONFIG_FILE" ] && grep -q '^authentication:' "$CONFIG_FILE"; then
        _tmp_auth="$(mktemp "$(dirname "$CONFIG_FILE")/.auth.XXXXXX")" || {
            echo "error: failed to create temporary file for authentication sync" >&2
            rm -f "$_sed_script"
            return 1
        }
        if ! MIHOMO_ROTATE_AUTH_PASS="$_new_secret" awk '
            BEGIN { nv = ENVIRON["MIHOMO_ROTATE_AUTH_PASS"] }
            /^[^[:space:]#]/ { in_auth = ($0 ~ /^authentication:/) ? 1 : 0 }
            in_auth && /^[[:space:]]*-[[:space:]]*"[^"]*"/ {
                line = $0
                if (match(line, /"[^"]*"/)) {
                    head = substr(line, 1, RSTART)
                    tail = substr(line, RSTART + RLENGTH - 1)
                    pair = substr(line, RSTART + 1, RLENGTH - 2)
                    n = index(pair, ":")
                    user = (n > 1) ? substr(pair, 1, n - 1) : pair
                    printf "%s%s:%s%s\n", head, user, nv, tail
                    next
                }
            }
            { print }
        ' "$CONFIG_FILE" > "$_tmp_auth"; then
            echo "error: failed to sync authentication password in $CONFIG_FILE" >&2
            rm -f "$_tmp_auth"
            rm -f "$_sed_script"
            return 1
        fi
        if ! chmod 0600 "$_tmp_auth"; then
            echo "error: failed to chmod 0600 authentication temp file" >&2
            rm -f "$_tmp_auth"
            rm -f "$_sed_script"
            return 1
        fi
        if ! mv -f "$_tmp_auth" "$CONFIG_FILE"; then
            echo "error: failed to replace $CONFIG_FILE after authentication sync" >&2
            rm -f "$_tmp_auth"
            rm -f "$_sed_script"
            return 1
        fi
        if ! grep -qF ":$_new_secret\"" "$CONFIG_FILE"; then
            echo "error: verification failed for authentication sync in $CONFIG_FILE" >&2
            rm -f "$_sed_script"
            return 1
        fi
    fi

    # hev.yaml 凭证同步：必须排在 authentication 联动之后，读到的才是新口令
    if ! sync_hev_auth; then
        rm -f "$_sed_script"
        return 1
    fi

    if [ -f "$ENV_FILE" ]; then
        if ! chmod 0600 "$ENV_FILE"; then
            echo "error: failed to chmod 0600 $ENV_FILE" >&2
            rm -f "$_sed_script"
            return 1
        fi
        if ! printf "s/^mihomo_secret=.*/mihomo_secret='%s'/\n" "$_new_secret" > "$_sed_script"; then
            echo "error: failed to write temporary sed script" >&2
            rm -f "$_sed_script"
            return 1
        fi
        if sed -i '' -f "$_sed_script" "$ENV_FILE" 2>/dev/null; then
            :
        elif sed -i -f "$_sed_script" "$ENV_FILE" 2>/dev/null; then
            :
        else
            echo "error: failed to update $ENV_FILE" >&2
            rm -f "$_sed_script"
            return 1
        fi
        # 行缺失时补写（env 为 POSIX 单引号赋值格式，与 env.sample 一致）
        if ! grep -q '^mihomo_secret=' "$ENV_FILE"; then
            if [ -s "$ENV_FILE" ] && [ -n "$(tail -c 1 "$ENV_FILE")" ]; then
                if ! printf '\n' >> "$ENV_FILE"; then
                    echo "error: failed to append newline to $ENV_FILE" >&2
                    rm -f "$_sed_script"
                    return 1
                fi
            fi
            if ! printf "mihomo_secret='%s'\n" "$_new_secret" >> "$ENV_FILE"; then
                echo "error: failed to append secret to $ENV_FILE" >&2
                rm -f "$_sed_script"
                return 1
            fi
        fi
        if ! grep -qF "mihomo_secret='$_new_secret'" "$ENV_FILE"; then
            echo "error: verification failed for $ENV_FILE" >&2
            rm -f "$_sed_script"
            return 1
        fi
    fi
    rm -f "$_sed_script"
    return 0
}

# configd 对 %s 参数做 shell 展开：set 子命令只接受 b64: 前缀，目的是让密钥
# 里的 shell 元字符不参与解释，不是保密手段——base64 可逆，且该参数仍会以
# 编码形式出现在进程 argv 中（需本机 root 权限才能读取其他用户的 ps 参数）。
# CLI 侧 base64(1) 按 76 列折行，先剥离全部空白再解码。解码结果写到 stdout。
decode_b64() {
    _clean="$(printf '%s' "$1" | tr -d ' \n\r\t')"
    _decoded="$(printf '%s' "$_clean" | base64 -d 2>/dev/null)" && { printf '%s' "$_decoded"; return 0; }
    _decoded="$(printf '%s' "$_clean" | openssl base64 -d -A 2>/dev/null)" && { printf '%s' "$_decoded"; return 0; }
    return 1
}

# 自定义密钥白名单：字母数字 + . _ ~ @ # % ^ + = : ; , ! ? * -
# 排除引号/反引号/$/&/\/|/空格/控制字符，保证 sed 替换、YAML 双引号、
# env 单引号三种落地语境均无需转义。
# 注意：不能写成 case 括号模式——dash 词法层会把 [..;..] 里的分号当分隔符
is_safe_custom_secret() {
    [ -n "$1" ] || return 1
    _residue="$(printf '%s' "$1" | tr -d 'A-Za-z0-9._~@#%^+=:;,!?*-')"
    [ -z "$_residue" ]
}

# 从 config.yaml 回退提取密钥：行内注释由尾部 .* 吃掉，
# 否则 `secret: "key" # comment` 会提取出 `key # comment`
extract_secret_from_config() {
    sed -n 's/^secret:[[:space:]]*["'\'']*\([^"'\'']*\)["'\'']*.*/\1/p' "$CONFIG_FILE"
}

cmd="${1:-get}"

case "$cmd" in
    generate|regen|rotate)
        NEW_SECRET="$(generate_secret)"
        trap 'subscription_lock_release' EXIT INT TERM
        if ! subscription_lock_acquire; then
            exit 1
        fi
        apply_secret_files "$NEW_SECRET"
        echo "OK: secret generated and secured"
        ;;
    set)
        RAW_ARG="${2:-}"
        if [ "${RAW_ARG#b64:}" = "$RAW_ARG" ] || [ -z "$RAW_ARG" ]; then
            echo "error: set requires a b64:-prefixed argument" >&2
            exit 1
        fi
        if ! NEW_SECRET="$(decode_b64 "${RAW_ARG#b64:}")" || [ -z "$NEW_SECRET" ]; then
            echo "error: secret base64 decode failed" >&2
            exit 1
        fi
        LEN="${#NEW_SECRET}"
        if [ "$LEN" -lt 4 ] || [ "$LEN" -gt 128 ]; then
            echo "error: secret length must be 4-128 characters" >&2
            exit 1
        fi
        if ! is_safe_custom_secret "$NEW_SECRET"; then
            echo "error: secret contains characters outside the allowed set" >&2
            exit 1
        fi
        trap 'subscription_lock_release' EXIT INT TERM
        if ! subscription_lock_acquire; then
            exit 1
        fi
        apply_secret_files "$NEW_SECRET"
        echo "OK: secret updated and secured"
        ;;
    get)
        if [ -s "$SECRET_FILE" ]; then
            cat "$SECRET_FILE"
        elif [ -f "$CONFIG_FILE" ]; then
            extract_secret_from_config
        else
            echo ""
        fi
        ;;
    masked|sanitize)
        if [ -s "$SECRET_FILE" ]; then
            SECRET_VAL="$(cat "$SECRET_FILE")"
        elif [ -f "$CONFIG_FILE" ]; then
            SECRET_VAL="$(extract_secret_from_config)"
        else
            SECRET_VAL=""
        fi
        if [ -z "$SECRET_VAL" ]; then
            echo "NOT_CONFIGURED"
        else
            len="${#SECRET_VAL}"
            if [ "$len" -ge 32 ]; then
                prefix="$(printf '%s' "$SECRET_VAL" | cut -c 1-4)"
                echo "${prefix}************************************"
            else
                echo "****************************************"
            fi
        fi
        ;;
    *)
        echo "usage: $0 generate|set|get|masked" >&2
        exit 1
        ;;
esac
