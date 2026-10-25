{#
 # Copyright (C) 2024-2026 Deciso B.V.
 # All rights reserved.
 #}

{{ partial('OPNsense/Mihomo/styles') }}

<div class="mihomo-page">
    <div class="mihomo-tabs-bar">
        <ul class="nav nav-tabs" role="tablist">
            <li class="active" role="presentation"><a href="#tab_rules_edit" data-toggle="tab" role="tab"><i class="fa fa-filter"></i> {{ lang._('自定义规则') }}</a></li>
            <li role="presentation"><a href="#tab_rules_query" data-toggle="tab" role="tab"><i class="fa fa-search"></i> {{ lang._('规则查询') }}</a></li>
        </ul>
    </div>

    <div class="tab-content">
        <!-- Tab 1：自定义规则编辑器 -->
        <div class="tab-pane active" id="tab_rules_edit">
            <div class="mihomo-card">
                <div class="mihomo-card-head">
                    <h2 class="mihomo-card-title">
                        <span><i class="fa fa-filter"></i> {{ lang._('自定义规则') }}</span>
                        <div class="btn-group btn-group-xs">
                            <button class="btn btn-default active" id="btn_mode_table" type="button">
                                <i class="fa fa-table"></i> {{ lang._('表格模式') }}
                            </button>
                            <button class="btn btn-default" id="btn_mode_raw" type="button">
                                <i class="fa fa-code"></i> {{ lang._('源码模式') }}
                            </button>
                        </div>
                    </h2>
                </div>
                <div class="mihomo-card-body">
                    <p class="mihomo-subtitle">{{ lang._('自定义规则插入到生成规则顶部，订阅更新后依然保留。') }}</p>

                    <!-- 文件级错误（line=0）与源码模式错误清单 -->
                    <div id="rules_file_error" class="alert alert-danger" style="display: none; margin-bottom: 10px;"></div>
                    <table id="rules_error_table" class="table table-condensed table-bordered" style="display: none;">
                        <thead>
                            <tr>
                                <th style="width: 80px;">{{ lang._('行号') }}</th>
                                <th>{{ lang._('错误信息') }}</th>
                            </tr>
                        </thead>
                        <tbody id="rules_error_body"></tbody>
                    </table>

                    <!-- 表格模式 -->
                    <div id="rules_table_view">
                        <div class="table-responsive mihomo-table-wrap mihomo-editor-wrap">
                            <table class="table table-condensed mihomo-editor-table" id="tbl_rules_editor">
                                <thead>
                                    <tr>
                                        <th class="mh-col-index">{{ lang._('序号') }}</th>
                                        <th class="mh-col-type">{{ lang._('类型') }}</th>
                                        <th>{{ lang._('值') }}</th>
                                        <th class="mh-col-target">{{ lang._('目标策略') }}</th>
                                        <th class="mh-col-opt">{{ lang._('解析') }}</th>
                                        <th class="mh-col-act">{{ lang._('操作') }}</th>
                                    </tr>
                                </thead>
                                <tbody id="tbl_rules_body"></tbody>
                            </table>
                        </div>
                    </div>

                    <!-- 源码模式 -->
                    <div id="rules_raw_view" style="display: none;">
                        <textarea id="rules_content" class="form-control mihomo-mono mh-input-wide" rows="16" spellcheck="false" style="font-size: 13px; line-height: 1.5; height: 360px; resize: vertical;"></textarea>
                        <span class="help-block">{{ lang._('每行一条规则：类型,值,目标[,no-resolve]；# 开头为注释行。') }}</span>
                    </div>

                    <div class="mihomo-toolbar mihomo-editor-foot">
                        <button class="btn btn-default btn-sm" id="btn_add_rule_row" type="button">
                            <i class="fa fa-plus"></i> {{ lang._('添加规则') }}
                        </button>
                        <div style="display: flex; align-items: center; gap: 14px; flex-wrap: wrap;">
                            <span class="text-muted" id="rules_counter" style="font-size: 12px;"></span>
                            <button class="btn btn-primary btn-sm" id="btn_rules_apply" type="button" disabled>
                                <b>{{ lang._('校验并应用') }}</b> <i id="btn_rules_apply_progress"></i>
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Tab 2：规则查询（按需查询内核生效规则，不默认铺全量） -->
        <div class="tab-pane" id="tab_rules_query">
            <div class="mihomo-card">
                <div class="mihomo-card-head">
                    <h2 class="mihomo-card-title">
                        <span><i class="fa fa-search"></i> {{ lang._('规则查询') }} <span id="effective_total_badge" class="badge" style="margin-left: 8px; font-weight: normal; background-color: #f0f0f0; color: #555555;"></span></span>
                        <button class="btn btn-default btn-xs" id="btn_refresh_effective" type="button">
                            <i class="fa fa-refresh"></i> {{ lang._('重新查询') }} <i id="effective_refresh_spinner"></i>
                        </button>
                    </h2>
                </div>
                <div class="mihomo-card-body">
                    <div class="mihomo-query-bar">
                        <div class="form-group" style="flex: 1 1 320px; margin-bottom: 0;">
                            <label for="filter_effective_rules" style="font-size: 12px;">{{ lang._('关键词') }}</label>
                            <input type="text" id="filter_effective_rules" class="form-control input-sm mh-input-wide" placeholder="{{ lang._('规则类型、域名或目标策略，如 google') }}" autocomplete="off" spellcheck="false">
                        </div>
                        <div class="form-group" style="margin-bottom: 0;">
                            <label for="effective_limit" style="font-size: 12px;">{{ lang._('每页条数') }}</label>
                            <select id="effective_limit" class="form-control input-sm" style="width: 110px;">
                                <option value="200" selected>200</option>
                                <option value="500">500</option>
                                <option value="1000">1000</option>
                            </select>
                        </div>
                        <button class="btn btn-primary btn-sm" id="btn_effective_search" type="button">
                            <i class="fa fa-search"></i> {{ lang._('查询') }}
                        </button>
                    </div>

                    <div id="effective_rules_alert" class="alert alert-warning" style="display: none; margin-top: 12px;"></div>

                    <div id="effective_rules_empty" class="mihomo-empty">
                        <i class="fa fa-search"></i> {{ lang._('输入关键词查询内核当前生效的分流规则；留空点击查询则浏览全部规则。') }}
                    </div>

                    <div class="table-responsive mihomo-table-wrap mihomo-query-wrap" id="effective_table_wrap" style="display: none;">
                        <table class="table table-condensed" id="tbl_effective_rules">
                            <thead>
                                <tr>
                                    <th class="mh-col-index">{{ lang._('序号') }}</th>
                                    <th class="mh-col-type">{{ lang._('类型') }}</th>
                                    <th>{{ lang._('值') }}</th>
                                    <th class="mh-col-target">{{ lang._('目标策略') }}</th>
                                </tr>
                            </thead>
                            <tbody id="tbl_effective_body"></tbody>
                        </table>
                    </div>

                    <div class="mihomo-toolbar mihomo-editor-foot" id="effective_pager" style="display: none;">
                        <span class="text-muted" id="effective_count_label" style="font-size: 12px;"></span>
                        <div class="btn-group btn-group-sm">
                            <button class="btn btn-default" id="effective_first" type="button" title="{{ lang._('首页') }}">
                                <i class="fa fa-angle-double-left"></i>
                            </button>
                            <button class="btn btn-default" id="effective_prev" type="button">
                                <i class="fa fa-chevron-left"></i> {{ lang._('上一页') }}
                            </button>
                            <span class="btn btn-default" id="effective_page_info" style="cursor: default; opacity: 1;">- / -</span>
                            <button class="btn btn-default" id="effective_next" type="button">
                                {{ lang._('下一页') }} <i class="fa fa-chevron-right"></i>
                            </button>
                            <button class="btn btn-default" id="effective_last" type="button" title="{{ lang._('末页') }}">
                                <i class="fa fa-angle-double-right"></i>
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>

<script>
$(function () {
    var rulesLimits = {
        maxLines: 200,
        maxBytes: 32768
    };

    var allowedRuleTypes = [
        'DOMAIN',
        'DOMAIN-SUFFIX',
        'DOMAIN-KEYWORD',
        'IP-CIDR',
        'IP-CIDR6',
        'GEOIP',
        'GEOSITE',
        'DST-PORT'
    ];

    var BUILTIN_TARGETS = ['DIRECT', 'REJECT', 'REJECT-DROP'];
    var allowedTargets = BUILTIN_TARGETS.slice();
    var liveGroups = [];
    var currentMode = 'table'; // 'table' or 'raw'
    var searched = false;
    // 规则内容成功加载前禁止提交：空编辑器一旦提交会清空 custom-rules.txt
    var rulesLoaded = false;

    var effectivePagination = {
        limit: 200,
        offset: 0,
        total: 0,
        query: ''
    };

    /* ---------- 工具 ---------- */

    function utf8Bytes(text) {
        if (typeof Blob === 'function') {
            try {
                return (new Blob([text])).size;
            } catch (e) {
                /* Blob 不可用时回落到编码估算 */
            }
        }
        return encodeURIComponent(text).replace(/%[0-9A-F]{2}/gi, 'x').length;
    }

    function countRuleLines(text) {
        var count = 0;
        $.each(String(text).split(/\r?\n/), function (i, line) {
            if ($.trim(line).length > 0) {
                count += 1;
            }
        });
        return count;
    }

    function currentEditorText() {
        return (currentMode === 'table') ? serializeTableToText() : ($('#rules_content').val() || '');
    }

    function fmtNum(v) {
        return String(v).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    }

    function updateCounter() {
        var text = currentEditorText();
        var bytes = utf8Bytes(text);
        var lines = countRuleLines(text);
        var $counter = $('#rules_counter');
        var over = [];
        if (lines > rulesLimits.maxLines) {
            over.push('{{ lang._("超出最大行数限制。") }}');
        }
        if (bytes > rulesLimits.maxBytes) {
            over.push('{{ lang._("超出最大字节限制。") }}');
        }
        $counter.removeClass('text-danger');
        $counter.text('{{ lang._("行数") }} ' + lines + ' / ' + rulesLimits.maxLines +
            ' · {{ lang._("字节") }} ' + bytes + ' / ' + rulesLimits.maxBytes +
            (over.length ? (' · ' + over.join(' ')) : ''));
        if (over.length > 0) {
            $counter.addClass('text-danger');
        }
    }

    /* ---------- 目标策略（只服务行内选择器，不再整条展示） ---------- */

    function targetNames() {
        var names = [];
        var seen = {};
        function add(name) {
            name = String(name || '');
            if (name === '' || seen[name]) {
                return;
            }
            seen[name] = true;
            names.push(name);
        }
        $.each(BUILTIN_TARGETS, function (i, name) { add(name); });
        $.each(allowedTargets, function (i, name) { add(name); });
        $.each(liveGroups, function (i, group) { add(group && group.name); });
        return names;
    }

    function loadLiveGroups() {
        ajaxGet('/api/mihomo/proxies/getGroups', {}, function (data) {
            if (!data || data.status !== 'ok' || !data.reachable || !Array.isArray(data.groups)) {
                return;
            }
            liveGroups = data.groups;
        });
    }

    function buildTypeSelect(selectedType) {
        var $select = $('<select class="form-control input-sm rule-field-type"></select>');
        var found = false;
        $.each(allowedRuleTypes, function (i, t) {
            var $opt = $('<option></option>').attr('value', t).text(t);
            if (t === selectedType) {
                $opt.prop('selected', true);
                found = true;
            }
            $select.append($opt);
        });
        if (!found && selectedType) {
            $('<option></option>').attr('value', selectedType).text(selectedType).prop('selected', true).prependTo($select);
        }
        return $select;
    }

    function appendPickerItem($list, name, meta, current, onPick) {
        var $item = $('<button type="button" class="mihomo-picker-item"></button>');
        if (name === current) {
            $item.addClass('is-active');
        }
        $('<span class="mihomo-picker-name"></span>').text(String(name)).appendTo($item);
        var detail = '';
        if (meta) {
            detail = String(meta.type || '');
            if (meta.now) {
                detail += (detail ? ' · ' : '') + '{{ lang._("当前") }}：' + String(meta.now);
            }
            if (meta.count !== undefined && meta.count !== null) {
                detail += (detail ? ' · ' : '') + String(meta.count) + ' {{ lang._("个节点") }}';
            }
        }
        if (detail) {
            $('<span class="mihomo-picker-meta"></span>').text(detail).appendTo($item);
        }
        $item.on('click', function () {
            onPick(name);
        });
        $list.append($item);
    }

    function openTargetPicker($hidden, $label) {
        var current = String($hidden.val() || '');
        var $wrap = $('<div></div>');
        var $search = $('<input type="text" class="form-control input-sm mihomo-picker-search" placeholder="{{ lang._('搜索目标策略') }}">');
        var $list = $('<div class="mihomo-picker-list"></div>');
        $wrap.append($search).append($list);

        var dialog = BootstrapDialog.show({
            type: BootstrapDialog.TYPE_DEFAULT,
            title: '{{ lang._("选择目标策略") }}',
            message: $wrap,
            onshown: function () {
                $search.focus();
            }
        });

        function pick(name) {
            $hidden.val(name);
            $label.text(name);
            $hidden.trigger('change');
            dialog.close();
        }

        function renderList() {
            var q = $.trim(String($search.val() || '')).toLowerCase();
            $list.empty();

            if (current && $.inArray(current, targetNames()) < 0) {
                $('<div class="mihomo-picker-section"></div>').text('{{ lang._("当前目标（不在列表中）") }}').appendTo($list);
                appendPickerItem($list, current, null, current, pick);
            }

            $('<div class="mihomo-picker-section"></div>').text('{{ lang._("内置动作") }}').appendTo($list);
            $.each(BUILTIN_TARGETS, function (i, name) {
                if (q !== '' && String(name).toLowerCase().indexOf(q) < 0) {
                    return;
                }
                appendPickerItem($list, name, null, current, pick);
            });

            $('<div class="mihomo-picker-section"></div>').text('{{ lang._("代理组") }}').appendTo($list);
            var groups = liveGroups;
            if (!groups || groups.length === 0) {
                groups = [];
                $.each(allowedTargets, function (i, name) {
                    if ($.inArray(name, BUILTIN_TARGETS) < 0) {
                        groups.push({name: name});
                    }
                });
            }
            var shown = 0;
            $.each(groups, function (i, group) {
                var name = (group && group.name) ? String(group.name) : '';
                if (name === '') {
                    return;
                }
                if (q !== '' && name.toLowerCase().indexOf(q) < 0) {
                    return;
                }
                appendPickerItem($list, name, group, current, pick);
                shown++;
            });
            if (shown === 0) {
                $('<div class="mihomo-empty"></div>').text('{{ lang._("没有匹配的目标策略。") }}').appendTo($list);
            }
        }

        $search.on('input', renderList);
        renderList();
    }

    function buildTargetPicker(selectedTarget) {
        var $wrap = $('<div class="mihomo-target-cell"></div>');
        var $hidden = $('<input type="hidden" class="rule-field-target" />').val(selectedTarget || '');
        var $btn = $('<button type="button" class="btn btn-default btn-xs rule-target-picker"></button>');
        var $label = $('<span class="rule-target-label"></span>').text(selectedTarget ? String(selectedTarget) : '-');
        $btn.append($label).append(' ').append($('<span class="caret"></span>'));
        $btn.on('click', function () {
            openTargetPicker($hidden, $label);
        });
        $wrap.append($hidden).append($btn);
        return $wrap;
    }

    /* ---------- 自定义规则表格 ---------- */

    function createTableRow(type, payload, target, noResolve, lineNumber, commentText) {
        var $tr = $('<tr class="rule-row"></tr>');
        $tr.attr('data-line', lineNumber || '');

        $tr.append($('<td class="row-index mh-col-index"></td>'));

        if (commentText !== undefined && commentText !== null) {
            /* 注释行或无法结构化解析的行：整行原文编辑 */
            $tr.addClass('rule-comment-row');
            var $tdComment = $('<td colspan="3"></td>');
            var $input = $('<input type="text" class="form-control input-sm rule-raw-line mh-input-wide" spellcheck="false" />');
            $input.val(commentText);
            $input.on('input', updateCounter);
            $tdComment.append($input);
            $tr.append($tdComment);
        } else {
            var $tdType = $('<td class="mh-col-type"></td>');
            var $selType = buildTypeSelect(type);
            $selType.on('change', updateCounter);
            $tdType.append($selType);
            $tr.append($tdType);

            var $tdPayload = $('<td></td>');
            var $inPayload = $('<input type="text" class="form-control input-sm rule-field-payload mh-input-wide" spellcheck="false" />');
            $inPayload.val(payload || '');
            $inPayload.on('input', updateCounter);
            $tdPayload.append($inPayload);
            $tdPayload.append($('<div class="text-danger rule-row-error" style="font-size: 11px; margin-top: 3px; display: none;"></div>'));
            $tr.append($tdPayload);

            var $tdTarget = $('<td class="mh-col-target"></td>');
            var $targetCell = buildTargetPicker(target);
            $targetCell.find('.rule-field-target').on('change', updateCounter);
            $tdTarget.append($targetCell);
            $tr.append($tdTarget);

            var $tdOptions = $('<td class="mh-col-opt"></td>');
            var $chkLabel = $('<label style="font-weight: normal; margin-bottom: 0; cursor: pointer; white-space: nowrap;"></label>');
            var $chkNoResolve = $('<input type="checkbox" class="rule-field-no-resolve" style="margin-right: 4px;" />');
            if (noResolve) {
                $chkNoResolve.prop('checked', true);
            }
            $chkNoResolve.on('change', updateCounter);
            $chkLabel.append($chkNoResolve).append(document.createTextNode('no-resolve'));
            $tdOptions.append($chkLabel);
            $tr.append($tdOptions);
        }

        var $tdAction = $('<td class="mh-col-act"></td>');
        var $btnDel = $('<button class="btn btn-default btn-xs btn-del-row" type="button" title="{{ lang._("删除规则") }}"><i class="fa fa-trash-o text-danger"></i></button>');
        $btnDel.on('click', function () {
            $tr.remove();
            reindexTableRows();
            updateCounter();
        });
        $tdAction.append($btnDel);
        $tr.append($tdAction);

        return $tr;
    }

    function reindexTableRows() {
        $('#tbl_rules_body tr').each(function (idx) {
            $(this).find('.row-index').text(idx + 1);
        });
    }

    function parseTextToTable(text) {
        var $body = $('#tbl_rules_body');
        $body.empty();
        var lines = String(text || '').split(/\r?\n/);

        $.each(lines, function (idx, rawLine) {
            var lineNo = idx + 1;
            var line = $.trim(rawLine);
            if (line === '') {
                return;
            }
            if (line.charAt(0) === '#') {
                $body.append(createTableRow(null, null, null, false, lineNo, rawLine));
                return;
            }
            var parts = line.split(',');
            if (parts.length === 3 || parts.length === 4) {
                $body.append(createTableRow(
                    $.trim(parts[0]),
                    $.trim(parts[1]),
                    $.trim(parts[2]),
                    parts.length === 4 && $.trim(parts[3]) === 'no-resolve',
                    lineNo
                ));
            } else {
                /* 无法匹配 3 或 4 段的行按原文保留 */
                $body.append(createTableRow(null, null, null, false, lineNo, rawLine));
            }
        });

        if ($body.children().length === 0) {
            $body.append(createTableRow(allowedRuleTypes[0] || 'DOMAIN-SUFFIX', '', allowedTargets[0] || 'DIRECT', false, 1));
        }
        reindexTableRows();
    }

    function serializeTableToText() {
        var lines = [];
        var outLineNum = 1;
        $('#tbl_rules_body tr').each(function () {
            var $tr = $(this);
            if ($tr.hasClass('rule-comment-row')) {
                var rawVal = $tr.find('.rule-raw-line').val();
                if (rawVal !== undefined && rawVal !== null && $.trim(rawVal) !== '') {
                    lines.push(rawVal);
                    $tr.attr('data-line', outLineNum);
                    outLineNum++;
                } else {
                    $tr.removeAttr('data-line');
                }
                return;
            }
            var payload = $.trim($tr.find('.rule-field-payload').val() || '');
            /* 只有填了值才输出，避免空行生成 DOMAIN,,DIRECT 这类无效规则 */
            if (payload === '') {
                $tr.removeAttr('data-line');
                return;
            }
            var ruleStr = ($tr.find('.rule-field-type').val() || '') + ',' + payload + ',' + ($tr.find('.rule-field-target').val() || '');
            if ($tr.find('.rule-field-no-resolve').is(':checked')) {
                ruleStr += ',no-resolve';
            }
            lines.push(ruleStr);
            $tr.attr('data-line', outLineNum);
            outLineNum++;
        });
        return lines.join('\n');
    }

    /* 自定义规则的 payload 集合：查询结果中命中的行加圆点标记 */
    function getCustomPayloadsSet() {
        var set = {};
        $.each(currentEditorText().split(/\r?\n/), function (i, l) {
            var trimmed = $.trim(l);
            if (trimmed === '' || trimmed.charAt(0) === '#') {
                return;
            }
            var parts = trimmed.split(',');
            if (parts.length >= 2) {
                var p = $.trim(parts[1]);
                if (p) {
                    set[p] = true;
                }
            }
        });
        return set;
    }

    function switchMode(newMode) {
        if (currentMode === newMode) {
            return;
        }
        if (newMode === 'raw') {
            $('#rules_content').val(serializeTableToText());
            $('#rules_table_view').hide();
            $('#rules_raw_view').show();
            $('#btn_mode_table').removeClass('active');
            $('#btn_mode_raw').addClass('active');
            currentMode = 'raw';
        } else {
            parseTextToTable($('#rules_content').val() || '');
            $('#rules_raw_view').hide();
            $('#rules_table_view').show();
            $('#btn_mode_raw').removeClass('active');
            $('#btn_mode_table').addClass('active');
            currentMode = 'table';
        }
        updateCounter();
    }

    $('#btn_mode_table').on('click', function () {
        switchMode('table');
    });

    $('#btn_mode_raw').on('click', function () {
        switchMode('raw');
    });

    $('#btn_add_rule_row').on('click', function () {
        var $body = $('#tbl_rules_body');
        var $row = createTableRow(
            allowedRuleTypes[0] || 'DOMAIN-SUFFIX',
            '',
            allowedTargets[0] || 'DIRECT',
            false,
            $body.children().length + 1
        );
        $body.append($row);
        reindexTableRows();
        updateCounter();
        $row.find('.rule-field-payload').focus();
    });

    $('#rules_content').on('input', updateCounter);

    /* ---------- 规则查询（内核生效规则，按需查询） ---------- */

    function targetBadge(proxy) {
        var cls = 'label-info';
        if (proxy === 'DIRECT') {
            cls = 'label-success';
        } else if (proxy === 'REJECT' || proxy === 'REJECT-DROP') {
            cls = 'label-danger';
        }
        return $('<span class="label"></span>').addClass(cls).text(proxy || '-');
    }

    function renderQueryResult(rules, total, offset) {
        var $body = $('#tbl_effective_body');
        var custom = getCustomPayloadsSet();
        $body.empty();

        var count = Array.isArray(rules) ? rules.length : 0;
        if (count === 0) {
            $body.append(
                $('<tr></tr>').append(
                    $('<td colspan="4" class="text-center text-muted"></td>').text('{{ lang._("没有匹配的规则。") }}')
                )
            );
        }

        $.each(rules || [], function (idx, r) {
            var type = (r && r.type) ? String(r.type) : '';
            var payload = (r && r.payload) ? String(r.payload) : '';
            var proxy = (r && r.proxy) ? String(r.proxy) : '';

            var $tr = $('<tr></tr>');
            $tr.append($('<td class="mh-col-index"></td>').text(offset + idx + 1));
            $tr.append($('<td class="mh-col-type"></td>').append($('<code style="font-size: 11px; padding: 1px 4px;"></code>').text(type)));

            var $tdPayload = $('<td class="mihomo-mono"></td>');
            if (payload && custom[payload]) {
                $tdPayload.append($('<i class="fa fa-circle mh-mine-dot" title="{{ lang._("命中自定义规则") }}"></i>'));
            }
            $tdPayload.append(document.createTextNode(payload));
            $tr.append($tdPayload);

            $tr.append($('<td class="mh-col-target"></td>').append(targetBadge(proxy)));
            $body.append($tr);
        });

        var totalNum = (typeof total === 'number') ? total : 0;
        var limitNum = effectivePagination.limit;
        var startIdx = totalNum > 0 ? offset + 1 : 0;
        var endIdx = offset + count;
        var totalPages = Math.max(1, Math.ceil(totalNum / limitNum));
        var currentPage = Math.floor(offset / limitNum) + 1;

        $('#effective_count_label').text('{{ lang._("匹配") }} ' + fmtNum(totalNum) + ' {{ lang._("条") }} · {{ lang._("当前") }} ' +
            fmtNum(startIdx) + ' - ' + fmtNum(endIdx));
        $('#effective_page_info').text(currentPage + ' / ' + fmtNum(totalPages));
        $('#effective_total_badge').text(fmtNum(totalNum) + ' {{ lang._("条") }}');
        $('#effective_first, #effective_prev').prop('disabled', offset <= 0);
        $('#effective_next, #effective_last').prop('disabled', endIdx >= totalNum);

        $('#effective_table_wrap').show();
        $('#effective_pager').show();
        $('#effective_rules_empty').hide();
    }

    function runQuery(resetOffset) {
        if (resetOffset === true) {
            effectivePagination.offset = 0;
        }
        effectivePagination.limit = parseInt($('#effective_limit').val(), 10) || 200;
        effectivePagination.query = $.trim($('#filter_effective_rules').val() || '');
        searched = true;

        var $spinner = $('#effective_refresh_spinner');
        var $alert = $('#effective_rules_alert');
        $spinner.addClass('fa fa-spinner fa-spin');
        $alert.hide().empty();

        ajaxGet('/api/mihomo/rules/getEffectiveRules', {
            limit: effectivePagination.limit,
            offset: effectivePagination.offset,
            q: effectivePagination.query
        }, function (data) {
            $spinner.removeClass('fa fa-spinner fa-spin');
            if (!data || data.status !== 'ok') {
                $alert.removeClass('alert-warning').addClass('alert-danger')
                    .text('{{ lang._("查询失败。") }}').show();
                return;
            }
            if (!data.reachable) {
                var note = (data.note) ? String(data.note) : '{{ lang._("无法连接 Mihomo API 服务") }}';
                $alert.removeClass('alert-danger').addClass('alert-warning').text(note).show();
                renderQueryResult([], 0, 0);
                return;
            }
            effectivePagination.total = (typeof data.total === 'number') ? data.total : 0;
            renderQueryResult(
                Array.isArray(data.rules) ? data.rules : [],
                effectivePagination.total,
                (typeof data.offset === 'number') ? data.offset : effectivePagination.offset
            );
        });
    }

    $('#btn_effective_search').on('click', function () {
        runQuery(true);
    });

    $('#filter_effective_rules').on('keydown', function (e) {
        if (e.which === 13) {
            e.preventDefault();
            runQuery(true);
        }
    });

    $('#effective_limit').on('change', function () {
        if (searched) {
            runQuery(true);
        }
    });

    $('#btn_refresh_effective').on('click', function () {
        runQuery(!searched);
    });

    $('#effective_first').on('click', function () {
        if (effectivePagination.offset > 0) {
            effectivePagination.offset = 0;
            runQuery(false);
        }
    });

    $('#effective_prev').on('click', function () {
        if (effectivePagination.offset > 0) {
            effectivePagination.offset = Math.max(0, effectivePagination.offset - effectivePagination.limit);
            runQuery(false);
        }
    });

    $('#effective_next').on('click', function () {
        if (effectivePagination.offset + effectivePagination.limit < effectivePagination.total) {
            effectivePagination.offset += effectivePagination.limit;
            runQuery(false);
        }
    });

    $('#effective_last').on('click', function () {
        var lastOffset = Math.max(0, Math.floor((effectivePagination.total - 1) / effectivePagination.limit) * effectivePagination.limit);
        if (effectivePagination.offset !== lastOffset) {
            effectivePagination.offset = lastOffset;
            runQuery(false);
        }
    });

    /* ---------- 校验并应用 ---------- */

    function submitRules(content, clearRules) {
        var $progress = $('#btn_rules_apply_progress');
        var $button = $('#btn_rules_apply');
        var $fileError = $('#rules_file_error');
        var $errorTable = $('#rules_error_table');
        var $errorBody = $('#rules_error_body');
        var payload = {content: content};
        if (clearRules) {
            payload.clear = '1';
        }

        $progress.addClass('fa fa-spinner fa-pulse');
        $button.prop('disabled', true);
        $fileError.hide().empty();
        $errorBody.empty();
        $errorTable.hide();
        $('.rule-row-error').hide().empty();

        ajaxCall('/api/mihomo/rules/set', payload, function (data) {
            $progress.removeClass('fa fa-spinner fa-pulse');
            $button.prop('disabled', !rulesLoaded);

            if (data && data.status === 'ok') {
                mhToast(data.message ? String(data.message) : '{{ lang._("自定义规则已校验并应用。") }}', 'success');
                $('#rules_content').val(content);
                if (searched) {
                    runQuery(false);
                }
                return;
            }

            var errors = (data && Array.isArray(data.errors)) ? data.errors : [];
            var listOnly = (currentMode !== 'table');
            $.each(errors, function (i, error) {
                var lineNum = (error && error.line !== undefined && error.line !== null) ? parseInt(error.line, 10) : 0;
                var msg = (error && error.message) ? String(error.message) : '';

                if (lineNum === 0) {
                    $fileError.text(msg).show();
                } else if (!listOnly) {
                    /* 表格模式：错误回到对应行内联显示 */
                    var $targetTr = $('#tbl_rules_body tr').filter(function () {
                        return $(this).attr('data-line') == lineNum;
                    });
                    if ($targetTr.length === 0) {
                        $targetTr = $('#tbl_rules_body tr').eq(lineNum - 1);
                    }
                    if ($targetTr.length > 0) {
                        $targetTr.find('.rule-row-error').text(msg).show();
                    }
                }

                if (lineNum === 0 || listOnly) {
                    var $tr = $('<tr></tr>');
                    $('<td></td>').text(lineNum > 0 ? String(lineNum) : '{{ lang._("文件") }}').appendTo($tr);
                    $('<td></td>').text(msg).appendTo($tr);
                    $errorBody.append($tr);
                }
            });
            if ($errorBody.children().length > 0) {
                $errorTable.show();
            }

            mhToast((data && data.message) ? String(data.message) : '{{ lang._("自定义规则校验失败。") }}', 'danger', 6000);
        });
    }

    $('#btn_rules_apply').click(function () {
        if (!rulesLoaded) {
            mhToast('{{ lang._("规则尚未加载完成，请稍后重试或刷新页面。") }}', 'info');
            return;
        }
        var content = currentEditorText();
        if ($.trim(content) === '') {
            /* 后端默认拒绝空内容：清空必须在确认后显式携带 clear=1 */
            BootstrapDialog.confirm({
                title: '{{ lang._("清空自定义规则") }}',
                message: '{{ lang._("当前规则内容为空，继续将清空全部自定义规则。确定继续？") }}',
                type: BootstrapDialog.TYPE_WARNING,
                callback: function (confirmed) {
                    if (confirmed) {
                        submitRules(content, true);
                    }
                }
            });
            return;
        }
        submitRules(content, false);
    });

    /* ---------- Tab 与 hash ---------- */

    $('a[data-toggle="tab"]').on('shown.bs.tab', function (e) {
        if (history.replaceState) {
            history.replaceState(null, null, $(e.target).attr('href'));
        }
    });

    function restoreTabFromHash() {
        var initialHash = window.location.hash;
        if (!initialHash || initialHash.length < 2 || !$.fn.tab) {
            return;
        }
        /* hash 会拼进 jQuery 选择器：先过白名单，非法值（如 #a[）会让选择器抛异常 */
        if (!/^#[A-Za-z0-9_-]+$/.test(initialHash)) {
            return;
        }
        try {
            if ($(initialHash).length === 0) {
                return;
            }
            var $anchor = $('a[data-toggle="tab"][href="' + initialHash + '"]');
            if ($anchor.length > 0) {
                $anchor.tab('show');
            }
        } catch (e) {
            /* 非法 hash 选择器：保持默认 Tab */
        }
    }

    restoreTabFromHash();
    $(window).on('hashchange', restoreTabFromHash);

    /* ---------- 初始化 ---------- */

    updateCounter();

    ajaxGet('/api/mihomo/rules/get', {}, function (data) {
        if (!data || data.status !== 'ok') {
            $('#btn_rules_apply').prop('disabled', true);
            mhToast('{{ lang._("加载自定义规则失败，为避免覆盖已有规则，提交已禁用。") }}', 'danger');
            return;
        }
        if (data.limits && typeof data.limits === 'object') {
            var maxLines = parseInt(data.limits.maxLines, 10);
            var maxBytes = parseInt(data.limits.maxBytes, 10);
            if (!isNaN(maxLines) && maxLines > 0) {
                rulesLimits.maxLines = maxLines;
            }
            if (!isNaN(maxBytes) && maxBytes > 0) {
                rulesLimits.maxBytes = maxBytes;
            }
        }
        if (Array.isArray(data.ruleTypes) && data.ruleTypes.length > 0) {
            allowedRuleTypes = data.ruleTypes;
        }
        if (Array.isArray(data.targets) && data.targets.length > 0) {
            allowedTargets = data.targets;
        }
        var initialContent = (typeof data.content === 'string') ? data.content : '';
        $('#rules_content').val(initialContent);
        parseTextToTable(initialContent);
        updateCounter();
        rulesLoaded = true;
        $('#btn_rules_apply').prop('disabled', false);
        loadLiveGroups();
    });
});
</script>
