#!/bin/sh
# Mihomo 订阅合成函数库
# 提供加锁、解脱、URL 脱敏、节点提取、配置合成、缓存持久化与状态记录等共享能力。
# 本文件仅供 source 引入，source 时零副作用。

MIHOMO_LOCK_DIR="${MIHOMO_LOCK_DIR:-/var/run/mihomo-sub.lock}"
MIHOMO_STRATEGY_MODE_FILE="${MIHOMO_STRATEGY_MODE_FILE:-/var/db/os-mihomo/strategy-mode}"
MIHOMO_STRATEGY_FILE="${MIHOMO_STRATEGY_FILE:-/var/db/os-mihomo/subscription-strategy.yaml}"
# 本次合成的策略输入（sub.sh 用临时片段）；为空时 compose 读取持久缓存 MIHOMO_STRATEGY_FILE
MIHOMO_STRATEGY_INPUT_FILE="${MIHOMO_STRATEGY_INPUT_FILE:-}"
MIHOMO_TEMPLATE_FILE="${MIHOMO_TEMPLATE_FILE:-/usr/local/etc/mihomo/sub/template_config.yaml}"
MIHOMO_RULES_FILE="${MIHOMO_RULES_FILE:-/usr/local/etc/mihomo/custom-rules.txt}"
MIHOMO_PANEL_STATE_FILE="${MIHOMO_PANEL_STATE_FILE:-/var/db/os-mihomo/panel-state.env}"
MIHOMO_STATUS_FILE="${MIHOMO_STATUS_FILE:-/var/db/os-mihomo/last-sub-update.json}"
MIHOMO_CACHE_FILE="${MIHOMO_CACHE_FILE:-/var/db/os-mihomo/subscription-cache.yaml}"
MIHOMO_SECRET_MANAGER="${MIHOMO_SECRET_MANAGER:-/usr/local/opnsense/scripts/OPNsense/Mihomo/secret_manager.sh}"
MIHOMO_ATOMIC_UPDATER="${MIHOMO_ATOMIC_UPDATER:-/usr/local/opnsense/scripts/OPNsense/Mihomo/atomic_config_updater.sh}"
MIHOMO_BIN="${MIHOMO_BIN:-/usr/local/bin/mihomo}"
MIHOMO_CONF_DIR="${MIHOMO_CONF_DIR:-/usr/local/etc/mihomo}"
LOCK_HELD="${LOCK_HELD:-0}"

# 策略合成全局状态变量（供 sub.sh 或外部查询 compose 结果）
MIHOMO_COMPOSE_STRATEGY_USED=""
MIHOMO_COMPOSE_STRATEGY_GROUPS=0
MIHOMO_COMPOSE_STRATEGY_RULES=0

# 读取策略来源模式：subscription | template
mihomo_lib_strategy_mode() {
    _mode="${MIHOMO_STRATEGY_MODE:-}"
    if [ "$_mode" = "subscription" ] || [ "$_mode" = "template" ]; then
        printf '%s\n' "$_mode"
        return 0
    fi
    if [ -r "$MIHOMO_STRATEGY_MODE_FILE" ]; then
        _file_mode="$(head -n 1 "$MIHOMO_STRATEGY_MODE_FILE" 2>/dev/null | tr -d '\r\n')"
        if [ "$_file_mode" = "subscription" ] || [ "$_file_mode" = "template" ]; then
            printf '%s\n' "$_file_mode"
            return 0
        fi
    fi
    printf '%s\n' "subscription"
}

# 顶层块提取：从 ^<key>[ \t]*: 开始，到下一个顶层键 ^[A-Za-z_][A-Za-z0-9_-]*[ \t]*: 之前
mihomo_lib_extract_top_block() {
    _top_raw_yaml="${1:-}"
    _top_key="${2:-}"
    _top_out_file="${3:-}"

    [ -f "$_top_raw_yaml" ] || return 1
    [ -n "$_top_key" ] || return 1
    [ -n "$_top_out_file" ] || return 1

    : > "$_top_out_file" || return 1

    awk -v key="$_top_key" '
      BEGIN {
          found = 0
          key_regex = "^" key "[ \t]*:"
          top_regex = "^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:"
      }
      $0 ~ key_regex {
          found = 1
          print
          next
      }
      found {
          if ($0 ~ top_regex) exit 0
          print
      }
      END {
          if (!found) exit 1
      }
    ' "$_top_raw_yaml" > "$_top_out_file" || {
        _top_rc=$?
        : > "$_top_out_file"
        return "$_top_rc"
    }
    return 0
}

