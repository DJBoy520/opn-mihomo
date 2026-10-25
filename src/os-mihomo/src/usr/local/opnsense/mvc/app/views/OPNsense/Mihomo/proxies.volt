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
            <!-- 状态信息条与工具栏 -->
            <div style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 14px;">
                <input type="text" class="form-control" id="node_search_input" placeholder="{{ lang._('搜索策略组或节点...') }}" style="max-width: 280px; height: 32px;">
                <button class="btn btn-default btn-xs" id="btn_expand_all" type="button">{{ lang._('全部展开') }}</button>
                <span class="text-muted" style="font-size: 12px;" id="proxies_count_badge">-</span>
                <span class="text-muted" style="font-size: 12px;">
                    {{ lang._('API 状态') }}：<span id="proxies_api_status" class="label label-default">{{ lang._('连接中') }}</span>
                    · {{ lang._('内核模式') }}：<span id="proxies_core_mode" class="label label-info">-</span>
                </span>
                <span class="text-muted" style="font-size: 12px; margin-left: auto;">
                    {{ lang._('点成员卡片即时切换，仅当前运行生效，重启后回到默认。') }}
                </span>
            </div>

            <div id="proxies_toast_area" style="margin-bottom: 10px;"></div>

            <!-- API 不可达错误横幅 -->
            <div id="proxies_error_banner" class="alert alert-warning" style="display: none;">
                <i class="fa fa-exclamation-triangle"></i>
                <span id="proxies_error_msg">{{ lang._('mihomo API 不可达（服务未运行或密钥未生效）') }}</span>
                <button class="btn btn-default btn-xs" id="btn_retry_conn" type="button" style="margin-left: 10px;">
                    <i class="fa fa-refresh"></i> {{ lang._('重试') }}
                </button>
            </div>

            <!-- 策略组纵向卡片列表容器 -->
            <div class="mh-glist" id="proxies_glist_container">
                <div class="mihomo-empty">{{ lang._('暂无策略组数据') }}</div>
            </div>
        </div>
    </div>
</div>

