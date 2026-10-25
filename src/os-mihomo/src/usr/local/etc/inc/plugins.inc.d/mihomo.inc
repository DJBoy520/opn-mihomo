<?php

/*
 * Copyright (C) 2024  https://pfchina.org/
 * All rights reserved.
 *
 */

function mihomo_services()
{
    global $config;

    $services = array();

        $services[] = array(
            'description' => gettext('mihomo'),
            'configd' => array(
                'restart' => array('mihomo restart'),
                'start' => array('mihomo start'),
                'stop' => array('mihomo stop'),
            ),
            'name' => 'mihomo',
            'pidfile' => '/var/run/mihomo.pid',
        );


    return $services;
}

function mihomo_configure()
{
    return [
        'newwanip' => ['mihomo_restart'],
    ];
}

function mihomo_syslog()
{
    $logfacilities = array();
    $logfacilities['mihomo'] = array(
        'facility' => array('mihomo'),
    );
    return $logfacilities;
}


function mihomo_restart()
{
    exec('/usr/local/sbin/configctl mihomo restart');
}

/**
 * 注册 mihomo-transport PF anchor
 *
 * anchor 由 filter reload 自动重建引用，规则内容由 transport_manager.sh 装载。
 *
 * @param \OPNsense\Firewall\FilterRule $fw
 * @return array
 */
function mihomo_firewall($fw)
{
    if (!@file_exists('/usr/local/etc/mihomo/pf-transport.conf')) {
        return array();
    }

    $mode = 'proxy';
    $cfg = \OPNsense\Core\Config::getInstance()->object();
    if (isset($cfg->OPNsense->mihomo->general->transport_mode)) {
        $mode = (string)$cfg->OPNsense->mihomo->general->transport_mode;
    }

    if ($mode === 'transparent') {
        $fw->registerAnchor('mihomo-transport', 'fw', 0, 'head', true);
    }

    return array();
}