# 策略片段提取：按顺序提取 5 个块，首行加注释，必须同时含 proxy-groups 与 rules
mihomo_lib_extract_strategy() {
    _strat_raw_yaml="${1:-}"
    _strat_out_file="${2:-}"

    [ -f "$_strat_raw_yaml" ] || return 1
    [ -n "$_strat_out_file" ] || return 1

    _strat_tmp_dir="$(dirname "$_strat_out_file")"
    mkdir -p "$_strat_tmp_dir" 2>/dev/null || true
    _tmp_part="$(mktemp "$_strat_tmp_dir/strat_part.XXXXXX" 2>/dev/null || mktemp /tmp/strat_part.XXXXXX)" || return 1

    printf '%s\n' "# subscription strategy (auto-extracted; do not edit)" > "$_strat_out_file"

    _has_groups=0
    _has_rules=0

    for _blk in proxy-providers proxy-groups rule-providers sub-rules rules; do
        if mihomo_lib_extract_top_block "$_strat_raw_yaml" "$_blk" "$_tmp_part"; then
            cat "$_tmp_part" >> "$_strat_out_file"
            [ "$_blk" = "proxy-groups" ] && _has_groups=1
            [ "$_blk" = "rules" ] && _has_rules=1
        fi
    done
    rm -f "$_tmp_part"

    if [ "$_has_groups" -eq 1 ] && [ "$_has_rules" -eq 1 ]; then
        return 0
    fi

    : > "$_strat_out_file"
    return 1
}

# 策略片段校验：文件非空且同时含 ^proxy-groups[ \t]*: 与 ^rules[ \t]*:
mihomo_lib_strategy_valid() {
    _file="${1:-}"
    [ -f "$_file" ] && [ -s "$_file" ] || return 1
    grep -Eq '^proxy-groups[ \t]*:' "$_file" && grep -Eq '^rules[ \t]*:' "$_file"
}

# 条目计数：统计顶层块内 ^[ \t]*-[ \t] 行数
mihomo_lib_count_block_items() {
    _file="${1:-}"
    _key="${2:-}"
    if [ ! -f "$_file" ] || [ -z "$_key" ]; then
        echo "0"
        return 0
    fi
    awk -v key="$_key" '
      BEGIN {
          in_block = 0
          count = 0
          key_regex = "^" key "[ \t]*:"
          top_regex = "^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:"
      }
      $0 ~ key_regex {
          in_block = 1
          next
      }
      in_block && $0 ~ top_regex {
          in_block = 0
      }
      in_block && (/^- / || /^  - /) {
          count++
      }
      END {
          print count + 0
      }
    ' "$_file" | tr -d ' '
}

# 策略缓存写入：原子写入 MIHOMO_STRATEGY_FILE
mihomo_lib_strategy_store() {
    _bundle="${1:-}"
    [ -f "$_bundle" ] || return 1
    _strat_dir="$(dirname "$MIHOMO_STRATEGY_FILE")"
    mkdir -p "$_strat_dir" 2>/dev/null || return 1
    chmod 0750 "$_strat_dir" 2>/dev/null || true

    _tmp_store="$(mktemp "$_strat_dir/strat.XXXXXX" 2>/dev/null || mktemp /tmp/strat.XXXXXX)" || return 1
    chmod 0600 "$_tmp_store" 2>/dev/null || true
    cat "$_bundle" > "$_tmp_store" || {
        rm -f "$_tmp_store"
        return 1
    }
    chmod 0600 "$_tmp_store" 2>/dev/null || true
    mv -f "$_tmp_store" "$MIHOMO_STRATEGY_FILE" || {
        rm -f "$_tmp_store"
        return 1
    }
    chmod 0600 "$MIHOMO_STRATEGY_FILE" 2>/dev/null || true
    return 0
}

# 策略缓存移除
mihomo_lib_strategy_remove() {
    rm -f "$MIHOMO_STRATEGY_FILE" 2>/dev/null || true
}