<script>
$(document).ready(function () {
    var inFlight = false;
    var requestSeq = 0;
    var groupsCache = [];
    var groupIndexMap = {};
    var OPEN = {};
    var initializedFirstOpen = false;
    var searchQuery = '';
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

    function dlClass(d) {
        if (typeof d !== 'number' || d <= 0) {
            return 'none';
        }
        if (d < 150) {
            return 'good';
        }
        if (d < 400) {
            return 'mid';
        }
        return 'bad';
    }

    function isBuiltin(g) {
        return !g || g.type === 'Direct' || g.type === 'Reject';
    }

    function buildRelations(groups) {
        groupIndexMap = {};
        $.each(groups, function (i, g) {
            groupIndexMap[g.name] = g;
        });

        $.each(groups, function (i, g) {
            g._subs = [];
            g._leaves = [];
            g._parents = [];
            var all = Array.isArray(g.all) ? g.all : [];
            $.each(all, function (j, memberName) {
                if (groupIndexMap[memberName]) {
                    g._subs.push(memberName);
                } else {
                    g._leaves.push(memberName);
                }
            });
        });

        $.each(groups, function (i, g) {
            $.each(g._subs, function (j, subName) {
                if (groupIndexMap[subName]) {
                    groupIndexMap[subName]._parents.push(g.name);
                }
            });
        });

        $.each(groups, function (i, g) {
            if (typeof g.delay === 'number') {
                g._bestDelay = g.delay;
            } else {
                var bestSubDelay = null;
                if (g._subs.length > 0 && g.now && groupIndexMap[g.now]) {
                    var subG = groupIndexMap[g.now];
                    if (typeof subG.delay === 'number') {
                        bestSubDelay = subG.delay;
                    }
                }
                g._bestDelay = bestSubDelay;
            }
        });
    }

    function isGroupHit(g, q) {
        if (!q) {
            return true;
        }
        if (g.name.toLowerCase().indexOf(q) > -1) {
            return true;
        }
        var all = Array.isArray(g.all) ? g.all : [];
        for (var i = 0; i < all.length; i++) {
            if (String(all[i]).toLowerCase().indexOf(q) > -1) {
                return true;
            }
        }
        return false;
    }

    function renderGroupCard(g) {
        var isOpen = !!OPEN[g.name];
        var isSel = (g.type === 'Selector');
        var subs = g._subs || [];
        var leaves = g._leaves || [];
        var parents = g._parents || [];
        var totalCount = g.count || (Array.isArray(g.all) ? g.all.length : 0);

        var $card = $('<div class="mh-gcard"></div>').attr('data-n', g.name);
        if (isOpen) {
            $card.addClass('is-open');
        }

        // 卡片头
        var $head = $('<div class="mh-ghead" tabindex="0"></div>');
        var $caret = $('<span class="g-caret"></span>').append($('<i class="fa"></i>').addClass(isOpen ? 'fa-chevron-down' : 'fa-chevron-right'));
        var $name = $('<span class="g-name"></span>').text(g.name).attr('title', g.name);
        var $type = $('<span class="gc-type"></span>').text(g.type || 'Unknown');
        var $cur = $('<span class="g-cur"></span>').text('{{ lang._("当前") }} ').append($('<b></b>').text(g.now || '-')).attr('title', g.now || '-');
        var $spacer = $('<span class="g-spacer"></span>');

        $head.append($caret).append($name).append($type).append($cur).append($spacer);

        if (totalCount > 0) {
            if (subs.length > 0) {
                $head.append($('<span class="g-stat"></span>').text(subs.length + ' {{ lang._("子策略") }}'));
            }
            if (leaves.length > 0) {
                $head.append($('<span class="g-stat"></span>').text(leaves.length + ' {{ lang._("节点") }}'));
            }
            if (typeof g._bestDelay === 'number') {
                var $best = $('<span class="g-stat"></span>').text('{{ lang._("最优") }} ');
                $best.append($('<b></b>').addClass(dlClass(g._bestDelay)).text(g._bestDelay + 'ms'));
                $head.append($best);
            }
            if (typeof g._bestDelay === 'number') {
                var $bars = $('<span class="gc-bars"></span>');
                var bClass = dlClass(g._bestDelay);
                $bars.append($('<i style="height: 6px;"></i>').addClass(bClass === 'mid' ? 'mid' : (bClass === 'bad' ? 'bad' : '')));
                $bars.append($('<i style="height: 10px;"></i>').addClass(bClass === 'mid' ? 'mid' : (bClass === 'bad' ? 'bad' : '')));
                $bars.append($('<i style="height: 14px;"></i>').addClass(bClass === 'mid' ? 'mid' : (bClass === 'bad' ? 'bad' : '')));
                $head.append($bars);
            }
        } else {
            $head.append($('<span class="g-stat"></span>').text('{{ lang._("内置出口") }}'));
        }

        if (parents.length > 0) {
            var $ref = $('<span class="g-ref"></span>').append($('<span class="lb">{{ lang._("被引用") }}</span>'));
            var showP = parents.slice(0, 2);
            $.each(showP, function (idx, pName) {
                var $up = $('<span class="up" data-jump="1"></span>').text(pName).attr('data-target-group', pName);
                $ref.append($up);
            });
            if (parents.length > 2) {
                $ref.append($('<span class="more"></span>').text('+' + (parents.length - 2)));
            }
            $head.append($ref);
        }

        var $cntBadge = $('<span class="cnt-badge"></span>').text(totalCount);
        $head.append($cntBadge);
        $card.append($head);

        // 卡片展开体
        if (isOpen) {
            var $body = $('<div class="mh-gbody"></div>');

            // 1. 子策略
            if (subs.length > 0) {
                $body.append($('<div class="gc-sub-h"></div>').text('{{ lang._("子策略") }} (' + subs.length + ')'));
                var $subGrid = $('<div class="mh-mb-grid"></div>');
                $.each(subs, function (idx, subName) {
                    var subG = groupIndexMap[subName] || {};
                    var isCur = (subName === g.now);
                    var $mb = $('<div class="mh-mb is-group"></div>').attr('data-jump', '1').attr('data-target-group', subName);
                    if (isCur) {
                        $mb.addClass('is-current');
                    }
                    var $mbBody = $('<div class="mb-body"></div>');
                    $mbBody.append($('<div class="mb-nm"></div>').text(subName).attr('title', subName));

                    var $mbSub = $('<div class="mb-sub"></div>');
                    if (subG.now) {
                        $mbSub.append($('<span class="mb-cur"></span>').text(subG.now).attr('title', subG.now));
                    }
                    $mbSub.append($('<span class="ty"></span>').text(subG.type || 'Group'));
                    if (subG.udpr) {
                        $mbSub.append($('<span class="ty">UDP</span>'));
                    }
                    var subCount = subG.count || (Array.isArray(subG.all) ? subG.all.length : 0);
                    if (subCount > 0) {
                        $mbSub.append($('<span class="cnt"></span>').text(subCount + ' {{ lang._("成员") }}'));
                    }
                    $mbBody.append($mbSub);

                    var $mbR = $('<div class="mb-r"></div>');
                    if (isCur) {
                        $mbR.addClass('ok').append($('<i class="fa fa-check"></i>'));
                    } else if (typeof subG.delay === 'number') {
                        $mbR.addClass(dlClass(subG.delay)).text(subG.delay + 'ms');
                    } else {
                        $mbR.addClass('none').text('—');
                    }

                    $mb.append($mbBody).append($mbR);
                    $subGrid.append($mb);
                });
                $body.append($subGrid);
            }

            // 2. 实际节点
            if (leaves.length > 0) {
                var maxRender = 200;
                var displayLeaves = leaves;
                var isTruncated = false;
                if (!searchQuery && leaves.length > maxRender) {
                    displayLeaves = leaves.slice(0, maxRender);
                    isTruncated = true;
                }

                var $leafH = $('<div class="gc-sub-h"></div>').text('{{ lang._("实际节点") }} (' + leaves.length + ')');
                $body.append($leafH);

                var $nodeGrid = $('<div class="mh-mb-grid"></div>');
                $.each(displayLeaves, function (idx, nodeName) {
                    var isCur = (nodeName === g.now);
                    var $mb = $('<div class="mh-mb"></div>').attr('data-sel', '1').attr('data-node-name', nodeName).attr('data-group-name', g.name);
                    if (isCur) {
                        $mb.addClass('is-current');
                    }
                    var $mbBody = $('<div class="mb-body"></div>');
                    $mbBody.append($('<div class="mb-nm"></div>').text(nodeName).attr('title', nodeName));

                    var $mbSub = $('<div class="mb-sub"></div>');
                    $mbSub.append($('<span class="ty">Node</span>'));
                    $mbBody.append($mbSub);

                    var $mbR = $('<div class="mb-r"></div>');
                    if (isCur) {
                        $mbR.addClass('ok').append($('<i class="fa fa-check"></i>'));
                    } else {
                        $mbR.addClass('none').text('—');
                    }

                    $mb.append($mbBody).append($mbR);
                    $nodeGrid.append($mb);
                });
                $body.append($nodeGrid);

                if (isTruncated) {
                    $body.append($('<div class="text-muted" style="font-size: 12px; margin-top: 6px;"></div>').text('{{ lang._("仅显示前 200 项，请用搜索缩小范围") }}'));
                }
            }

            if (totalCount === 0) {
                $body.append($('<div class="gc-empty"></div>').text('{{ lang._("mihomo 内置出口，无成员，被引用时直接生效。") }}'));
            }

            $card.append($body);
        }

        return $card;
    }

    function renderAllCards() {
        var $container = $('#proxies_glist_container');
        var savedScrollY = window.scrollY;

        var q = searchQuery.toLowerCase();
        var matchedGroups = [];
        $.each(groupsCache, function (i, g) {
            if (isGroupHit(g, q)) {
                matchedGroups.push(g);
                if (q) {
                    OPEN[g.name] = true;
                }
            }
        });

        $container.empty();

        if (matchedGroups.length === 0) {
            $container.append($('<div class="gc-empty" style="padding: 16px;"></div>').text('{{ lang._("没有匹配的策略组。") }}'));
        } else {
            $.each(matchedGroups, function (i, g) {
                $container.append(renderGroupCard(g));
            });
        }

        var total = groupsCache.length;
        var shown = matchedGroups.length;
        $('#proxies_count_badge').text('{{ lang._("显示") }} ' + shown + ' / ' + total + ' {{ lang._("个") }}');

        var allExpanded = (total > 0);
        $.each(groupsCache, function (i, g) {
            if (!OPEN[g.name]) {
                allExpanded = false;
                return false;
            }
        });
        $('#btn_expand_all').text(allExpanded ? '{{ lang._("全部收起") }}' : '{{ lang._("全部展开") }}');

        window.scrollTo(0, savedScrollY);
    }

    function jumpToGroup(groupName) {
        OPEN[groupName] = true;
        renderAllCards();
        var $el = $('#proxies_glist_container .mh-gcard[data-n="' + CSS.escape(groupName) + '"]');
        if ($el.length > 0) {
            $el[0].scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
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
                $('#proxies_api_status').removeClass('label-success').addClass('label-danger').text('{{ lang._("不可达") }}');
                $('#proxies_error_banner').show();
                var note = (data && data.note) ? data.note : '{{ lang._("mihomo API 不可达（服务未运行或密钥未生效）") }}';
                $('#proxies_error_msg').text(note);
                if (groupsCache.length === 0) {
                    $('#proxies_glist_container').empty().append(
                        $('<div class="mihomo-empty"></div>').text('{{ lang._("无法加载策略组数据") }}')
                    );
                }
                return;
            }

            $('#proxies_error_banner').hide();
            $('#proxies_api_status').removeClass('label-default label-danger').addClass('label-success').text('{{ lang._("正常") }}');
            if (data.core_mode) {
                var coreModeNames = { 'rule': '{{ lang._("规则分流") }}', 'global': '{{ lang._("全局代理") }}', 'direct': '{{ lang._("直连") }}' };
                $('#proxies_core_mode').text(coreModeNames[data.core_mode] || data.core_mode);
            }

            groupsCache = Array.isArray(data.groups) ? data.groups : [];
            buildRelations(groupsCache);

            if (!initializedFirstOpen && groupsCache.length > 0) {
                OPEN[groupsCache[0].name] = true;
                initializedFirstOpen = true;
            }

            renderAllCards();
        });
    }

    function confirmAndSelectNode(group, name) {
        if (isSwitchingNode) {
            return;
        }

        BootstrapDialog.confirm({
            title: '{{ lang._("切换节点") }}',
            message: '{{ lang._("确定要将策略组「") }}' + group + '{{ lang._("」切换至节点「") }}' + name + '{{ lang._("」吗？（仅当前运行生效）") }}',
            type: BootstrapDialog.TYPE_PRIMARY,
            btnCancelLabel: '{{ lang._("取消") }}',
            btnOKLabel: '{{ lang._("确认切换") }}',
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
                showToast('success', res.message || ('{{ lang._("已成功切换至 ") }}' + name));
                loadGroups(true);
            } else {
                var err = (res && res.message) ? res.message : '{{ lang._("切换失败") }}';
                showToast('failed', err);
            }
        });
    }

    // 容器委托事件
    $('#proxies_glist_container').on('click', function (e) {
        var $jump = $(e.target).closest('[data-jump="1"]');
        if ($jump.length > 0) {
            e.stopPropagation();
            var targetGroup = $jump.attr('data-target-group');
            if (targetGroup) {
                jumpToGroup(targetGroup);
            }
            return;
        }

        var $sel = $(e.target).closest('[data-sel="1"]');
        if ($sel.length > 0) {
            e.stopPropagation();
            var gName = $sel.attr('data-group-name');
            var nName = $sel.attr('data-node-name');
            var grp = groupIndexMap[gName];
            if (grp && (grp.selectable || grp.type === 'Selector')) {
                if (grp.now !== nName) {
                    confirmAndSelectNode(gName, nName);
                }
            }
            return;
        }

        var $head = $(e.target).closest('.mh-ghead');
        if ($head.length > 0) {
            var $card = $head.closest('.mh-gcard');
            var name = $card.attr('data-n');
            if (name) {
                OPEN[name] = !OPEN[name];
                renderAllCards();
            }
        }
    });

    $('#proxies_glist_container').on('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') {
            var $head = $(e.target).closest('.mh-ghead');
            if ($head.length > 0) {
                e.preventDefault();
                var $card = $head.closest('.mh-gcard');
                var name = $card.attr('data-n');
                if (name) {
                    OPEN[name] = !OPEN[name];
                    renderAllCards();
                }
            }
        }
    });

    $('#btn_expand_all').on('click', function () {
        var anyCollapsed = false;
        $.each(groupsCache, function (i, g) {
            if (!OPEN[g.name]) {
                anyCollapsed = true;
                return false;
            }
        });
        $.each(groupsCache, function (i, g) {
            OPEN[g.name] = anyCollapsed;
        });
        renderAllCards();
    });

    $('#node_search_input').on('input', function () {
        searchQuery = $.trim($(this).val());
        renderAllCards();
    });

    $('#chk_include_global').on('change', function () {
        loadGroups(true);
    });

    $('#btn_refresh_proxies').on('click', function () {
        loadGroups(true);
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
