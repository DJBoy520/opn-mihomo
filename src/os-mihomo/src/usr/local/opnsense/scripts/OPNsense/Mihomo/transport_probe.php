#!/usr/local/bin/php
<?php

/**
 * transport_probe.php - 透明链路端到端 SOCKS5 数据面探针（fixB）
 *
 * 背景：transport-status 的组件级检查（mode/anchor/hev PID/tun0）在 ACL/鉴权
 * 把回环链路掐断时依然全绿。hev 与 LAN 客户端共用 127.0.0.1:socks-port 入口，
 * 这里做一次真实 SOCKS5 CONNECT：方法协商 → （可选）用户名密码子协商 → CONNECT。
 * 探针通过即代表 ACL/鉴权/mihomo 核心数据面全通；任何一层损坏都能被发现。
 *
 * 输出单行："SOCKS probe: ok|failed|skipped ..."，由 transport_manager.sh
 * status 附加显示；本脚本自身永远 exit 0（状态查询不因探针失败而报错）。
 * 探针目标可用 MIHOMO_PROBE_HOST / MIHOMO_PROBE_PORT 覆盖，默认 1.1.1.1:53。
 */

$confFile = '/usr/local/etc/mihomo/config.yaml';
$probeHost = getenv('MIHOMO_PROBE_HOST') ?: '1.1.1.1';
$probePort = (int)(getenv('MIHOMO_PROBE_PORT') ?: '53');
$port = 7891;
$user = null;
$pass = null;

function probe_fail(string $why): void
{
    echo "SOCKS probe: failed ({$why})\n";
    exit(0);
}

$lines = @file($confFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
if ($lines === false) {
    probe_fail('config unreadable');
}

$inAuth = false;
foreach ($lines as $line) {
    if (preg_match('/^socks-port:\s*(\d+)\s*(?:#.*)?$/', $line, $m)) {
        $port = (int)$m[1];
    }
    if (preg_match('/^authentication:\s*\[\s*\]\s*(?:#.*)?$/', $line)) {
        $inAuth = false;
        continue;
    }
    if (preg_match('/^authentication:\s*(.*)$/', $line, $m)) {
        $val = trim($m[1]);
        if ($val === '[]') {
            $inAuth = false;
            continue;
        }
        // 空值键行 = 块式鉴权列表开始，后续缩进行为条目
        $inAuth = true;
        continue;
    }
    if ($inAuth) {
        if ($line[0] !== ' ' && $line[0] !== "\t" && $line[0] !== '-' && $line[0] !== '#') {
            $inAuth = false;
        } elseif (preg_match('/^\s*-\s*(.+?)\s*(?:#.*)?$/', $line, $m)) {
            $pair = trim($m[1]);
            $pair = preg_replace('/^"(.*)"$/', '$1', $pair);
            $pair = preg_replace("/^'(.*)'$/", '$1', $pair);
            $idx = strpos((string)$pair, ':');
            if ($idx !== false && $idx > 0) {
                $user = substr((string)$pair, 0, $idx);
                $pass = substr((string)$pair, $idx + 1);
                $inAuth = false;
            }
        }
    }
}

if ($port <= 0) {
    echo "SOCKS probe: skipped (socks-port disabled)\n";
    exit(0);
}

$ip = ip2long($probeHost);
if ($ip === false) {
    probe_fail('bad probe host');
}

$fp = @fsockopen('127.0.0.1', $port, $errno, $errstr, 3);
if ($fp === false) {
    probe_fail('connect: ' . $errstr);
}
stream_set_timeout($fp, 5);

// greeting：mihomo 配置了 authentication 时首选用户名密码法
fwrite($fp, "\x05\x01" . ($user !== null ? "\x02" : "\x00"));
$resp = (string)fread($fp, 2);
if (strlen($resp) < 2 || ord($resp[0]) !== 0x05) {
    fclose($fp);
    probe_fail('greeting');
}
$method = ord($resp[1]);
if ($method === 0x02) {
    if ($user === null) {
        fclose($fp);
        probe_fail('auth required, no credentials');
    }
    fwrite($fp, "\x01" . chr(strlen($user)) . $user . chr(strlen($pass)) . $pass);
    $resp = (string)fread($fp, 2);
    if (strlen($resp) < 2 || ord($resp[1]) !== 0x00) {
        fclose($fp);
        probe_fail('auth rejected');
    }
} elseif ($method !== 0x00) {
    fclose($fp);
    probe_fail('method 0x' . dechex($method));
}

// CONNECT ATYP=1(IPv4) 到探针目标
$req = "\x05\x01\x00\x01" . pack('N', $ip) . pack('n', $probePort);
fwrite($fp, $req);
$resp = (string)fread($fp, 10);
fclose($fp);
if (strlen($resp) < 4 || ord($resp[1]) !== 0x00) {
    probe_fail('connect rejected');
}

echo "SOCKS probe: ok ({$probeHost}:{$probePort})\n";
exit(0);