# 订阅操作加锁（含陈旧锁自动清理机制）
# 只按 pid 存活判定会永久锁死：mkdir 成功与写入 pid 之间进程被杀时 pid 文件
# 不存在，任何持有者都无从判断锁主已死。故 pid 缺失时用锁目录 mtime 超龄兜底。
MIHOMO_LOCK_STALE_SECS=900

mihomo_lib_lock_acquire() {
    if mkdir "$MIHOMO_LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=1
        printf '%s\n' "$$" > "$MIHOMO_LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi

    _lock_pid="$(cat "$MIHOMO_LOCK_DIR/pid" 2>/dev/null || true)"
    _lock_stale=0

    if [ -n "$_lock_pid" ]; then
        if ! kill -0 "$_lock_pid" 2>/dev/null; then
            _lock_stale=1
        fi
    else
        # BSD stat 用 -f %m，GNU stat 用 -c %Y；输出非数字时视为不可判定
        _lock_mtime="$(stat -f %m "$MIHOMO_LOCK_DIR" 2>/dev/null || true)"
        case "$_lock_mtime" in
            ''|*[!0-9]*) _lock_mtime="$(stat -c %Y "$MIHOMO_LOCK_DIR" 2>/dev/null || true)" ;;
        esac
        case "$_lock_mtime" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$(( $(date +%s) - _lock_mtime ))" -gt "$MIHOMO_LOCK_STALE_SECS" ]; then
                    _lock_stale=1
                fi
                ;;
        esac
    fi

    if [ "$_lock_stale" = "1" ]; then
        if [ -n "$_lock_pid" ]; then
            echo "警告：发现陈旧锁（持有者 PID $_lock_pid 已不存在），自动清理后重试。" >&2
        else
            echo "警告：发现陈旧锁（无 pid 文件且锁已超过 ${MIHOMO_LOCK_STALE_SECS} 秒），自动清理后重试。" >&2
        fi
        rm -rf "$MIHOMO_LOCK_DIR"
        # 回收与重建之间存在 TOCTOU：以本次 mkdir 成功为唯一凭据
        if mkdir "$MIHOMO_LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$MIHOMO_LOCK_DIR/pid" 2>/dev/null || true
            # 重建后立即重验：pid 落盘且等于本进程才算持锁成功
            if [ "$(cat "$MIHOMO_LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
                LOCK_HELD=1
                return 0
            fi
            rmdir "$MIHOMO_LOCK_DIR" 2>/dev/null || true
        fi
    fi
    return 1
}

# 释放锁
mihomo_lib_lock_release() {
    if [ "${LOCK_HELD:-0}" = "1" ]; then
        rm -f "$MIHOMO_LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$MIHOMO_LOCK_DIR" 2>/dev/null || true
        LOCK_HELD=0
    fi
}

# URL 脱敏：保留 scheme://host，path/query 脱敏为 ***
mihomo_lib_mask_url() {
    _raw_url="${1:-}"
    _scheme="$(printf "%s" "$_raw_url" | sed -n 's/^\([a-zA-Z][a-zA-Z0-9+.-]*:\/\/\).*/\1/p')"
    _host="$(printf "%s" "$_raw_url" | sed 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' | cut -d'/' -f1 | cut -d'?' -f1)"
    printf '%s%s/***\n' "$_scheme" "$_host"
}

# 提取 proxies 顶层段（含 www.speedtet.net 修正）
# 起点与终点都必须是列 0 的顶层键：策略组的成员表里也有缩进的 proxies:，
# 零缩进的序列项（"- name: x"）也不是顶层键，两者都不能当作段边界
mihomo_lib_extract_proxies() {
    _raw_yaml="${1:-}"
    _out_file="${2:-}"
    [ -f "$_raw_yaml" ] || return 1
    [ -n "$_out_file" ] || return 1
    awk '
      in_proxies && /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/ {
          exit
      }
      /^proxies[ \t]*:/ {
          in_proxies = 1
          print
          next
      }
      in_proxies {
          print
      }
    ' "$_raw_yaml" | sed 's/www\.speedtet\.net/www.speedtest.net/g' > "$_out_file"
}

