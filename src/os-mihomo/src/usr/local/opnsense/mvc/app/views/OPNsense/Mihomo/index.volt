{#
 # Copyright (C) 2024-2026 Deciso B.V.
 # All rights reserved.
 #}

{{ partial('OPNsense/Mihomo/styles') }}

<div class="mihomo-page">
    <div id="save_toast" class="mihomo-save-toast" style="display: none;"></div>

    <div class="mihomo-tabs-bar">
        <ul class="nav nav-tabs" role="tablist">
            <li class="active" role="presentation"><a href="#tab_overview" data-toggle="tab" role="tab"><i class="fa fa-dashboard"></i> {{ lang._('概览') }}</a></li>
            <li role="presentation"><a href="#tab_general" data-toggle="tab" role="tab"><i class="fa fa-sliders"></i> {{ lang._('基本设置') }}</a></li>
            <li role="presentation"><a href="#tab_subscription" data-toggle="tab" role="tab"><i class="fa fa-rss"></i> {{ lang._('订阅与策略') }}</a></li>
        </ul>
    </div>

    <div class="tab-content">
        <!-- Tab 1：概览（吸收运行状态页全部信息） -->
        <div class="tab-pane active" id="tab_overview">
            <div class="row mihomo-row-cards">
            <div class="col-md-4">
            <div class="mihomo-card">
                <div class="mihomo-card-head">
                    <h2 class="mihomo-card-title">
                        <span><i class="fa fa-cogs"></i> {{ lang._('服务状态') }}</span>
                        <button class="btn btn-default btn-xs" id="btn_ov_refresh" type="button" title="{{ lang._('刷新状态与指标') }}">
                            <i class="fa fa-refresh"></i> {{ lang._('刷新') }}
                        </button>
                    </h2>
                </div>
                <div class="mihomo-card-body">
                    <div class="mihomo-stat-card">
                        <div style="display: flex; align-items: center; flex-wrap: wrap; gap: 8px;">
                            <span id="ov_state_dot" class="mihomo-status-dot"></span>
                            <span id="ov_state_text" style="font-weight: 600;">{{ lang._('检查中...') }}</span>
                            <span id="service_status_badge" class="label label-default" style="font-size: 11px; padding: 2px 6px;">-</span>
                        </div>
                        <div style="font-size: 12px; color: var(--mh-muted); margin-top: 8px;">
                            {{ lang._('开机自启') }}：<span id="ov_autostart">-</span>
                        </div>
                        <div style="margin-top: 12px;">
                            <div class="mihomo-inline-ctl">
                                <span class="mihomo-inline-note">{{ lang._('内核模式') }}</span>                                <select id="ov_core_mode_select" class="form-control input-sm">
                                    <option value="rule">{{ lang._('规则分流 (rule)') }}</option>
                                    <option value="global">{{ lang._('全局代理 (global)') }}</option>
                                    <option value="direct">{{ lang._('直连 (direct)') }}</option>
                                </select>
                                <button class="btn btn-primary btn-xs" id="btn_core_mode_apply" type="button">
                                    <i class="fa fa-check"></i> {{ lang._('应用') }}
                                </button>
                            </div>
                            <div style="margin-top: 4px; font-size: 11px;">
                                <span id="core_mode_config" class="mihomo-inline-note">{{ lang._('配置默认：-') }}</span>
                                <span id="core_mode_msg" class="mihomo-inline-note"></span>
                            </div>
                        </div>
                        <div class="mihomo-toolbar" style="margin-bottom: 0; margin-top: 14px;">
                            <!-- 启动键独立于 btn-group：隐藏组内首个可见按钮时避免 BS3 圆角丢失 -->
                            <button class="btn btn-success" id="btn_start" type="button">
                                <i class="fa fa-play"></i> {{ lang._('启动') }}
                            </button>
                            <div class="btn-group">
                                <button class="btn btn-danger" id="btn_stop" type="button">
                                    <i class="fa fa-stop"></i> {{ lang._('停止') }}
                                </button>
                                <button class="btn btn-warning" id="btn_restart" type="button">
                                    <i class="fa fa-refresh"></i> {{ lang._('重启') }}
                                </button>
                                <button class="btn btn-info" id="btn_reload" type="button">
                                    <i class="fa fa-retweet"></i> {{ lang._('重载') }}
                                </button>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
            </div>
            <div class="col-md-4">
            <div class="mihomo-card">
                <div class="mihomo-card-head">
                    <h2 class="mihomo-card-title">
                        <span><i class="fa fa-line-chart"></i> {{ lang._('运行指标') }}</span>
                    </h2>
                </div>
                <div class="mihomo-card-body">
                    <div class="mihomo-stat-card">
                        <div class="mihomo-kv-rows" style="width: 100%;">
                            <div>
                                <span class="mh-kv-label">{{ lang._('运行时长') }}</span>
                                <span class="mh-kv-value mihomo-mono" id="ov_uptime">-</span>
                            </div>
                            <div>
                                <span class="mh-kv-label">{{ lang._('内存占用') }}</span>
                                <span class="mh-kv-value mihomo-mono" id="ov_memory">-</span>
                            </div>
                            <div>
                                <span class="mh-kv-label">{{ lang._('进程 ID') }}</span>
                                <span class="mh-kv-value mihomo-mono" id="ov_pid">-</span>
                            </div>
                            <div>
                                <span class="mh-kv-label">{{ lang._('TUN 隧道') }}</span>
                                <span class="mh-kv-value"><span id="ov_tun" class="label label-default" style="font-size: 11px; padding: 2px 6px;">-</span></span>
                            </div>
                            <div>
                                <span class="mh-kv-label">{{ lang._('控制 API') }}</span>
                                <span class="mh-kv-value"><span id="ov_api" class="label label-default" style="font-size: 11px; padding: 2px 6px;">-</span></span>
                            </div>
                            <div>
                                <span class="mh-kv-label">{{ lang._('插件 / 内核版本') }}</span>
                                <span class="mh-kv-value mihomo-mono" id="ov_versions" title="-">-</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
            </div>
            <div class="col-md-4">
            <div class="mihomo-card">
                <div class="mihomo-card-head">
                    <h2 class="mihomo-card-title">
                        <span><i class="fa fa-bar-chart"></i> {{ lang._('订阅资源') }}</span>
                    </h2>
                </div>
                <div class="mihomo-card-body">
                    <div class="mihomo-stat-card">
                        <div class="row" style="margin-bottom: 10px;">
                            <div class="col-xs-4" style="text-align: center;">
                                <div class="mihomo-stat-num" id="ov_nodes"><span class="mihomo-skeleton" style="display: inline-block; width: 56px; height: 24px;"></span></div>
                                <div class="mihomo-stat-label">{{ lang._('可用节点') }}</div>
                            </div>
                            <div class="col-xs-4" style="text-align: center;">
                                <div class="mihomo-stat-num" id="ov_groups"><span class="mihomo-skeleton" style="display: inline-block; width: 56px; height: 24px;"></span></div>
                                <div class="mihomo-stat-label">{{ lang._('策略组') }}</div>
                            </div>
                            <div class="col-xs-4" style="text-align: center;">
                                <div class="mihomo-stat-num" id="ov_rules"><span class="mihomo-skeleton" style="display: inline-block; width: 76px; height: 24px;"></span></div>
                                <div class="mihomo-stat-label">{{ lang._('分流规则') }}</div>
                            </div>
                        </div>
                        <div style="font-size: 13px; color: var(--mh-muted); margin-bottom: 10px;">
                            <span id="ov_sub_result" class="label label-default" style="margin-right: 6px;">-</span>
                            <span id="ov_sub_time">-</span>
                        </div>
                        <div class="mihomo-toolbar" style="margin-bottom: 0;">
                            <button class="btn btn-default btn-sm" id="ov_btn_sub_update" type="button">
                                <i class="fa fa-cloud-download"></i> {{ lang._('立即更新') }}
                            </button>
                        </div>
                    </div>
                </div>
            </div>
            </div>
            </div>
        </div>

        <!-- Tab 2：基本设置（运行参数 + 面板与 API 合并） -->
        <div class="tab-pane" id="tab_general">
            <div class="mihomo-card">
                <div class="mihomo-card-head">
                    <h2 class="mihomo-card-title">
                        <span><i class="fa fa-sliders"></i> {{ lang._('运行参数') }}</span>
                    </h2>
                </div>
                <div class="mihomo-card-body">
                    <div class="mihomo-form-wrap mihomo-modern-form">
                        {{ partial("layout_partials/base_form", ['fields': generalForm, 'id': 'frm_general_settings']) }}
                        <div class="mihomo-toolbar" style="margin-top: 15px; margin-bottom: 0;">
                            <button class="btn btn-primary" id="btn_save" type="button">
                                <b>{{ lang._('保存并应用') }}</b> <i id="btn_save_progress"></i>
                            </button>
                        </div>
                    </div>
                </div>
            </div>

            <div class="mihomo-card">
                <div class="mihomo-card-head">
                    <h2 class="mihomo-card-title">
                        <span><i class="fa fa-tachometer"></i> {{ lang._('面板与 API') }}</span>
                    </h2>
                </div>
                <div class="mihomo-card-body">
                    <div class="mh-fields is-2">
                        <div class="mh-field is-full">
                            <div class="mh-field-label">{{ lang._('控制 API 地址') }}</div>
                            <div class="mh-field-control">
                                <span class="mh-code" id="api_endpoint_display">-</span>
                                <button type="button" class="btn btn-xs btn-default" id="btn_copy_endpoint">
                                    <i class="fa fa-clipboard"></i> {{ lang._('复制') }}
                                </button>
                            </div>
                            <div class="mh-field-hint">
                                {{ lang._('外部面板（metacubexd / Zashboard）与自建流量工具填此地址，配合下方密钥使用。') }}
                            </div>
                        </div>

                        <div class="mh-field">
                            <div class="mh-field-label">{{ lang._('API 绑定地址') }}</div>
                            <div class="mh-field-control">
                                <input type="text" class="form-control" id="api_bind" placeholder="{{ lang._('如 192.168.1.1 / 127.0.0.1') }}" autocomplete="off" spellcheck="false"/>
                            </div>
                        </div>

                        <div class="mh-field">
                            <div class="mh-field-label">{{ lang._('API 端口') }}</div>
                            <div class="mh-field-control">
                                <input type="text" class="form-control" id="api_port" placeholder="1024-65535" autocomplete="off" spellcheck="false"/>
                            </div>
                        </div>

                        <div class="mh-field is-full">
                            <div class="mh-field-label">{{ lang._('认证密钥') }}</div>
                            <div class="mh-field-control">
                                <span class="mh-code mh-secret" id="api_secret_masked">{{ lang._('加载中...') }}</span>
                                <button type="button" class="btn btn-xs btn-default" id="btn_secret_reveal">
                                    <i class="fa fa-eye"></i> {{ lang._('查看密钥') }}
                                </button>
                                <button type="button" class="btn btn-xs btn-warning" id="btn_secret_generate">
                                    <i class="fa fa-refresh"></i> {{ lang._('生成新密钥') }}
                                </button>
                            </div>
                        </div>

                        <div class="mh-field is-full is-last">
                            <div class="mh-field-label">{{ lang._('自定义密钥') }} <span class="tag">{{ lang._('可选') }}</span></div>
                            <div class="mh-inline-form">
                                <input type="text" class="form-control mh-input-wide" id="api_secret_custom" placeholder="{{ lang._('4-128 个字符') }}" autocomplete="off" spellcheck="false"/>
                                <button type="button" class="btn btn-default" id="btn_secret_apply">
                                    {{ lang._('填入') }}
                                </button>
                            </div>
                            <div class="mh-field-hint">{{ lang._('仅允许字母、数字以及 . _ ~ @ # % ^ + = : ; , ! ? * -') }}</div>
                        </div>
                    </div>

                    <div id="api_wan_warn" class="mihomo-callout-warning" style="display: none; margin-top: 14px; margin-bottom: 0;">
                        <i class="fa fa-exclamation-triangle"></i> {{ lang._('已监听全部网络接口（0.0.0.0）。建议仅在 LAN 接口监听并确保 WAN 防火墙阻断未授权流量。') }}
                    </div>

                    <div class="mihomo-toolbar" style="margin: 16px 0 0; padding-top: 14px; border-top: 1px dashed var(--mh-card-border); margin-bottom: 0;">
                        <button type="button" class="btn btn-primary" id="btn_api_save">
                            <b>{{ lang._('保存并应用') }}</b> <i id="btn_api_save_progress"></i>
                        </button>
                        <span class="text-muted" style="font-size: 12px; margin-left: 8px;">{{ lang._('卡内改动（绑定地址、端口、密钥）点此按钮才写入配置并热重载') }}</span>
                    </div>
                </div>
            </div>
        </div>

        <!-- Tab 3：订阅与策略（策略来源固定沿用订阅自带，选择器已移除） -->
        <div class="tab-pane" id="tab_subscription">
            <div class="mihomo-card">
                <div class="mihomo-card-head">
                    <h2 class="mihomo-card-title">
                        <span><i class="fa fa-rss"></i> {{ lang._('订阅') }}</span>
                    </h2>
                </div>
                <div class="mihomo-card-body">
                    <div class="mh-fields is-2">
                        <div class="mh-field is-full">
                            <div class="mh-field-label">{{ lang._('订阅地址') }}</div>
                            <div class="mh-field-control">
                                <input type="text" class="form-control mh-input-wide" id="sub_url" placeholder="https://..." autocomplete="off" spellcheck="false"/>
                            </div>
                            <div class="mh-field-hint" id="sub_url_hint">{{ lang._('请输入 https 订阅地址。') }}</div>
                        </div>

                        <div class="mh-field is-switch">
                            <div class="mh-field-control">
                                <input type="checkbox" id="sub_auto_update" style="width: 18px; height: 18px; cursor: pointer;"/>
                            </div>
                            <label class="mh-field-label" for="sub_auto_update" style="margin-bottom: 0;">{{ lang._('启用自动更新') }}</label>
                        </div>

                        <div class="mh-field">
                            <div class="mh-field-label">
                                <label for="sub_interval" style="font-size: 13px; font-weight: 600; margin-bottom: 0;">{{ lang._('自动更新周期') }}</label>
                            </div>
                            <div class="mh-field-control">
                                <select id="sub_interval" class="form-control">
                                    <option value="o6h">{{ lang._('每 6 小时') }}</option>
                                    <option value="o12h">{{ lang._('每 12 小时') }}</option>
                                    <option value="o24h">{{ lang._('每 24 小时') }}</option>
                                </select>
                            </div>
                        </div>
                    </div>

                    <div class="mihomo-toolbar" style="margin: 14px 0 0; padding-top: 14px; border-top: 1px dashed var(--mh-card-border); margin-bottom: 6px;">
                        <button class="btn btn-primary" id="btn_sub_save" type="button">
                            <b>{{ lang._('保存订阅') }}</b> <i id="btn_sub_save_progress"></i>
                        </button>
                        <button class="btn btn-info" id="btn_sub_update" type="button">
                            <i class="fa fa-cloud-download" id="btn_sub_update_icon"></i> {{ lang._('立即更新') }}
                        </button>
                        <span class="text-muted" style="font-size: 12px; margin-left: 8px;">{{ lang._('改地址不触发拉取') }}</span>
                    </div>
                    <div id="sub_state_message" class="text-muted" style="font-size: 12px; margin-bottom: 18px;"></div>

                    <div class="mihomo-card-title" style="font-size: 14px; font-weight: 600; margin: 20px 0 0;">
                        <span><i class="fa fa-history"></i> {{ lang._('最近更新状态') }}</span>
                    </div>
                    <div id="sub_state" class="mihomo-kv-strip" style="grid-template-columns: repeat(2, minmax(0, 1fr));">
                        <div>
                            <div class="mh-kv-label">{{ lang._('更新时间') }}</div>
                            <div class="mh-kv-value mihomo-mono" id="sub_state_time">-</div>
                        </div>
                        <div>
                            <div class="mh-kv-label">{{ lang._('更新结果') }}</div>
                            <div class="mh-kv-value"><span id="sub_state_result" class="label label-default">-</span></div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>

<script>
$(function () {
    var subPollTimer = null;
    var subPollStart = 0;
    var subLastUpdateTime = null;
    var subBaselineTime = null;
    var subHasUrl = false;
    var subUpdateInProgress = false;

    function textBlock(text) {
        return $('<div></div>').text(String(text));
    }

    /* OPNsense Mvc\Response 会对 API 输出做 htmlspecialchars，取回的可读文本需还原实体。
       用显式字符串替换还原，不走 DOM 解析，避免把服务端文本当 HTML 注入页面 */
    function mhFromEntities(text) {
        if (!text) {
            return '';
        }
        return String(text)
            .replace(/&lt;/g, '<')
            .replace(/&gt;/g, '>')
            .replace(/&quot;/g, '"')
            .replace(/&#0?39;/g, "'")
            .replace(/&amp;/g, '&');
    }

    function messageLines(lines) {
        var $box = $('<div></div>');
        if (Array.isArray(lines)) {
            $.each(lines, function (i, line) {
                $('<div></div>').text(String(line)).appendTo($box);
            });
        }
        return $box;
    }

    /* ---------- Tab 与 URL hash ---------- */

    function isOverviewActive() {
        return $('#tab_overview').hasClass('active');
    }

    $('a[data-toggle="tab"]').on('shown.bs.tab', function (e) {
        if (history.replaceState) {
            history.replaceState(null, null, $(e.target).attr('href'));
        }
        $('.selectpicker').selectpicker('refresh');
        if ($(e.target).attr('href') === '#tab_overview') {
            updateStatus(true);
            loadCoreMode();
        }
    });

    document.addEventListener('visibilitychange', function () {
        if (!document.hidden && isOverviewActive()) {
            updateStatus(true);
            loadCoreMode();
        }
    });

    function restoreTabFromHash() {
        var initialHash = window.location.hash;
        if (!initialHash || initialHash.length < 2) {
            return true;
        }
        try {
            if (!$.fn.tab) {
                return false;
            }
            if ($(initialHash).length === 0) {
                return true;
            }
            var $anchor = $('a[data-toggle="tab"][href="' + initialHash + '"]');
            if ($anchor.length === 0) {
                return true;
            }
            $anchor.tab('show');
            return true;
        } catch (e) {
            /* 非法 hash 选择器：保持默认概览 Tab */
            return true;
        }
    }

    /* Bootstrap tab 插件可能晚于 DOM-ready 就绪：短轮询直到激活成功，window load 兜底 */
    restoreTabFromHash();
    var hashRestoreTries = 0;
    var hashRestoreTimer = setInterval(function () {
        hashRestoreTries += 1;
        if (restoreTabFromHash() || hashRestoreTries > 40) {
            clearInterval(hashRestoreTimer);
        }
    }, 250);
    $(window).on('load', restoreTabFromHash);
    /* 同文档 hash 变化（浏览器前进/后退或手动改地址）也恢复对应 Tab；
       Tab 自身切换走 replaceState，不触发 hashchange，无回环 */
    $(window).on('hashchange', restoreTabFromHash);

    /* ---------- 保存成功横条 ---------- */

    function showSaveToast(msg) {
        var $t = $('#save_toast');
        $t.text(String(msg));
        $t.show();
        setTimeout(function () { $t.hide(); }, 4000);
    }

    /* ---------- 概览：状态 / 指标 / 主按钮（原运行状态页已并入此处） ---------- */

    var coreModeNames = {
        'rule': '{{ lang._("规则分流") }}',
        'global': '{{ lang._("全局代理") }}',
        'direct': '{{ lang._("直连") }}'
    };

    var stateMeta = {
        'RUNNING': { text: '{{ lang._("运行中") }}', icon: 'fa-check-circle', cls: 'label-success', dot: 'is-running' },
        'STARTING': { text: '{{ lang._("启动中") }}', icon: 'fa-spinner fa-spin', cls: 'label-info', dot: 'is-running' },
        'STOPPING': { text: '{{ lang._("停止中") }}', icon: 'fa-spinner fa-spin', cls: 'label-warning', dot: 'is-stopped' },
        'DEGRADED': { text: '{{ lang._("降级") }}', icon: 'fa-exclamation-circle', cls: 'label-warning', dot: 'is-error' },
        'FAILED': { text: '{{ lang._("故障") }}', icon: 'fa-times-circle', cls: 'label-danger', dot: 'is-error' },
        'DISABLED': { text: '{{ lang._("已禁用") }}', icon: 'fa-ban', cls: 'label-default', dot: 'is-stopped' }
    };

    function renderOverview(data) {
        data = data || {};
        var state = String(data.state || '').toUpperCase();
        var running = state === 'RUNNING';
        var meta = stateMeta[state] || { text: '{{ lang._("已停止") }}', icon: 'fa-power-off', cls: 'label-default', dot: 'is-stopped' };

        $('#ov_state_dot').removeClass('is-running is-stopped is-error').addClass(meta.dot);
        $('#ov_state_text').empty()
            .append($('<i></i>').addClass('fa ' + meta.icon).css('margin-right', '4px'))
            .append(document.createTextNode(meta.text));

        /* 接入方式徽章（悬停看隧道类型） */
        var $access = $('#service_status_badge').removeClass('label-default label-success label-primary label-info label-danger');
        var accessText = '{{ lang._("直连") }}';
        var accessCls = 'label-default';
        if (running) {
            if (data.transport_mode === 'transparent') {
                accessText = '{{ lang._("透明代理") }}';
                accessCls = 'label-info';
            } else {
                accessText = '{{ lang._("仅代理") }}';
                accessCls = 'label-primary';
            }
        }
        var accessDetail = running && data.tun_kind ? accessText + ' (' + data.tun_kind + ')' : accessText;
        $access.addClass(accessCls).text(accessDetail).attr('title', accessDetail);

        /* 主按钮可见性 */
        $('#btn_start').toggle(!running);
        $('#btn_stop').toggle(running);
        $('#btn_restart').toggle(running);
        $('#btn_reload').toggle(running);

        /* 运行指标 */
        $('#ov_uptime').text(data.uptime || '-');
        $('#ov_memory').text(data.memory || '-');
        $('#ov_pid').text(data.pid ? String(data.pid) : '-');
        var versionText = (data.plugin_version || '-') + ' / ' + (data.mihomo_version || '-');
        $('#ov_versions').text(versionText).attr('title', versionText);

        var tunMap = {
            up: { text: '{{ lang._("正常") }}', cls: 'label-success' },
            down: { text: '{{ lang._("断开") }}', cls: 'label-danger' },
            other: { text: 'SOCKS', cls: 'label-default' }
        };
        var tunKey = data.tun_status === 'UP' ? 'up' : (data.tun_status === 'DOWN' ? 'down' : 'other');
        $('#ov_tun').removeClass('label-default label-success label-danger')
            .addClass(tunMap[tunKey].cls).text(tunMap[tunKey].text);
        $('#ov_api').removeClass('label-default label-success label-danger')
            .addClass(data.api_status === 'UP' ? 'label-success' : 'label-danger')
            .text(data.api_status === 'UP' ? '{{ lang._("正常") }}' : '{{ lang._("不可用") }}');

        /* 内核模式：配置默认提示 + 服务未运行时禁用切换 */
        var cfgMode = data.core_mode || 'rule';
        $('#core_mode_config').text('{{ lang._("配置默认：") }}' + (coreModeNames[cfgMode] || cfgMode));
        $('#ov_core_mode_select, #btn_core_mode_apply').prop('disabled', !running);
        if (!running) {
            $('#core_mode_msg').removeClass('text-success text-danger').addClass('text-muted').text('{{ lang._("服务未运行") }}');
        }
    }

    function updateStatus(force) {
        /* 5 秒轮询仅服务概览 Tab；页面隐藏或离开概览时跳过请求 */
        if (force !== true && (!isOverviewActive() || document.hidden)) {
            return;
        }
        ajaxGet('/api/mihomo/status/getMihomoStatus', {}, function (data) {
            renderOverview(data);
        });
    }

    /* ---------- 剪贴板 ---------- */

    var currentApiBind = '';
    var currentApiPort = '';

    function copyToClipboard(text, successMsg) {
        if (!text || text === '-') {
            return;
        }
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text).then(function () {
                mhToast(successMsg || '{{ lang._("内容已复制到剪贴板。") }}', 'success');
            }, function () {
                fallbackCopy(text, successMsg);
            });
        } else {
            fallbackCopy(text, successMsg);
        }
    }

    function fallbackCopy(text, successMsg) {
        var $temp = $('<textarea style="position: absolute; left: -9999px; top: -9999px;"></textarea>');
        $temp.val(text).appendTo('body');
        $temp.select();
        try {
            document.execCommand('copy');
            mhToast(successMsg || '{{ lang._("内容已复制到剪贴板。") }}', 'success');
        } catch (e) {
            BootstrapDialog.show({
                type: BootstrapDialog.TYPE_WARNING,
                title: '{{ lang._("复制失败") }}',
                message: textBlock('{{ lang._("请手动复制：") }}' + text)
            });
        }
        $temp.remove();
    }

    function updateApiDisplay(bind, port) {
        currentApiBind = (bind && String(bind).trim().length > 0) ? String(bind).trim() : '';
        currentApiPort = (port && String(port).trim().length > 0) ? String(port).trim() : '';

        if (!currentApiPort) {
            $('#api_endpoint_display').text('-');
            $('#btn_copy_endpoint').prop('disabled', true);
            $('#api_wan_warn').hide();
            return;
        }

        var dispHost = (currentApiBind === '0.0.0.0') ? window.location.hostname : (currentApiBind || window.location.hostname);
        var endpointUrl = 'http://' + dispHost + ':' + currentApiPort;

        $('#api_endpoint_display').text(endpointUrl);
        $('#btn_copy_endpoint').prop('disabled', false);

        if (currentApiBind === '0.0.0.0') {
            $('#api_wan_warn').show();
        } else {
            $('#api_wan_warn').hide();
        }
    }

    $('#btn_copy_endpoint').click(function () {
        var endpoint = $('#api_endpoint_display').text();
        if (endpoint && endpoint !== '-') {
            copyToClipboard(endpoint, '{{ lang._("API 端点地址已复制到剪贴板。") }}');
        }
    });

    function loadSecretMasked() {
        ajaxGet('/api/mihomo/general/getGeneral', {}, function (data) {
            var gen = (data && data.mihomo && data.mihomo.general) ? data.mihomo.general : ((data && data.general) ? data.general : {});
            var masked = gen.secret_masked || '';
            $('#api_secret_masked').text(masked || '{{ lang._("未配置") }}');
            var bind = gen.api_bind;
            var port = gen.api_port;
            if ($('#api_bind').length && !$('#api_bind').data('user-touched')) {
                $('#api_bind').val(bind || '');
            }
            if ($('#api_port').length && !$('#api_port').data('user-touched')) {
                $('#api_port').val(port || '');
            }
            updateApiDisplay(bind, port);
            /* 概览：开机自启（配置意图；运行态接入方式与内核模式由 getMihomoStatus 驱动） */
            $('#ov_autostart').text(flagEnabled(gen.enabled) === '1' ? '{{ lang._("开") }}' : '{{ lang._("关") }}');
        });
    }

    $('#api_bind, #api_port').on('input change', function () {
        $(this).data('user-touched', true);
        updateApiDisplay($('#api_bind').val(), $('#api_port').val());
    });

    /* 内核模式：运行时模式下拉（原运行状态页功能并入概览） */
    function loadCoreMode() {
        ajaxGet('/api/mihomo/status/getMode', {}, function (data) {
            var $msg = $('#core_mode_msg');
            if (data && data.reachable && data.mode) {
                $('#ov_core_mode_select').val(data.mode);
                if ($msg.hasClass('text-danger')) {
                    $msg.removeClass('text-danger text-muted').text('');
                }
            } else {
                var note = (data && data.note) ? data.note : '{{ lang._("API 不可达") }}';
                $msg.removeClass('text-success text-muted').addClass('text-danger').text(note);
            }
        });
    }

    $('#btn_core_mode_apply').click(function () {
        var selectedMode = $('#ov_core_mode_select').val();
        var $btn = $(this);
        var $msg = $('#core_mode_msg');
        $btn.prop('disabled', true);
        $msg.removeClass('text-danger text-success').addClass('text-muted').text('{{ lang._("切换中...") }}');
        ajaxCall('/api/mihomo/status/setMode', { mode: selectedMode }, function (res) {
            $btn.prop('disabled', false);
            if (res && res.status === 'ok') {
                $msg.removeClass('text-danger text-muted').addClass('text-success').text(res.message || '{{ lang._("切换成功") }}');
                setTimeout(function () {
                    updateStatus(true);
                    loadCoreMode();
                }, 500);
            } else {
                var err = (res && res.message) ? res.message : '{{ lang._("切换失败") }}';
                $msg.removeClass('text-success text-muted').addClass('text-danger').text(err);
            }
        });
    });

    $('#btn_ov_refresh').click(function () {
        updateStatus(true);
        loadCoreMode();
        loadSubscription(false);
    });

    function showSecretDialog(title, secret) {
        var $input = $('<input type="text" class="form-control" readonly style="font-family: Menlo, Monaco, Consolas, monospace;"/>').val(secret);
        var $wrap = $('<div></div>');
        var dispHost = (currentApiBind === '0.0.0.0') ? window.location.hostname : (currentApiBind || '-');
        var endpointText = currentApiPort ? (dispHost + ':' + currentApiPort) : '-';
        $('<p></p>').text('{{ lang._("使用此密钥登录 Web 控制台 / Metacubexd（地址 ") }}' + endpointText + '）：').appendTo($wrap);
        $input.appendTo($wrap);
        BootstrapDialog.show({
            type: BootstrapDialog.TYPE_INFO,
            title: title,
            message: $wrap,
            onshown: function (dialog) {
                $input.on('focus click', function () { this.select(); });
                $input.focus();
            }
        });
    }

    mapDataToFormUI({'frm_general_settings': '/api/mihomo/general/getGeneral'}).done(function () {
        formatTokenizersUI();
        $('.selectpicker').selectpicker('refresh');
        classifyFormRows();
        hideFormApiRows();
        updateStatus(true);
    });

    /* 隐藏运行参数中与面板与 API 重复的 api_bind / api_port 行，避免两处编辑冲突 */
    function hideFormApiRows() {
        $('#frm_general_settings [id$="general.api_bind"]').closest('tr').hide();
        $('#frm_general_settings [id$="general.api_port"]').closest('tr').hide();
    }

    /* 宽屏两列表单：仅 checkbox 行占满整行（长 help 行在两列内换行展示） */
    function classifyFormRows() {
        $('#frm_general_settings table.table > tbody > tr').each(function () {
            if ($(this).find('input[type="checkbox"]').length > 0) {
                $(this).addClass('mh-span-full');
            }
        });
    }

    /* ---------- 服务控制 ---------- */

    function callServiceAction(action) {
        ajaxCall('/api/mihomo/service/' + action, {}, function (data) {
            if (data && data.status === 'ok') {
                mhToast(data.response || '{{ lang._("操作执行成功。") }}', 'success');
            } else {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_DANGER,
                    title: '{{ lang._("错误") }}',
                    message: textBlock((data && data.message) ? data.message : '{{ lang._("操作失败。") }}')
                });
            }
            setTimeout(function () {
                updateStatus(true);
                loadCoreMode();
            }, 1000);
        });
    }

    $('#btn_start').click(function() { callServiceAction('start'); });
    $('#btn_stop').click(function() {
        BootstrapDialog.confirm({
            title: '{{ lang._("确认停止服务") }}',
            message: '{{ lang._("停止 Mihomo 将中断透明代理分流并恢复直连，确定停止？") }}',
            type: BootstrapDialog.TYPE_DANGER,
            btnCancelLabel: '{{ lang._("取消") }}',
            btnOKLabel: '{{ lang._("确认停止") }}',
            btnOKClass: 'btn-danger',
            callback: function (confirmed) {
                if (confirmed) {
                    callServiceAction('stop');
                }
            }
        });
    });
    $('#btn_restart').click(function() { callServiceAction('restart'); });
    $('#btn_reload').click(function() { callServiceAction('reload'); });

    $('#btn_save').click(function () {
        var $progress = $('#btn_save_progress');
        var $button = $('#btn_save');
        $progress.addClass('fa fa-spinner fa-pulse');
        $button.prop('disabled', true);
        saveFormToEndpoint('/api/mihomo/general/setGeneral', 'frm_general_settings', function (data) {
            $progress.removeClass('fa fa-spinner fa-pulse');
            $button.prop('disabled', false);
            updateStatus(true);
            var failed = (data && data.status === 'failed');
            var $message = messageLines(failed ? [] : (data ? data.messages : []));
            var flat = '';
            if ($message.children().length === 0) {
                if (failed) {
                    $message.text(data && data.message ? data.message : '{{ lang._("保存设置失败。") }}');
                } else {
                    $message.text('{{ lang._("设置已保存。") }}');
                }
            }
            if (failed) {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_DANGER,
                    title: '{{ lang._("错误") }}',
                    message: $message
                });
            } else {
                $message.children().each(function () { flat += $(this).text() + ' '; });
                showSaveToast($.trim(flat) || '{{ lang._("设置已保存。") }}');
            }
            loadSecretMasked();
        }, true, function (data) {
            $progress.removeClass('fa fa-spinner fa-pulse');
            $button.prop('disabled', false);
            updateStatus(true);
            BootstrapDialog.show({
                type: BootstrapDialog.TYPE_DANGER,
                title: '{{ lang._("错误") }}',
                message: textBlock(data && data.message ? data.message : '{{ lang._("保存设置失败。") }}')
            });
        });
    });

    /* ---------- 订阅与策略 ---------- */

    function setSubUpdating(active) {
        subUpdateInProgress = active;
        $('#btn_sub_update, #ov_btn_sub_update').prop('disabled', active);
        $('#btn_sub_update_icon').removeClass('fa-cloud-download fa-spinner fa-pulse');
        $('#btn_sub_update_icon').addClass(active ? 'fa-spinner fa-pulse' : 'fa-cloud-download');
    }

    function flagEnabled(value) {
        return (value === true || value === 1 || value === '1' || value === 'true') ? '1' : '0';
    }

    function relativeTime(iso) {
        if (!iso) {
            return '-';
        }
        var t = new Date(String(iso));
        var ms = t.getTime();
        if (isNaN(ms)) {
            return String(iso);
        }
        var diff = (new Date()).getTime() - ms;
        if (diff < 0) {
            diff = 0;
        }
        var min = Math.floor(diff / 60000);
        if (min < 1) {
            return '{{ lang._("刚刚") }}';
        }
        if (min < 60) {
            return min + ' {{ lang._("分钟前") }}';
        }
        var h = Math.floor(min / 60);
        if (h < 24) {
            return h + ' {{ lang._("小时前") }}';
        }
        return Math.floor(h / 24) + ' {{ lang._("天前") }}';
    }

    function fmtNum(v) {
        if (v === undefined || v === null || v === '') {
            return '-';
        }
        return String(v).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    }

    function renderLastUpdate(lastUpdate) {
        var $badge = $('#sub_state_result');
        var $ovBadge = $('#ov_sub_result');
        $badge.removeClass('label-default label-success label-danger label-warning');
        $ovBadge.removeClass('label-default label-success label-danger label-warning');
        if (!lastUpdate || typeof lastUpdate !== 'object') {
            subLastUpdateTime = null;
            $('#sub_state_time').text('-').attr('title', '');
            $badge.addClass('label-default').text('-');
            $('#ov_nodes').text('-');
            $('#ov_groups').text('-');
            $('#ov_rules').text('-');
            $('#ov_sub_result').addClass('label-default').text('-');
            $('#ov_sub_time').text('-');
            return;
        }
        subLastUpdateTime = lastUpdate.time ? String(lastUpdate.time) : null;
        /* 时间：相对时间展示，悬停显示完整时间 */
        $('#sub_state_time').text(relativeTime(lastUpdate.time))
            .attr('title', lastUpdate.time ? String(lastUpdate.time).replace('T', ' ').replace('Z', ' (UTC)') : '');
        var result = (lastUpdate.result ? String(lastUpdate.result) : '').toLowerCase();
        var resultText = '-';
        var resultClass = 'label-default';
        if (result === 'success') {
            resultClass = 'label-success';
            resultText = '{{ lang._("成功") }}';
        } else if (result === 'failed') {
            resultClass = 'label-danger';
            resultText = '{{ lang._("失败") }}';
        } else if (result.length > 0) {
            resultClass = 'label-warning';
            resultText = result;
        }
        $badge.addClass(resultClass).text(resultText);
        $ovBadge.addClass(resultClass).text(resultText);
        /* 概览数字（骨架占位在此被 .text() 替换；千分位仅用于展示） */
        $('#ov_nodes').text(fmtNum(lastUpdate.nodes));
        $('#ov_groups').text(fmtNum(lastUpdate.groups));
        $('#ov_rules').text(fmtNum(lastUpdate.rules));
        $('#ov_sub_time').text(relativeTime(lastUpdate.time));
    }

    function applySubscription(sub) {
        sub = sub || {};
        var url = mhFromEntities(sub.url);
        subHasUrl = (flagEnabled(sub.has_url) === '1') || (url.length > 0);
        $('#sub_url').val(url);
        if (subHasUrl) {
            $('#sub_url_hint').removeClass('text-muted').addClass('text-info')
                .text('{{ lang._("已配置订阅地址。修改后点击「保存订阅」生效；留空保存则保持现有地址不变。") }}');
        } else {
            $('#sub_url_hint').removeClass('text-info').addClass('text-muted').text('{{ lang._("请输入 https 订阅地址。") }}');
        }
        $('#sub_auto_update').prop('checked', flagEnabled(sub.auto_update) === '1');
        var interval = sub.auto_interval ? String(sub.auto_interval) : 'o24h';
        if (interval !== 'o6h' && interval !== 'o12h' && interval !== 'o24h') {
            interval = 'o24h';
        }
        $('#sub_interval').val(interval);
    }

    function loadSubscription(applyForm) {
        ajaxGet('/api/mihomo/subscription/get', {}, function (data) {
            if (!data || data.status !== 'ok') {
                /* 接口异常时落地骨架屏，避免占位扫光常驻 */
                renderLastUpdate(null);
                return;
            }
            if (applyForm !== false) {
                applySubscription(data.subscription);
            }
            renderLastUpdate(data.last_update);
        });
    }

    function stopSubPolling(finished) {
        if (subPollTimer !== null) {
            clearInterval(subPollTimer);
            subPollTimer = null;
        }
        setSubUpdating(false);
        $('#sub_state_message').text('');
        if (finished === true) {
            loadSubscription(false);
        }
    }

    function startSubPolling() {
        if (subPollTimer !== null) {
            clearInterval(subPollTimer);
            subPollTimer = null;
        }
        subPollStart = (new Date()).getTime();
        setSubUpdating(true);
        $('#sub_state_message').text('{{ lang._("已触发更新，正在等待结果...") }}');
        subPollTimer = setInterval(function () {
            if (((new Date()).getTime() - subPollStart) > 1200000) {
                stopSubPolling(false);
                $('#sub_state_message').text('{{ lang._("更新仍在后台执行，请稍后刷新页面查看结果。") }}');
                return;
            }
            ajaxGet('/api/mihomo/subscription/get', {}, function (data) {
                if (!data || data.status !== 'ok' || !data.last_update) {
                    return;
                }
                var result = (data.last_update.result ? String(data.last_update.result) : '').toLowerCase();
                var updateTime = data.last_update.time ? String(data.last_update.time) : '';
                var changed = (subBaselineTime === null) || (updateTime !== subBaselineTime);
                if (!changed) {
                    /* 状态文件仍是触发前那一轮的结果，保持“等待中”提示 */
                    return;
                }
                renderLastUpdate(data.last_update);
                if (result === 'success' || result === 'failed') {
                    stopSubPolling(false);
                }
            });
        }, 3000);
    }

    $('#btn_sub_save').click(function () {
        var url = $.trim($('#sub_url').val() || '');
        if (url.length > 0 && url.indexOf('https://') !== 0) {
            BootstrapDialog.show({
                type: BootstrapDialog.TYPE_DANGER,
                title: '{{ lang._("错误") }}',
                message: textBlock('{{ lang._("订阅地址必须以 https:// 开头。") }}')
            });
            return;
        }
        if (url.length === 0 && !subHasUrl) {
            BootstrapDialog.show({
                type: BootstrapDialog.TYPE_WARNING,
                title: '{{ lang._("错误") }}',
                message: textBlock('{{ lang._("请输入订阅地址。") }}')
            });
            return;
        }
        var payload = {
            auto_update: $('#sub_auto_update').is(':checked') ? '1' : '0',
            auto_interval: $('#sub_interval').val()
        };
        if (url.length > 0) {
            payload.url = url;
        }
        var $progress = $('#btn_sub_save_progress');
        var $button = $('#btn_sub_save');
        $progress.addClass('fa fa-spinner fa-pulse');
        $button.prop('disabled', true);
        ajaxCall('/api/mihomo/subscription/set', payload, function (data) {
            $progress.removeClass('fa fa-spinner fa-pulse');
            $button.prop('disabled', false);
            if (data && data.status === 'ok') {
                if (url.length > 0) {
                    subHasUrl = true;
                    $('#sub_url').val(url);
                }
                $('#sub_url_hint').removeClass('text-muted').addClass('text-info').text('{{ lang._("已配置订阅地址。修改后点击「保存订阅」生效；留空保存则保持现有地址不变。") }}');
                mhToast(data.message || '{{ lang._("订阅设置已保存。") }}', 'success');
                loadSubscription(false);
            } else {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_DANGER,
                    title: '{{ lang._("错误") }}',
                    message: textBlock(data && data.message ? data.message : '{{ lang._("保存订阅设置失败。") }}')
                });
            }
        });
    });

    function triggerSubUpdate() {
        if (subUpdateInProgress) {
            return;
        }
        setSubUpdating(true);
        ajaxCall('/api/mihomo/subscription/update', {}, function (data) {
            var status = (data && data.status) ? data.status : 'failed';
            if (status === 'triggered') {
                subBaselineTime = subLastUpdateTime;
                startSubPolling();
            } else if (status === 'busy') {
                setSubUpdating(false);
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_WARNING,
                    title: '{{ lang._("订阅更新") }}',
                    message: textBlock('{{ lang._("当前已有更新任务正在运行，请等待其完成。") }}')
                });
            } else {
                setSubUpdating(false);
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_DANGER,
                    title: '{{ lang._("错误") }}',
                    message: textBlock(data && data.message ? data.message : '{{ lang._("触发订阅更新失败。") }}')
                });
            }
        });
    }

    $('#btn_sub_update').click(triggerSubUpdate);
    $('#ov_btn_sub_update').click(triggerSubUpdate);

    /* ---------- 面板与 API ---------- */

    $('#btn_secret_reveal').click(function () {
        ajaxCall('/api/mihomo/general/secretReveal', {}, function (data) {
            if (data && data.status === 'ok') {
                showSecretDialog('{{ lang._("查看 API 密钥") }}', data.secret);
            } else {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_DANGER,
                    title: '{{ lang._("错误") }}',
                    message: textBlock(data && data.message ? data.message : '{{ lang._("获取 API 密钥失败。") }}')
                });
            }
        });
    });

    function generateRandomSecret(len) {
        len = len || 32;
        var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
        var arr = new Uint8Array(len);
        if (window.crypto && window.crypto.getRandomValues) {
            window.crypto.getRandomValues(arr);
        } else {
            for (var i = 0; i < len; i++) {
                arr[i] = Math.floor(Math.random() * 256);
            }
        }
        var str = '';
        for (var j = 0; j < len; j++) {
            str += chars[arr[j] % chars.length];
        }
        return str;
    }

    $('#btn_secret_generate').click(function () {
        var newSec = generateRandomSecret(32);
        $('#api_secret_custom').val(newSec);
        mhToast('{{ lang._("已生成随机密钥并填入自定义密钥输入框，请点击下方「保存并应用」生效。") }}', 'info');
    });

    $('#btn_secret_apply').click(function () {
        var secret = $.trim($('#api_secret_custom').val());
        if (secret.length < 4 || secret.length > 128) {
            BootstrapDialog.show({
                type: BootstrapDialog.TYPE_WARNING,
                title: '{{ lang._("错误") }}',
                message: textBlock('{{ lang._("密钥长度必须为 4-128 个字符。") }}')
            });
            return;
        }
        if (!/^[A-Za-z0-9._~@#%^+=:;,!?*-]+$/.test(secret)) {
            BootstrapDialog.show({
                type: BootstrapDialog.TYPE_WARNING,
                title: '{{ lang._("错误") }}',
                message: textBlock('{{ lang._("仅允许字母、数字以及 . _ ~ @ # % ^ + = : ; , ! ? * -") }}')
            });
            return;
        }
        mhToast('{{ lang._("密钥已就绪，请点击下方「保存并应用」统一提交保存。") }}', 'info');
    });

    $('#btn_api_save').click(function () {
        var bind = $.trim($('#api_bind').val());
        var port = $.trim($('#api_port').val());
        var customSecret = $.trim($('#api_secret_custom').val());

        if (customSecret.length > 0) {
            if (customSecret.length < 4 || customSecret.length > 128) {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_WARNING,
                    title: '{{ lang._("错误") }}',
                    message: textBlock('{{ lang._("密钥长度必须为 4-128 个字符。") }}')
                });
                return;
            }
            if (!/^[A-Za-z0-9._~@#%^+=:;,!?*-]+$/.test(customSecret)) {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_WARNING,
                    title: '{{ lang._("错误") }}',
                    message: textBlock('{{ lang._("仅允许字母、数字以及 . _ ~ @ # % ^ + = : ; , ! ? * -") }}')
                });
                return;
            }
        }

        var $progress = $('#btn_api_save_progress');
        var $button = $('#btn_api_save');
        $progress.addClass('fa fa-spinner fa-pulse');
        $button.prop('disabled', true);

        // 如果填写了自定义密钥，先写密钥，成功后再存 general 配置
        function saveGeneralParams() {
            var payload = {
                general: {
                    api_bind: bind,
                    api_port: port
                }
            };
            ajaxCall('/api/mihomo/general/setGeneral', payload, function (data) {
                $progress.removeClass('fa fa-spinner fa-pulse');
                $button.prop('disabled', false);
                updateStatus(true);
                var failed = (data && data.status === 'failed');
                if (failed) {
                    BootstrapDialog.show({
                        type: BootstrapDialog.TYPE_DANGER,
                        title: '{{ lang._("错误") }}',
                        message: textBlock(data && data.message ? data.message : '{{ lang._("保存设置失败。") }}')
                    });
                } else {
                    $('#api_bind').data('user-touched', false);
                    $('#api_port').data('user-touched', false);
                    $('#api_secret_custom').val('');
                    showSaveToast('{{ lang._("控制 API 设置已保存并应用。") }}');
                    loadSecretMasked();
                }
            });
        }

        if (customSecret.length > 0) {
            ajaxCall('/api/mihomo/general/secretSet', { secret: customSecret }, function (secData) {
                if (secData && secData.status === 'ok') {
                    saveGeneralParams();
                } else {
                    $progress.removeClass('fa fa-spinner fa-pulse');
                    $button.prop('disabled', false);
                    BootstrapDialog.show({
                        type: BootstrapDialog.TYPE_DANGER,
                        title: '{{ lang._("错误") }}',
                        message: textBlock(secData && secData.message ? secData.message : '{{ lang._("更新 API 密钥失败。") }}')
                    });
                }
            });
        } else {
            saveGeneralParams();
        }
    });

    /* ---------- 初始化 ---------- */

    loadSubscription(true);
    loadSecretMasked();
    loadCoreMode();
    updateStatus(true);
    setInterval(updateStatus, 5000);
});
</script>
