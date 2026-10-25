{#
 # Copyright (C) 2024-2026 Deciso B.V.
 # All rights reserved.
 #}

{{ partial('OPNsense/Mihomo/styles') }}

<div class="mihomo-page">
    <div class="mihomo-card">
        <div class="mihomo-card-head">
            <h2 class="mihomo-card-title">
                <i class="fa fa-sitemap"></i> {{ lang._('策略组') }}
            </h2>
            <div class="mihomo-toolbar" style="margin-bottom: 0;">
                <div class="checkbox" style="margin-top: 0; margin-bottom: 0; display: inline-flex; align-items: center; margin-right: 15px;">
                    <label style="margin-bottom: 0; font-weight: normal; font-size: 13px;">
                        <input type="checkbox" id="chk_include_global" style="margin-top: 2px;"> {{ lang._('显示 GLOBAL 组') }}
                    </label>
                </div>
                <div class="checkbox" style="margin-top: 0; margin-bottom: 0; display: inline-flex; align-items: center; margin-right: 15px;">
                    <label style="margin-bottom: 0; font-weight: normal; font-size: 13px;">
                        <input type="checkbox" id="chk_auto_refresh" checked style="margin-top: 2px;"> {{ lang._('自动刷新 (10s)') }}
                    </label>
                </div>
                <button class="btn btn-default btn-xs" id="btn_refresh_proxies" type="button" title="{{ lang._('手动刷新') }}">
                    <i class="fa fa-refresh"></i> {{ lang._('刷新') }}
                </button>
            </div>
        </div>

        <div class="mihomo-card-body">
            <!-- 状态信息条 -->
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; flex-wrap: wrap; gap: 10px;">
                <div style="display: flex; align-items: center; gap: 8px;">
                    <span style="font-size: 13px; color: #666666;">{{ lang._('API 状态') }}：</span>
                    <span id="proxies_api_status" class="label label-default" style="font-size: 12px; padding: 3px 8px;">
                        <i class="fa fa-spinner fa-spin"></i> {{ lang._('连接中') }}
                    </span>
                    <span style="font-size: 13px; color: #666666; margin-left: 10px;">{{ lang._('内核模式') }}：</span>
                    <span id="proxies_core_mode" class="label label-info" style="font-size: 12px; padding: 3px 8px;">-</span>
                </div>
                <div id="proxies_toast_area"></div>
            </div>

            <!-- API 不可达错误大横幅 -->
            <div id="proxies_error_banner" class="alert alert-warning" style="display: none;">
                <i class="fa fa-exclamation-triangle"></i>
                <span id="proxies_error_msg">{{ lang._('mihomo API 不可达（服务未运行或密钥未生效）') }}</span>
                <button class="btn btn-default btn-xs" id="btn_retry_conn" type="button" style="margin-left: 10px;">
                    <i class="fa fa-refresh"></i> {{ lang._('重试') }}
                </button>
            </div>

            <!-- 主内容区域：左窄右宽，右侧节点多列铺满 -->
            <div class="row mihomo-proxy-layout" id="proxies_main_content">
                <!-- 左栏：组列表 -->
                <div class="col-xs-12 col-md-3" style="margin-bottom: 15px;">
                    <ul class="mihomo-group-list" id="group_list_container">
                        <li class="mihomo-empty">{{ lang._('暂无策略组数据') }}</li>
                    </ul>
                </div>

                <!-- 右栏：节点行列表与分页 -->
                <div class="col-xs-12 col-md-9">
                    <!-- 当前组概览与操作栏 -->
                    <div style="background-color: #fafafa; border: 1px solid #e3e3e3; border-radius: 6px; padding: 12px 16px; margin-bottom: 15px;">
                        <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px;">
                            <div>
                                <h3 id="current_group_title" style="margin: 0; font-size: 16px; font-weight: 600; color: #333333; display: inline-block;">-</h3>
                                <span id="current_group_type" class="label label-primary" style="margin-left: 8px; font-size: 11px;">-</span>
                            </div>
                            <div style="font-size: 13px; color: #666666;">
                                <span>{{ lang._('当前选择') }}：</span>
                                <strong id="current_group_now" class="text-primary">-</strong>
                            </div>
                        </div>
                        <div id="current_group_note" class="text-muted" style="margin-top: 6px; font-size: 12px; display: none;"></div>
                    </div>

                    <!-- 节点搜索与分页控制 -->
                    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; flex-wrap: wrap; gap: 10px;">
                        <div style="max-width: 260px; width: 100%;">
                            <input type="text" class="form-control input-sm" id="node_search_input" placeholder="{{ lang._('在当前组搜索节点...') }}">
                        </div>
                        <div style="display: flex; align-items: center; gap: 8px;">
                            <span id="proxies_page_info" style="font-size: 12px; color: #666666;">-</span>
                            <div class="btn-group">
                                <button class="btn btn-default btn-xs" id="proxies_prev" type="button" disabled title="{{ lang._('上一页') }}">
                                    <i class="fa fa-chevron-left"></i>
                                </button>
                                <button class="btn btn-default btn-xs" id="proxies_next" type="button" disabled title="{{ lang._('下一页') }}">
                                    <i class="fa fa-chevron-right"></i>
                                </button>
                            </div>
                        </div>
                    </div>

                    <!-- 节点紧凑行列表容器 -->
                    <div class="mihomo-node-list" id="node_grid_container">
                        <div class="mihomo-empty" style="grid-column: 1 / -1;">{{ lang._('请选择左侧策略组查看节点') }}</div>
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>

<script>
$(document).ready(function () {
    var inFlight = false;
    var requestSeq = 0;
    var activeGroupName = '';
    var activeGroupSelectable = false;
    var groupsCache = [];
    var nodeSearchQuery = '';
    var nodeOffset = 0;
    var nodeLimit = 100;
    var nodeTotal = 0;
    var nodeInFlight = false;
    var isSwitchingNode = false;
    var pollTimer = null;

    function showToast(type, text) {
        var $area = $('#proxies_toast_area');
        $area.empty();
        var alertClass = (type === 'success') ? 'alert-success' : 'alert-danger';
        var iconClass = (type === 'success') ? 'fa-check' : 'fa-exclamation-circle';
        var $toast = $('<div class="alert ' + alertClass + '" style="margin-bottom: 0; padding: 4px 10px; font-size: 12px; display: inline-block;"></div>');
        $toast.append($('<i class="fa ' + iconClass + '"></i> ')).append($('<span></span>').text(text));
        $area.append($toast);
        setTimeout(function () {
            $toast.fadeOut(400, function () { $toast.remove(); });
        }, 4000);
    }

    function formatDelay(delay) {
        if (!delay || delay <= 0) {
            return { text: '-', className: '' };
        }
        var cls = 'is-good';
        if (delay > 400) {
            cls = 'is-bad';
        } else if (delay > 180) {
            cls = 'is-warn';
        }
        return { text: delay + ' ms', className: cls };
    }

    function loadGroups(isManual) {
        if (inFlight && !isManual) {
            return;
        }

        var seq = ++requestSeq;
        inFlight = true;

        var includeGlobal = $('#chk_include_global').is(':checked') ? 1 : 0;

        ajaxGet('/api/mihomo/proxies/getGroups', { include_global: includeGlobal }, function (data) {
            if (seq !== requestSeq) {
                return;
            }
            inFlight = false;

            if (!data || data.status !== 'ok' || !data.reachable) {
                $('#proxies_api_status').removeClass('label-success').addClass('label-danger').text('不可达');
                $('#proxies_error_banner').show();
                var note = (data && data.note) ? data.note : 'mihomo API 不可达（服务未运行或密钥未生效）';
                $('#proxies_error_msg').text(note);
                if (groupsCache.length === 0) {
                    $('#group_list_container').empty().append(
                        $('<li class="mihomo-empty"></li>').text('无法加载策略组数据')
                    );
                }
                return;
            }

            $('#proxies_error_banner').hide();
            $('#proxies_api_status').removeClass('label-default label-danger').addClass('label-success').text('正常');
            if (data.core_mode) {
                var coreModeNames = { 'rule': '规则分流', 'global': '全局代理', 'direct': '直连' };
                $('#proxies_core_mode').text(coreModeNames[data.core_mode] || data.core_mode);
            }

            groupsCache = Array.isArray(data.groups) ? data.groups : [];
            renderGroupList();

            // 若当前未选中组或选中组已不存在，默认选中第一项
            if (groupsCache.length > 0) {
                var found = false;
                for (var i = 0; i < groupsCache.length; i++) {
                    if (groupsCache[i].name === activeGroupName) {
                        found = true;
                        // 同步当前最新 now 值
                        $('#current_group_now').text(groupsCache[i].now || '-');
                        break;
                    }
                }
                if (!found) {
                    selectGroup(groupsCache[0].name, groupsCache[0].type, groupsCache[0].selectable, groupsCache[0].now);
                }
            } else {
                $('#group_list_container').empty().append(
                    $('<li class="mihomo-empty"></li>').text('未发现任何策略组')
                );
                $('#node_grid_container').empty().append(
                    $('<div class="mihomo-empty" style="grid-column: 1 / -1;"></div>').text('暂无可用策略组')
                );
            }
        });
    }

    function renderGroupList() {
        var $list = $('#group_list_container');
        $list.empty();

        var renderedCount = 0;
        $.each(groupsCache, function (idx, grp) {
            renderedCount++;

            var $item = $('<li class="mihomo-group-item"></li>');
            if (grp.name === activeGroupName) {
                $item.addClass('is-active');
            }

            var $head = $('<div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; gap: 8px;"></div>');
            var $title = $('<span style="font-size: 14px; font-weight: 600; color: #333333; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1 1 auto; min-width: 0;"></span>').text(grp.name);
            var $badge = $('<span class="label label-default" style="font-size: 10px; padding: 2px 5px; flex-shrink: 0;"></span>').text(grp.type);
            $head.append($title).append($badge);

            var $foot = $('<div style="display: flex; justify-content: space-between; align-items: center; font-size: 12px; color: #777777; gap: 8px;"></div>');
            var $now = $('<span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1 1 auto; min-width: 0;"></span>').text(grp.now || '-');
            var $cnt = $('<span class="badge" style="font-size: 10px; background-color: #eeeeee; color: #666666; flex-shrink: 0;"></span>').text(grp.count);
            $foot.append($now).append($cnt);

            $item.append($head).append($foot);

            $item.on('click', function () {
                if (activeGroupName !== grp.name) {
                    selectGroup(grp.name, grp.type, grp.selectable, grp.now);
                }
            });

            $list.append($item);
        });

        if (renderedCount === 0) {
            $list.append($('<li class="mihomo-empty"></li>').text('没有匹配的策略组'));
        }
    }

    function selectGroup(groupName, groupType, selectable, now) {
        activeGroupName = groupName;
        activeGroupSelectable = (selectable === true || groupType === 'Selector');
        nodeOffset = 0;
        nodeSearchQuery = '';
        $('#node_search_input').val('');

        $('#group_list_container .mihomo-group-item').removeClass('is-active');
        $('#group_list_container .mihomo-group-item').each(function () {
            var nameInItem = $(this).find('span:first').text();
            if (nameInItem === groupName) {
                $(this).addClass('is-active');
            }
        });

        $('#current_group_title').text(groupName);
        $('#current_group_type').text(groupType);
        $('#current_group_now').text(now || '-');

        if (!activeGroupSelectable) {
            $('#current_group_note').text('该策略组类型为 ' + groupType + '，由内核自动调度，不可手动切换节点。').show();
        } else {
            $('#current_group_note').text('点击任意节点可实时切换，切换仅在当前运行生效，重启后回到默认。').show();
        }

        loadNodes();
    }

    function loadNodes() {
        if (!activeGroupName || nodeInFlight) {
            return;
        }

        nodeInFlight = true;
        var $grid = $('#node_grid_container');
        $grid.css('opacity', 0.6);

        var params = {
            group: activeGroupName,
            offset: nodeOffset,
            limit: nodeLimit,
            q: nodeSearchQuery
        };

        ajaxGet('/api/mihomo/proxies/getNodes', params, function (data) {
            nodeInFlight = false;
            $grid.css('opacity', 1);

            if (!data || data.status !== 'ok' || !data.reachable) {
                var msg = (data && data.message) ? data.message : '加载节点明细失败';
                $grid.empty().append($('<div class="mihomo-empty" style="grid-column: 1 / -1;"></div>').text(msg));
                return;
            }

            if (data.group !== activeGroupName) {
                return;
            }

            nodeTotal = data.total || 0;
            updatePaginationUI();
            renderNodesGrid(data.nodes || []);
        });
    }

    function renderNodesGrid(nodes) {
        var $grid = $('#node_grid_container');
        $grid.empty();

        if (nodes.length === 0) {
            $grid.append($('<div class="mihomo-empty" style="grid-column: 1 / -1;"></div>').text('未找到匹配的节点'));
            return;
        }

        /* 紧凑行：名称（当前节点打勾） + 类型 + 延迟，多列铺满，无需滚动逐个看卡片 */
        $.each(nodes, function (idx, node) {
            var $row = $('<div class="mihomo-node"></div>');
            if (node.current) {
                $row.addClass('is-current');
            }
            if (!activeGroupSelectable) {
                $row.addClass('is-disabled');
            }

            var $name = $('<span class="mihomo-node-name"></span>').text(node.name).attr('title', node.name);
            if (node.current) {
                $name.prepend($('<i class="fa fa-check"></i>'));
                $row.attr('title', '{{ lang._("当前使用中的节点") }}');
            } else if (activeGroupSelectable) {
                $row.attr('title', '{{ lang._("点击切换到该节点") }}');
            }

            var $type = $('<span class="mihomo-node-type"></span>').text(node.type);
            var delayInfo = formatDelay(node.delay);
            var $delay = $('<span class="mihomo-delay ' + delayInfo.className + '"></span>').text(delayInfo.text);

            $row.append($name).append($type).append($delay);

            if (activeGroupSelectable && !node.current) {
                $row.on('click', function () {
                    confirmAndSelectNode(activeGroupName, node.name);
                });
            }

            $grid.append($row);
        });
    }

    function confirmAndSelectNode(group, name) {
        if (isSwitchingNode) {
            return;
        }

        BootstrapDialog.confirm({
            title: '切换节点',
            message: '确定要将策略组「' + group + '」切换至节点「' + name + '」吗？（仅当前运行生效）',
            type: BootstrapDialog.TYPE_PRIMARY,
            btnCancelLabel: '取消',
            btnOKLabel: '确认切换',
            btnOKClass: 'btn-primary',
            callback: function (result) {
                if (result) {
                    doSelectNode(group, name);
                }
            }
        });
    }

    function doSelectNode(group, name) {
        isSwitchingNode = true;
        ajaxCall('/api/mihomo/proxies/select', { group: group, name: name }, function (res) {
            isSwitchingNode = false;
            if (res && res.status === 'ok') {
                showToast('success', res.message || ('已成功切换至 ' + name));
                // 刷新组与当前组节点
                loadGroups(true);
                loadNodes();
            } else {
                var err = (res && res.message) ? res.message : '切换失败';
                showToast('failed', err);
            }
        });
    }

    function updatePaginationUI() {
        var start = (nodeTotal > 0) ? (nodeOffset + 1) : 0;
        var end = Math.min(nodeOffset + nodeLimit, nodeTotal);
        $('#proxies_page_info').text(start + ' - ' + end + ' / ' + nodeTotal);

        $('#proxies_prev').prop('disabled', nodeOffset <= 0);
        $('#proxies_next').prop('disabled', (nodeOffset + nodeLimit) >= nodeTotal);
    }

    $('#proxies_prev').on('click', function () {
        if (nodeOffset > 0) {
            nodeOffset = Math.max(0, nodeOffset - nodeLimit);
            loadNodes();
        }
    });

    $('#proxies_next').on('click', function () {
        if ((nodeOffset + nodeLimit) < nodeTotal) {
            nodeOffset += nodeLimit;
            loadNodes();
        }
    });

    $('#node_search_input').on('input', function () {
        nodeSearchQuery = $.trim($(this).val());
        nodeOffset = 0;
        loadNodes();
    });

    $('#chk_include_global').on('change', function () {
        loadGroups(true);
    });

    $('#btn_refresh_proxies').on('click', function () {
        loadGroups(true);
        loadNodes();
    });

    $('#btn_retry_conn').on('click', function () {
        loadGroups(true);
    });

    function resetPollTimer() {
        if (pollTimer) {
            clearInterval(pollTimer);
        }
        pollTimer = setInterval(function () {
            if ($('#chk_auto_refresh').is(':checked') && !document.hidden) {
                loadGroups(false);
            }
        }, 10000);
    }

    $(document).on('visibilitychange', function () {
        if (!document.hidden && $('#chk_auto_refresh').is(':checked')) {
            loadGroups(true);
        }
    });

    // 初始加载
    loadGroups(true);
    resetPollTimer();
});
</script>
