{#
 # Copyright (C) 2024-2026 Deciso B.V.
 # All rights reserved.
 #}

{{ partial('OPNsense/Mihomo/styles') }}

<div class="mihomo-page">
    <div class="mihomo-card">
        <div class="mihomo-card-head">
            <h2 class="mihomo-card-title">
                <span><i class="fa fa-file-text-o"></i> {{ lang._('实时日志') }}</span>
            </h2>
            <!-- 状态指示徽章 -->
            <span id="log_conn_status" class="label label-success" style="font-size: 12px; padding: 5px 10px;">
                <i class="fa fa-circle" style="font-size: 9px; vertical-align: middle; margin-right: 4px;"></i><span id="log_conn_text">{{ lang._('实时') }}</span>
            </span>
        </div>
        <div class="mihomo-card-body">
            <!-- 顶部控件栏 -->
            <div class="mihomo-toolbar form-inline" style="margin-bottom: 12px;">
                <div class="form-group">
                    <label for="log_level_filter" style="margin-right: 6px;">{{ lang._('日志级别') }}：</label>
                    <select id="log_level_filter" class="selectpicker" data-width="130px">
                        <option value="all" selected>{{ lang._('全部级别') }}</option>
                        <option value="debug">{{ lang._('调试') }}</option>
                        <option value="info">{{ lang._('信息') }}</option>
                        <option value="warning">{{ lang._('警告') }}</option>
                        <option value="error">{{ lang._('错误') }}</option>
                    </select>
                </div>

                <div class="form-group">
                    <label for="log_limit" style="margin-right: 6px;">{{ lang._('每页行数') }}：</label>
                    <select id="log_limit" class="selectpicker" data-width="90px">
                        <option value="20" selected>20</option>
                        <option value="50">50</option>
                        <option value="100">100</option>
                    </select>
                </div>

                <div class="form-group">
                    <button class="btn btn-default" id="btn_toggle_pause" type="button" title="{{ lang._('暂停 / 继续轮询') }}">
                        <i class="fa fa-pause" id="icon_toggle_pause"></i> <span id="text_toggle_pause">{{ lang._('暂停') }}</span>
                    </button>
                    <button class="btn btn-default" id="btn_clear_logs" type="button" title="{{ lang._('清空屏幕日志') }}">
                        <i class="fa fa-trash-o"></i> {{ lang._('清屏') }}
                    </button>
                    <button class="btn btn-default" id="btn_download_logs" type="button" title="{{ lang._('下载原始日志') }}">
                        <i class="fa fa-download"></i> {{ lang._('下载') }}
                    </button>
                </div>

                <div class="form-group">
                    <label style="font-weight: normal; margin-bottom: 0; cursor: pointer;">
                        <input type="checkbox" id="chk_auto_scroll" checked> {{ lang._('自动滚动') }}
                    </label>
                </div>
            </div>

            <!-- 表格化滚动区（高度随行数自适应，上限见 .mihomo-log-view） -->
            <div id="log_container" class="mihomo-log-view" style="min-height: 200px;">
                <table class="table table-condensed mihomo-log-table" style="margin-bottom: 0; width: 100%;">
                    <thead>
                        <tr>
                            <th class="mihomo-log-time" style="width: 175px; min-width: 175px;">{{ lang._('时间') }}</th>
                            <th class="mihomo-log-level" style="width: 80px; min-width: 80px; text-align: center;">{{ lang._('级别') }}</th>
                            <th class="mihomo-log-msg">{{ lang._('消息') }}</th>
                        </tr>
                    </thead>
                    <tbody id="log_table_body">
                        <!-- 日志动态插入 -->
                    </tbody>
                </table>
            </div>
        </div>
    </div>
</div>

<script>
$(function () {
    $('.selectpicker').selectpicker('refresh');

    var currentCursor = 0;
    var isPaused = false;
    var pollTimer = null;
    var retryDelay = 2000;
    /* DOM 行数上限跟随「每页行数」选择：超出即丢弃最旧行，保持一屏可控 */
    var maxDomRows = currentLimit();

    function currentLimit() {
        var raw = parseInt($('#log_limit').val(), 10);
        if (raw === 50 || raw === 100) {
            return raw;
        }
        return 20;
    }

    var $tableBody = $('#log_table_body');
    var $container = $('#log_container');
    var $btnPause = $('#btn_toggle_pause');
    var $iconPause = $('#icon_toggle_pause');
    var $textPause = $('#text_toggle_pause');
    var $btnClear = $('#btn_clear_logs');
    var $btnDownload = $('#btn_download_logs');
    var $chkAutoScroll = $('#chk_auto_scroll');
    var $connStatus = $('#log_conn_status');
    var $connText = $('#log_conn_text');

    function updateConnStatus(state, extra) {
        if (state === 'live') {
            $connStatus.removeClass('label-warning label-danger label-default').addClass('label-success');
            $connText.text('{{ lang._("实时") }}');
        } else if (state === 'paused') {
            $connStatus.removeClass('label-success label-danger label-warning').addClass('label-default');
            $connText.text('{{ lang._("已暂停") }}');
        } else if (state === 'error') {
            $connStatus.removeClass('label-success label-default label-warning').addClass('label-danger');
            $connText.text(extra || '{{ lang._("连接中断") }}');
        } else if (state === 'reconnecting') {
            $connStatus.removeClass('label-success label-default label-danger').addClass('label-warning');
            var delaySec = Math.round(extra / 1000);
            $connText.text('{{ lang._("重连中") }} (' + delaySec + 's)');
        }
    }

    function formatTime(isoStr) {
        if (!isoStr) {
            return '';
        }
        var d = new Date(isoStr);
        if (isNaN(d.getTime())) {
            return isoStr;
        }
        var year = d.getFullYear();
        var month = String(d.getMonth() + 1).padStart(2, '0');
        var day = String(d.getDate()).padStart(2, '0');
        var hours = String(d.getHours()).padStart(2, '0');
        var minutes = String(d.getMinutes()).padStart(2, '0');
        var seconds = String(d.getSeconds()).padStart(2, '0');
        var ms = String(d.getMilliseconds()).padStart(3, '0');
        return year + '-' + month + '-' + day + ' ' + hours + ':' + minutes + ':' + seconds + '.' + ms;
    }

    function createBadge(level) {
        var $badge = $('<span></span>').addClass('label');
        var lvl = (level || '').toLowerCase();

        if (lvl === 'debug') {
            $badge.addClass('label-default').text('调试');
        } else if (lvl === 'info') {
            $badge.addClass('label-info').text('信息');
        } else if (lvl === 'warning' || lvl === 'warn') {
            $badge.addClass('label-warning').text('警告');
        } else if (lvl === 'error' || lvl === 'fatal') {
            $badge.addClass('label-danger').text(lvl === 'fatal' ? '致命' : '错误');
        } else {
            $badge.addClass('label-default').text(lvl ? lvl.toUpperCase() : '-');
        }
        return $badge;
    }

    function appendEntry(entry) {
        var $tr = $('<tr></tr>');

        if (entry.raw !== undefined) {
            // 解析失败整行放 raw 字段
            var $tdRaw = $('<td></td>')
                .attr('colspan', '3')
                .addClass('mihomo-log-msg mihomo-mono')
                .css({
                    'white-space': 'pre-wrap',
                    'word-break': 'break-all'
                })
                .text(entry.raw);
            $tr.append($tdRaw);
        } else {
            // 结构化条目: time, level, msg
            var $tdTime = $('<td></td>')
                .addClass('mihomo-log-time mihomo-nowrap')
                .css('vertical-align', 'top')
                .text(formatTime(entry.time));

            var $tdLevel = $('<td></td>')
                .addClass('mihomo-log-level')
                .attr('data-level', entry.level ? String(entry.level).toUpperCase() : '')
                .css({
                    'text-align': 'center',
                    'vertical-align': 'top'
                })
                .append(createBadge(entry.level));

            var $tdMsg = $('<td></td>')
                .addClass('mihomo-log-msg mihomo-mono')
                .css({
                    'white-space': 'pre-wrap',
                    'word-break': 'break-all',
                    'vertical-align': 'top'
                })
                .text(entry.msg);

            $tr.append($tdTime).append($tdLevel).append($tdMsg);
        }

        $tableBody.append($tr);
    }

    function trimDomRows() {
        var rowCount = $tableBody.children('tr').length;
        if (rowCount > maxDomRows) {
            var excess = rowCount - maxDomRows;
            $tableBody.children('tr').slice(0, excess).remove();
        }
    }

    function scrollToBottom() {
        if ($chkAutoScroll.is(':checked')) {
            $container.scrollTop($container[0].scrollHeight);
        }
    }

    function schedulePoll(delay) {
        clearTimeout(pollTimer);
        if (!isPaused) {
            pollTimer = setTimeout(pollLogs, delay);
        }
    }

    function pollLogs() {
        if (isPaused) {
            return;
        }

        var level = $('#log_level_filter').val();
        var limit = currentLimit();
        maxDomRows = limit;

        ajaxCall('/api/mihomo/logs/getLogs', {
            level: level,
            limit: limit,
            cursor: currentCursor
        }, function (data, status) {
            if (isPaused) {
                return;
            }

            if (data && data.status === 'ok') {
                retryDelay = 2000;
                updateConnStatus('live');

                if (data.truncated) {
                    $tableBody.empty();
                }

                if (Array.isArray(data.entries) && data.entries.length > 0) {
                    for (var i = 0; i < data.entries.length; i++) {
                        appendEntry(data.entries[i]);
                    }
                    trimDomRows();
                    scrollToBottom();
                }

                if (data.cursor !== undefined) {
                    currentCursor = parseInt(data.cursor, 10);
                }

                schedulePoll(2000);
            } else if (data && data.status === 'failed') {
                // 服务端明确返回读取失败（如无权限读取日志）
                updateConnStatus('error', data.message || '{{ lang._("连接中断") }}');
                handlePollFailure();
            } else {
                handlePollFailure();
            }
        });
    }

    function handlePollFailure() {
        if (isPaused) {
            return;
        }
        if ($connStatus.hasClass('label-danger')) {
            // 已显示错误状态，仅更新定时重试，不覆盖状态文本
        } else {
            updateConnStatus('reconnecting', retryDelay);
        }
        schedulePoll(retryDelay);
        retryDelay = Math.min(retryDelay * 2, 10000);
    }

    // 暂停/恢复切换
    $btnPause.click(function () {
        if (isPaused) {
            isPaused = false;
            $iconPause.removeClass('fa-play').addClass('fa-pause');
            $textPause.text('{{ lang._("暂停") }}');
            updateConnStatus('live');
            retryDelay = 2000;
            pollLogs();
        } else {
            isPaused = true;
            clearTimeout(pollTimer);
            $iconPause.removeClass('fa-pause').addClass('fa-play');
            $textPause.text('{{ lang._("继续") }}');
            updateConnStatus('paused');
        }
    });

    // 清屏
    $btnClear.click(function () {
        $tableBody.empty();
    });

    // 原始日志下载（前端 Blob 下载）
    $btnDownload.click(function () {
        var lines = [];
        $tableBody.find('tr').each(function () {
            var $row = $(this);
            var $tds = $row.children('td');
            if ($tds.length === 1) {
                lines.push($tds.text());
            } else if ($tds.length === 3) {
                var t = $($tds[0]).text();
                var l = $($tds[1]).attr('data-level') || $($tds[1]).text().trim();
                var m = $($tds[2]).text();
                lines.push('[' + t + '] [' + l + '] ' + m);
            }
        });

        var blob = new Blob([lines.join('\r\n')], { type: 'text/plain;charset=utf-8' });
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = 'mihomo-' + new Date().toISOString().replace(/[:.]/g, '-') + '.log';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    });

    // 过滤条件改变：重置游标并重新拉取
    $('#log_level_filter, #log_limit').change(function () {
        currentCursor = 0;
        maxDomRows = currentLimit();
        $tableBody.empty();
        if (!isPaused) {
            clearTimeout(pollTimer);
            pollLogs();
        }
    });

    // 初次加载
    pollLogs();
});
</script>