# 提取节点名称列表（去重、去引号、转义并格式化为 YAML 项）
# 名称里可能含逗号（策略组按名字引用，取错即整组失联），所以流式 map 的
# name 值必须感知引号：取到下一个未加引号的逗号或块尾 } 为止，且不假设字段顺序
mihomo_lib_extract_names() {
    _names_proxies_file="${1:-}"
    _names_out_file="${2:-}"
    [ -f "$_names_proxies_file" ] || return 1
    [ -n "$_names_out_file" ] || return 1
    awk '
      function trim(s) {
          sub(/^[[:space:]]+/, "", s)
          sub(/[[:space:]]+$/, "", s)
          return s
      }
      function unquote(s) {
          s = trim(s)
          if ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") ||
              (substr(s, 1, 1) == "\047" && substr(s, length(s), 1) == "\047")) {
              s = substr(s, 2, length(s) - 2)
          }
          return s
      }
      function emit(s) {
          s = unquote(s)
          if (s != "" && !seen[s]++) {
              gsub(/\\/, "\\\\", s)
              gsub(/"/, "\\\"", s)
              print "      - \"" s "\""
          }
      }
      function flow_name(line,   n, i, ch, out, q) {
          if (!match(line, /[{,][ \t]*name[ \t]*:[ \t]*/)) return ""
          line = substr(line, RSTART + RLENGTH)
          n = length(line)
          out = ""
          q = ""
          for (i = 1; i <= n; i++) {
              ch = substr(line, i, 1)
              if (q != "") {
                  # 引号内：反斜杠转义连同下一字符一起吞掉
                  if (ch == "\\") {
                      out = out ch
                      if (i < n) {
                          i++
                          out = out substr(line, i, 1)
                      }
                      continue
                  }
                  out = out ch
                  if (ch == q) q = ""
                  continue
              }
              if (ch == "\"" || ch == "\047") {
                  q = ch
                  out = out ch
                  continue
              }
              if (ch == "," || ch == "}") break
              out = out ch
          }
          return out
      }
      /^[[:space:]]*-[[:space:]]*\{/ {
          line = flow_name($0)
          if (line != "") emit(line)
          next
      }
      /^[[:space:]]*-[[:space:]]*name[[:space:]]*:/ {
          line = $0
          sub(/^[[:space:]]*-[[:space:]]*name[[:space:]]*:[[:space:]]*/, "", line)
          sub(/[[:space:]]+#.*$/, "", line)
          emit(line)
          next
      }
      /^[[:space:]]*name[[:space:]]*:/ {
          line = $0
          sub(/^[[:space:]]*name[[:space:]]*:[[:space:]]*/, "", line)
          sub(/[[:space:]]+#.*$/, "", line)
          emit(line)
          next
      }
    ' "$_names_proxies_file" > "$_names_out_file"
}

# 统计 proxies 中的节点数量
# 段边界判据必须与 extract_proxies 一致：零缩进序列项（"- name: x"）属于段内
mihomo_lib_count_nodes() {
    _proxies_file="${1:-}"
    if [ ! -f "$_proxies_file" ]; then
        echo "0"
        return 0
    fi
    awk '
      BEGIN { count = 0 }
      in_proxies == 1 && /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/ { in_proxies = 0 }
      /^proxies[ \t]*:/ { in_proxies = 1; next }
      in_proxies == 1 && /^[[:space:]]*-[[:space:]]/ { count++ }
      END { print count }
    ' "$_proxies_file" | tr -d ' '
}

# 配置合成函数：
# 1. 占位符替换（proxies, names, custom_rules）
# 2. LAN 暴露处理（allow-lan, bind-address, authentication, lan-allowed-ips）
# 3. secret 注入
# 4. 权限设置 0600
mihomo_lib_compose() {
    _proxies_file="${1:-}"
    _out_file="${2:-}"

    [ -f "$_proxies_file" ] || {
        echo "错误：代理文件不存在：$_proxies_file" >&2
        return 1
    }
    [ -n "$_out_file" ] || {
        echo "错误：未指定输出文件路径" >&2
        return 1
    }

    # a) 检查模板及必要占位符
    if [ ! -f "$MIHOMO_TEMPLATE_FILE" ]; then
        echo "错误：缺少模板文件：$MIHOMO_TEMPLATE_FILE" >&2
        return 1
    fi
    if ! grep -q '__MIHOMO_PROXIES__' "$MIHOMO_TEMPLATE_FILE" || \
       ! grep -q '__MIHOMO_NODE_NAMES__' "$MIHOMO_TEMPLATE_FILE"; then
        echo "错误：模板文件缺少占位符：__MIHOMO_PROXIES__ 或 __MIHOMO_NODE_NAMES__" >&2
        return 1
    fi
    # 自定义规则占位符向后兼容：旧模板（1.0.4 及用户自定）可能没有
    # __MIHOMO_CUSTOM_RULES__（F4 快照恢复会保留旧模板）——此时降级为
    # 注入到 rules: 顶层键之后，而不是拒绝服务
    _rules_mode="placeholder"
    if ! grep -q '__MIHOMO_CUSTOM_RULES__' "$MIHOMO_TEMPLATE_FILE"; then
        if ! grep -q '^rules:[[:space:]]*$' "$MIHOMO_TEMPLATE_FILE"; then
            echo "错误：模板既无 __MIHOMO_CUSTOM_RULES__ 占位符也无 rules: 顶层键，无法注入自定义规则" >&2
            return 1
        fi
        _rules_mode="fallback"
        echo "提示：模板缺少 __MIHOMO_CUSTOM_RULES__ 占位符，自定义规则将注入到 rules: 之后" >&2
    fi

    # b) 提取节点名称并进行占位符替换
    _compose_tmp_dir="$(dirname "$_out_file")"
    mkdir -p "$_compose_tmp_dir" 2>/dev/null || true

    _tmp_names="$(mktemp "$_compose_tmp_dir/names.XXXXXX" 2>/dev/null || mktemp /tmp/names.XXXXXX)"
    if ! mihomo_lib_extract_names "$_proxies_file" "$_tmp_names"; then
        rm -f "$_tmp_names"
        echo "错误：提取节点名称失败" >&2
        return 1
    fi

    _rules_src="/dev/null"
    if [ -n "$MIHOMO_RULES_FILE" ] && [ -f "$MIHOMO_RULES_FILE" ]; then
        _rules_src="$MIHOMO_RULES_FILE"
    fi

    _tmp_step1="$(mktemp "$_compose_tmp_dir/comp1.XXXXXX" 2>/dev/null || mktemp /tmp/comp1.XXXXXX)"

    awk -v proxies_file="$_proxies_file" -v names_file="$_tmp_names" -v rules_file="$_rules_src" -v rules_mode="$_rules_mode" '
      /^[[:space:]]*#[[:space:]]*__MIHOMO_PROXIES__[[:space:]]*$/ {
          while ((getline line < proxies_file) > 0) print line
          close(proxies_file)
          next
      }
      /^[[:space:]]*#[[:space:]]*__MIHOMO_NODE_NAMES__[[:space:]]*$/ {
          while ((getline line < names_file) > 0) print line
          close(names_file)
          next
      }
      /^[[:space:]]*#[[:space:]]*__MIHOMO_CUSTOM_RULES__[[:space:]]*$/ {
          while ((getline line < rules_file) > 0) {
              # 空行跳过；注释行原样缩进保留；规则行补 YAML 列表前缀（校验器存的是裸规则）
              if (line ~ /^[[:space:]]*$/) continue
              if (line ~ /^[[:space:]]*#/) { print "  " line } else { print "  - " line }
          }
          close(rules_file)
          next
      }
      # fallback 模式：模板没有占位符时，把自定义规则插到 rules: 顶层键之后
      rules_mode == "fallback" && /^rules:[[:space:]]*$/ {
          print
          while ((getline line < rules_file) > 0) {
              if (line ~ /^[[:space:]]*$/) continue
              if (line ~ /^[[:space:]]*#/) { print "  " line } else { print "  - " line }
          }
          close(rules_file)
          next
      }
      { print }
    ' "$MIHOMO_TEMPLATE_FILE" > "$_tmp_step1"

    rm -f "$_tmp_names"

    if [ ! -s "$_tmp_step1" ]; then
        rm -f "$_tmp_step1"
        echo "错误：基础配置合成结果为空" >&2
        return 1
    fi

    # 策略来源处理（subscription 模式下替换策略组与分流规则，否则沿用模板）
    _strategy_mode="$(mihomo_lib_strategy_mode)"
    _strategy_src="${MIHOMO_STRATEGY_INPUT_FILE:-$MIHOMO_STRATEGY_FILE}"
    if [ "$_strategy_mode" = "subscription" ]; then
        if [ -n "${_strategy_src:-}" ] && [ -f "$_strategy_src" ] && mihomo_lib_strategy_valid "$_strategy_src"; then
            _tmp_cut="$(mktemp "$_compose_tmp_dir/comp_cut.XXXXXX" 2>/dev/null || mktemp /tmp/comp_cut.XXXXXX)"
            awk '
              BEGIN {
                  target_regex = "^(proxy-providers|proxy-groups|rule-providers|sub-rules|rules)[ \t]*:"
                  top_regex = "^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:"
                  skip = 0
              }
              $0 ~ target_regex {
                  skip = 1
                  next
              }
              skip {
                  if ($0 ~ top_regex) {
                      if ($0 ~ target_regex) {
                          skip = 1
                          next
                      } else {
                          skip = 0
                          print
                          next
                      }
                  }
                  next
              }
              { print }
            ' "$_tmp_step1" > "$_tmp_cut"

            _tmp_inj="$(mktemp "$_compose_tmp_dir/comp_inj.XXXXXX" 2>/dev/null || mktemp /tmp/comp_inj.XXXXXX)"
            awk -v rules_file="$_rules_src" '
              /^rules:[ \t]*/ {
                  print
                  while ((getline rline < rules_file) > 0) {
                      if (rline ~ /^[ \t]*$/) continue
                      if (rline ~ /^[ \t]*#/) { print "  " rline } else { print "  - " rline }
                  }
                  close(rules_file)
                  print "  - GEOSITE,private,DIRECT"
                  next
              }
              { print }
            ' "$_strategy_src" > "$_tmp_inj"

            cat "$_tmp_cut" "$_tmp_inj" > "$_tmp_step1"
            rm -f "$_tmp_cut" "$_tmp_inj"

            MIHOMO_COMPOSE_STRATEGY_USED="subscription"
            MIHOMO_COMPOSE_STRATEGY_GROUPS="$(mihomo_lib_count_block_items "$_strategy_src" proxy-groups)"
            MIHOMO_COMPOSE_STRATEGY_RULES="$(mihomo_lib_count_block_items "$_strategy_src" rules)"
        else
            echo "提示：未找到可用的订阅策略组缓存，本次使用插件模板" >&2
            MIHOMO_COMPOSE_STRATEGY_USED="template"
            MIHOMO_COMPOSE_STRATEGY_GROUPS="$(mihomo_lib_count_block_items "$MIHOMO_TEMPLATE_FILE" proxy-groups)"
            MIHOMO_COMPOSE_STRATEGY_RULES="$(mihomo_lib_count_block_items "$MIHOMO_TEMPLATE_FILE" rules)"
        fi
    else
        MIHOMO_COMPOSE_STRATEGY_USED="template"
        MIHOMO_COMPOSE_STRATEGY_GROUPS="$(mihomo_lib_count_block_items "$MIHOMO_TEMPLATE_FILE" proxy-groups)"
        MIHOMO_COMPOSE_STRATEGY_RULES="$(mihomo_lib_count_block_items "$MIHOMO_TEMPLATE_FILE" rules)"
    fi

    # 解析 Secret
    _secret=""
    if [ -n "${mihomo_secret:-}" ]; then
        _secret="$mihomo_secret"
    elif [ -x "$MIHOMO_SECRET_MANAGER" ]; then
        _secret="$("$MIHOMO_SECRET_MANAGER" get 2>/dev/null || true)"
    fi
    if [ -z "$_secret" ]; then
        if command -v openssl >/dev/null 2>&1; then
            _secret="$(openssl rand -hex 32)"
        elif [ -r /dev/urandom ]; then
            _secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        else
            echo "错误：缺少安全随机数生成器" >&2
            rm -f "$_tmp_step1"
            return 1
        fi
    fi

    # c) LAN 暴露处理
    _lan_expose=0
    _lan_user="mihomo"
    if [ -f "$MIHOMO_PANEL_STATE_FILE" ]; then
        MIHOMO_LAN_EXPOSE=0
        MIHOMO_LAN_USER="mihomo"
        . "$MIHOMO_PANEL_STATE_FILE" 2>/dev/null || true
        _lan_expose="${MIHOMO_LAN_EXPOSE:-0}"
        _lan_user="${MIHOMO_LAN_USER:-mihomo}"
    fi

    _tmp_step2="$(mktemp "$_compose_tmp_dir/comp2.XXXXXX" 2>/dev/null || mktemp /tmp/comp2.XXXXXX)"

    if [ "$_lan_expose" = "1" ]; then
        _lan_net=""
        _php_bin="${PHP_BIN:-/usr/local/bin/php}"
        _render_script="${MIHOMO_TRANSPORT_RENDER:-/usr/local/opnsense/scripts/OPNsense/Mihomo/transport_render.php}"
        if [ -x "$_php_bin" ] && [ -f "$_render_script" ]; then
            _lan_net="$("$_php_bin" "$_render_script" lan-net 2>/dev/null || true)"
        fi
        if [ -z "$_lan_net" ]; then
            echo "# 提示：未获取到 LAN 网段（php 不存在或执行失败），lan-allowed-ips 保持原样"
        fi

        export MIHOMO_LAN_USER_VAL="$_lan_user"
        export MIHOMO_LAN_SECRET_VAL="$_secret"
        export MIHOMO_LAN_NET_VAL="$_lan_net"

        awk '
          BEGIN {
              lan_user = ENVIRON["MIHOMO_LAN_USER_VAL"]
              lan_secret = ENVIRON["MIHOMO_LAN_SECRET_VAL"]
              lan_net = ENVIRON["MIHOMO_LAN_NET_VAL"]
              in_lan_ips = 0
          }
          /^[[:space:]]*allow-lan:[[:space:]]*false/ {
              sub(/allow-lan:[[:space:]]*false/, "allow-lan: true")
              print
              next
          }
          /^[[:space:]]*bind-address:[[:space:]]*127\.0\.0\.1/ {
              # \047 是 POSIX awk 的单引号八进制转义（BSD awk 不支持 \x 转义）
              sub(/bind-address:[[:space:]]*127\.0\.0\.1/, "bind-address: \047*\047")
              print
              print "authentication:"
              print "  - \"" lan_user ":" lan_secret "\""
              next
          }
          /^[[:space:]]*lan-allowed-ips:[[:space:]]*/ {
              print
              in_lan_ips = 1
              if (lan_net != "") {
                  # fixB: 透明传输层 hev 固定从 127.0.0.1 拨入 mihomo，
                  # 收窄白名单时回环必须始终保留，否则透明代理被 ACL 静默掐断
                  print "  - 127.0.0.1/32"
                  print "  - ::1/128"
                  print "  - " lan_net
              }
              next
          }
          in_lan_ips && /^[[:space:]]*-[[:space:]]*(0\.0\.0\.0\/0|::\/0)[[:space:]]*$/ {
              if (lan_net != "") {
                  next
              }
          }
          in_lan_ips && /^[^[:space:]]/ {
              in_lan_ips = 0
          }
          { print }
        ' "$_tmp_step1" > "$_tmp_step2"
        rm -f "$_tmp_step1"
    else
        mv "$_tmp_step1" "$_tmp_step2"
    fi

    # d) secret 注入
    _tmp_step3="$(mktemp "$_compose_tmp_dir/comp3.XXXXXX" 2>/dev/null || mktemp /tmp/comp3.XXXXXX)"
    awk '!/^[[:space:]]*secret[[:space:]]*:/ { print }' "$_tmp_step2" > "$_tmp_step3"
    rm -f "$_tmp_step2"

    _tmp_step4="$(mktemp "$_compose_tmp_dir/comp4.XXXXXX" 2>/dev/null || mktemp /tmp/comp4.XXXXXX)"
    if grep -q '^external-ui:' "$_tmp_step3"; then
        MIHOMO_SUB_SECRET="$_secret" awk '
          /^external-ui:/ {
              print
              print "secret: \"" ENVIRON["MIHOMO_SUB_SECRET"] "\""
              next
          }
          { print }
        ' "$_tmp_step3" > "$_tmp_step4"
    else
        cat "$_tmp_step3" > "$_tmp_step4"
        printf 'secret: "%s"\n' "$_secret" >> "$_tmp_step4"
    fi
    rm -f "$_tmp_step3"

    # e) 输出文件权限为 0600
    chmod 0600 "$_tmp_step4" 2>/dev/null || true
    mv -f "$_tmp_step4" "$_out_file"
    chmod 0600 "$_out_file" 2>/dev/null || true
    return 0
}

# 缓存 proxies 文件并返回 sha256
mihomo_lib_cache_store() {
    _proxies_file="${1:-}"
    [ -f "$_proxies_file" ] || return 1
    _cache_dir="$(dirname "$MIHOMO_CACHE_FILE")"
    mkdir -p "$_cache_dir" 2>/dev/null || true
    _tmp_cache="$(mktemp "$_cache_dir/cache.XXXXXX" 2>/dev/null || mktemp /tmp/cache.XXXXXX)" || return 1
    chmod 0600 "$_tmp_cache" 2>/dev/null || true
    cat "$_proxies_file" > "$_tmp_cache"
    chmod 0600 "$_tmp_cache" 2>/dev/null || true
    mv -f "$_tmp_cache" "$MIHOMO_CACHE_FILE"
    chmod 0600 "$MIHOMO_CACHE_FILE" 2>/dev/null || true

    _hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        _hash="$(sha256sum "$MIHOMO_CACHE_FILE" | awk '{print $1}')"
    elif command -v sha256 >/dev/null 2>&1; then
        _hash="$(sha256 -q "$MIHOMO_CACHE_FILE" 2>/dev/null || sha256 "$MIHOMO_CACHE_FILE" | awk '{print $NF}')"
    elif command -v shasum >/dev/null 2>&1; then
        _hash="$(shasum -a 256 "$MIHOMO_CACHE_FILE" | awk '{print $1}')"
    fi
    printf '%s\n' "$_hash"
}

# 状态写入：单行 JSON 写 MIHOMO_STATUS_FILE
mihomo_lib_status_write() {
    _res="${1:-failed}"
    _nodes="${2:-0}"
    _hash="${3:-}"
    _msg="${4:-}"
    _strat="${5:-template}"
    _groups="${6:-0}"
    _rules="${7:-0}"

    case "$_nodes" in
        ''|*[!0-9]*) _nodes=0 ;;
    esac

    case "$_strat" in
        subscription|template) ;;
        *) _strat="template" ;;
    esac

    case "$_groups" in
        ''|*[!0-9]*) _groups=0 ;;
    esac

    case "$_rules" in
        ''|*[!0-9]*) _rules=0 ;;
    esac

    _clean_res="$(printf '%s' "$_res" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')"
    _clean_hash="$(printf '%s' "$_hash" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')"
    _clean_msg="$(printf '%s' "$_msg" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')"

    _status_dir="$(dirname "$MIHOMO_STATUS_FILE")"
    mkdir -p "$_status_dir" 2>/dev/null || true
    _tmp_status="$(mktemp "$_status_dir/status.XXXXXX" 2>/dev/null || mktemp /tmp/status.XXXXXX)" || return 1
    _now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    printf '{"time":"%s","result":"%s","nodes":%d,"cache_sha256":"%s","message":"%s","strategy":"%s","groups":%d,"rules":%d}\n' \
        "$_now" "$_clean_res" "$_nodes" "$_clean_hash" "$_clean_msg" "$_strat" "$_groups" "$_rules" > "$_tmp_status"
    chmod 0644 "$_tmp_status" 2>/dev/null || true
    mv -f "$_tmp_status" "$MIHOMO_STATUS_FILE"
}

# 解析 config.yaml 的 external-controller 为 "host port"（协议见 docs/DESIGN-lan-api.md v3.2）
# 只接受 IPv4:port 形态；0.0.0.0 归一化为 127.0.0.1（探测走本机回环），
# 解析失败回退 127.0.0.1 9090 并向 stderr 告警。输出用空格分隔两段。
mihomo_lib_api_addr() {
    _api_conf="${1:-/usr/local/etc/mihomo/config.yaml}"
    _api_raw=""
    if [ -r "$_api_conf" ]; then
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
        ' "$_api_conf" 2>/dev/null || true)"
    fi
    if [ -z "$_api_raw" ]; then
        echo "警告：无法从 $_api_conf 解析 external-controller，回退 127.0.0.1 端口 9090" >&2
        printf '%s %s\n' "127.0.0.1" "9090"
        return 0
    fi
    _api_host="${_api_raw% *}"
    _api_port="${_api_raw#* }"
    if [ "$_api_host" = "0.0.0.0" ]; then
        _api_host="127.0.0.1"
    fi
    printf '%s %s\n' "$_api_host" "$_api_port"
}
