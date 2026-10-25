<?php

/*
 * Copyright (C) 2024-2026 Deciso B.V.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 * OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

namespace OPNsense\Mihomo\Api;

use OPNsense\Base\ApiControllerBase;

class ProxiesController extends ApiControllerBase
{
    private const CONFIG_FILE = '/usr/local/etc/mihomo/config.yaml';
    private const MAX_CONFIG_READ_BYTES = 262144; // 256KB
    private const MAX_PROXIES_RESPONSE_BYTES = 4194304; // 4MiB
    private const MAX_GROUPS_LIMIT = 200;

    /**
     * 流式读取 config.yaml，提取 external-controller 与 secret
     * 累计最多读取 256KB，命中或超限立即退出，严禁整文件一次性载入
     */
    private function readConfigInfo(): array
    {
        $info = [
            'addr' => null,
            'secret' => '',
            'mode' => 'rule',
        ];

        if (!is_file(self::CONFIG_FILE) || !is_readable(self::CONFIG_FILE)) {
            return $info;
        }

        $handle = @fopen(self::CONFIG_FILE, 'r');
        if ($handle === false) {
            return $info;
        }

        $bytesRead = 0;
        $foundAddr = false;
        $foundSecret = false;
        $foundMode = false;

        while (($line = fgets($handle, 4096)) !== false) {
            $bytesRead += strlen($line);

            if (!$foundAddr && preg_match('/^external-controller:\s*(.*)$/', $line, $matches)) {
                $raw = trim($matches[1]);
                $comment = strpos($raw, ' #');
                if ($comment !== false) {
                    $raw = rtrim(substr($raw, 0, $comment));
                }
                $val = trim($raw, " \t\n\r\0\x0B\"'");
                $parts = explode(':', $val);
                if (count($parts) === 2) {
                    $h = $parts[0];
                    $p = $parts[1];
                    if (filter_var($h, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false && ctype_digit($p)) {
                        $pInt = (int)$p;
                        if ($pInt >= 1 && $pInt <= 65535) {
                            if ($h === '0.0.0.0') {
                                $h = '127.0.0.1';
                            }
                            $info['addr'] = ['host' => $h, 'port' => $pInt];
                            $foundAddr = true;
                        }
                    }
                }
            }

            if (!$foundSecret && preg_match('/^secret:[[:space:]]*(.*)$/', $line, $matches)) {
                $raw = trim($matches[1]);
                if ($raw !== '') {
                    if (preg_match('/^(["\'])(.*)\1\s*(?:#.*)?$/', $raw, $qMatches)) {
                        $info['secret'] = trim($qMatches[2]);
                    } else {
                        $commentPos = strpos($raw, ' #');
                        if ($commentPos !== false) {
                            $raw = substr($raw, 0, $commentPos);
                        }
                        $info['secret'] = trim($raw, " \t\n\r\0\x0B\"'");
                    }
                }
                $foundSecret = true;
            }

            if (!$foundMode && preg_match('/^mode:[[:space:]]*(\S+)/', $line, $matches)) {
                $m = strtolower(trim($matches[1], " \t\n\r\0\x0B\"'"));
                if (in_array($m, ['rule', 'global', 'direct'], true)) {
                    $info['mode'] = $m;
                }
                $foundMode = true;
            }

            if (($foundAddr && $foundSecret && $foundMode) || $bytesRead >= self::MAX_CONFIG_READ_BYTES) {
                break;
            }
        }

        fclose($handle);
        return $info;
    }

    /**
     * 安全执行 curl 请求，secret 写入 0600 临时配置文件（-K），并通过 try/finally 清理
     * 支持 -m 5 (读) 与 -m 6 (PUT 切换) 等超时控制
     */
    private function execCurl(string $method, string $url, ?string $body = null, int $timeout = 5): array
    {
        $configInfo = $this->readConfigInfo();
        $secret = $configInfo['secret'];

        $cfgFile = null;
        try {
            $cmd = '/usr/local/bin/curl -s';
            if ($timeout > 0) {
                $cmd .= ' -m ' . (int)$timeout;
            }
            $cmd .= ' --connect-timeout 2';

            if ($method !== 'GET') {
                $cmd .= ' -X ' . escapeshellarg($method);
            }

            if ($secret !== '') {
                $cfgFile = tempnam(sys_get_temp_dir(), 'mihomo-curl-');
                if ($cfgFile !== false) {
                    chmod($cfgFile, 0600);
                    $cfgContent = 'header = "Authorization: Bearer ' . str_replace(['\\', '"'], ['\\\\', '\\"'], $secret) . "\"\n";
                    if (file_put_contents($cfgFile, $cfgContent) !== false) {
                        $cmd .= ' -K ' . escapeshellarg($cfgFile);
                    } else {
                        @unlink($cfgFile);
                        $cfgFile = null;
                    }
                }
            }

            if ($body !== null) {
                $cmd .= ' -H ' . escapeshellarg('Content-Type: application/json');
                $cmd .= ' -d ' . escapeshellarg($body);
            }

            $cmd .= ' -w ' . escapeshellarg("\n%{http_code}") . ' ' . escapeshellarg($url) . ' 2>/dev/null';

            $rawOutput = shell_exec($cmd);

            if (!is_string($rawOutput) || $rawOutput === '') {
                return ['ok' => false, 'code' => 0, 'body' => '', 'error' => '无输出或命令执行失败'];
            }

            $lastNewline = strrpos($rawOutput, "\n");
            if ($lastNewline === false) {
                return ['ok' => false, 'code' => 0, 'body' => '', 'error' => '输出格式异常'];
            }

            $codeStr = trim(substr($rawOutput, $lastNewline + 1));
            $bodyStr = substr($rawOutput, 0, $lastNewline);
            $httpCode = ctype_digit($codeStr) ? (int)$codeStr : 0;

            return [
                'ok' => true,
                'code' => $httpCode,
                'body' => $bodyStr,
                'error' => '',
            ];
        } finally {
            if ($cfgFile !== null && file_exists($cfgFile)) {
                @unlink($cfgFile);
            }
        }
    }

    /**
     * 获取轻量级代理组列表（GET /api/mihomo/proxies/getGroups）
     * 可选参数 include_global=1
     */
    public function getGroupsAction()
    {
        $includeGlobal = ($this->request->get('include_global', 'int', 0) === 1);

        $configInfo = $this->readConfigInfo();
        $addr = $configInfo['addr'];
        $coreMode = $configInfo['mode'];

        if ($addr === null) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'groups' => [],
                'core_mode' => $coreMode,
                'updated' => time(),
                'note' => 'mihomo API 不可达',
            ];
        }

        $url = 'http://' . $addr['host'] . ':' . $addr['port'] . '/proxies';
        $res = $this->execCurl('GET', $url, null, 5);

        if (!$res['ok'] || $res['code'] !== 200) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'groups' => [],
                'core_mode' => $coreMode,
                'updated' => time(),
                'note' => 'mihomo API 不可达',
            ];
        }

        $rawBody = $res['body'];
        if (strlen($rawBody) > self::MAX_PROXIES_RESPONSE_BYTES) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'groups' => [],
                'core_mode' => $coreMode,
                'updated' => time(),
                'note' => '响应过大',
            ];
        }

        $data = json_decode($rawBody, true);
        if (!is_array($data) || !isset($data['proxies']) || !is_array($data['proxies'])) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'groups' => [],
                'core_mode' => $coreMode,
                'updated' => time(),
                'note' => '解析响应失败',
            ];
        }

        $groups = [];
        $truncated = false;

        foreach ($data['proxies'] as $name => $item) {
            if (!is_array($item)) {
                continue;
            }

            $type = isset($item['type']) ? (string)$item['type'] : '';
            // 组对象必须具备 all 数组
            if (!isset($item['all']) || !is_array($item['all'])) {
                continue;
            }

            // 默认跳过 GLOBAL
            if (!$includeGlobal && $name === 'GLOBAL') {
                continue;
            }

            if (count($groups) >= self::MAX_GROUPS_LIMIT) {
                $truncated = true;
                break;
            }

            $now = isset($item['now']) ? (string)$item['now'] : '';
            $selectable = ($type === 'Selector');
            $count = count($item['all']);

            // 严格白名单：只输出 name, type, now, count, selectable
            $groups[] = [
                'name' => (string)$name,
                'type' => $type,
                'now' => $now,
                'count' => $count,
                'selectable' => $selectable,
            ];
        }

        $result = [
            'status' => 'ok',
            'reachable' => true,
            'core_mode' => $coreMode,
            'updated' => time(),
            'groups' => $groups,
            'note' => '',
        ];

        if ($truncated) {
            $result['truncated'] = true;
        }

        return $result;
    }

    /**
     * 按需、分页、搜索获取指定组的节点明细（GET /api/mihomo/proxies/getNodes）
     * 参数：group（必填）、q（可选，<=200）、offset（>=0）、limit（1~500，默认 100）
     */
    public function getNodesAction()
    {
        $rawGroup = $this->request->get('group', 'string', null);
        if ($rawGroup === null || !is_scalar($rawGroup) || trim((string)$rawGroup) === '') {
            return ['status' => 'failed', 'message' => '必须指定策略组名称'];
        }
        $targetGroup = (string)$rawGroup;

        $rawLimit = $this->request->get('limit', 'int', 100);
        $limit = ($rawLimit !== null && (int)$rawLimit >= 1) ? min(500, (int)$rawLimit) : 100;

        $rawOffset = $this->request->get('offset', 'int', 0);
        $offset = ($rawOffset !== null && (int)$rawOffset >= 0) ? (int)$rawOffset : 0;

        $rawQ = $this->request->get('q', 'string', '');
        $q = '';
        if ($rawQ !== null && is_scalar($rawQ)) {
            $sanitized = preg_replace('/[\x00-\x1F\x7F]/u', '', (string)$rawQ);
            $q = mb_substr(trim($sanitized), 0, 200, 'UTF-8');
        }

        $configInfo = $this->readConfigInfo();
        $addr = $configInfo['addr'];

        if ($addr === null) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'group' => $targetGroup,
                'type' => '',
                'now' => '',
                'selectable' => false,
                'nodes' => [],
                'total' => 0,
                'offset' => $offset,
                'limit' => $limit,
                'truncated' => false,
                'query' => $q,
                'note' => 'mihomo API 不可达',
            ];
        }

        $url = 'http://' . $addr['host'] . ':' . $addr['port'] . '/proxies';
        $res = $this->execCurl('GET', $url, null, 5);

        if (!$res['ok'] || $res['code'] !== 200) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'group' => $targetGroup,
                'type' => '',
                'now' => '',
                'selectable' => false,
                'nodes' => [],
                'total' => 0,
                'offset' => $offset,
                'limit' => $limit,
                'truncated' => false,
                'query' => $q,
                'note' => 'mihomo API 不可达',
            ];
        }

        $rawBody = $res['body'];
        if (strlen($rawBody) > self::MAX_PROXIES_RESPONSE_BYTES) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'group' => $targetGroup,
                'type' => '',
                'now' => '',
                'selectable' => false,
                'nodes' => [],
                'total' => 0,
                'offset' => $offset,
                'limit' => $limit,
                'truncated' => false,
                'query' => $q,
                'note' => '响应过大',
            ];
        }

        $data = json_decode($rawBody, true);
        if (!is_array($data) || !isset($data['proxies']) || !is_array($data['proxies'])) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'group' => $targetGroup,
                'type' => '',
                'now' => '',
                'selectable' => false,
                'nodes' => [],
                'total' => 0,
                'offset' => $offset,
                'limit' => $limit,
                'truncated' => false,
                'query' => $q,
                'note' => '解析响应失败',
            ];
        }

        $allProxies = $data['proxies'];
        if (!isset($allProxies[$targetGroup]) || !is_array($allProxies[$targetGroup])) {
            return ['status' => 'failed', 'message' => '策略组不存在'];
        }

        $groupObj = $allProxies[$targetGroup];
        if (!isset($groupObj['all']) || !is_array($groupObj['all'])) {
            return ['status' => 'failed', 'message' => '指定目标不是策略组'];
        }

        $groupType = isset($groupObj['type']) ? (string)$groupObj['type'] : '';
        $groupNow = isset($groupObj['now']) ? (string)$groupObj['now'] : '';
        $selectable = ($groupType === 'Selector');
        $allNodeNames = $groupObj['all'];

        $hasQ = ($q !== '');
        $qLower = mb_strtolower($q, 'UTF-8');

        $filteredNodeNames = [];
        foreach ($allNodeNames as $nodeName) {
            $nodeNameStr = (string)$nodeName;
            if ($hasQ) {
                if (mb_stripos($nodeNameStr, $qLower, 0, 'UTF-8') === false) {
                    continue;
                }
            }
            $filteredNodeNames[] = $nodeNameStr;
        }

        $total = count($filteredNodeNames);
        $slice = array_slice($filteredNodeNames, $offset, $limit);
        $truncated = (($offset + count($slice)) < $total);

        $nodes = [];
        foreach ($slice as $nName) {
            $nodeInfo = isset($allProxies[$nName]) && is_array($allProxies[$nName]) ? $allProxies[$nName] : [];
            $nType = isset($nodeInfo['type']) ? (string)$nodeInfo['type'] : 'Unknown';
            $isCurrent = ($nName === $groupNow);

            $delay = 0;
            if (isset($nodeInfo['history']) && is_array($nodeInfo['history']) && !empty($nodeInfo['history'])) {
                $lastHistory = end($nodeInfo['history']);
                if (is_array($lastHistory) && isset($lastHistory['delay']) && is_numeric($lastHistory['delay'])) {
                    $delay = (int)$lastHistory['delay'];
                }
            }

            // 严格白名单：只输出 name, type, current, delay
            $nodes[] = [
                'name' => $nName,
                'type' => $nType,
                'current' => $isCurrent,
                'delay' => $delay,
            ];
        }

        return [
            'status' => 'ok',
            'reachable' => true,
            'group' => $targetGroup,
            'type' => $groupType,
            'now' => $groupNow,
            'selectable' => $selectable,
            'nodes' => $nodes,
            'total' => $total,
            'offset' => $offset,
            'limit' => $limit,
            'truncated' => $truncated,
            'query' => $q,
        ];
    }

    /**
     * 实时切换策略组节点（POST /api/mihomo/proxies/select）
     * 参数：group（<=128字符）、name（<=128字符）
     */
    public function selectAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => '仅支持 POST 请求'];
        }

        $rawGroup = $this->request->getPost('group', 'string', null);
        $rawName = $this->request->getPost('name', 'string', null);

        if ($rawGroup === null || !is_scalar($rawGroup) || trim((string)$rawGroup) === '') {
            return ['status' => 'failed', 'message' => '参数 group 无效'];
        }
        if ($rawName === null || !is_scalar($rawName) || trim((string)$rawName) === '') {
            return ['status' => 'failed', 'message' => '参数 name 无效'];
        }

        $group = trim((string)$rawGroup);
        $name = trim((string)$rawName);

        if (mb_strlen($group, 'UTF-8') > 128 || preg_match('/[\x00-\x1F\x7F]/u', $group)) {
            return ['status' => 'failed', 'message' => '策略组名称超长或包含控制字符'];
        }
        if (mb_strlen($name, 'UTF-8') > 128 || preg_match('/[\x00-\x1F\x7F]/u', $name)) {
            return ['status' => 'failed', 'message' => '节点名称超长或包含控制字符'];
        }

        $configInfo = $this->readConfigInfo();
        $addr = $configInfo['addr'];

        if ($addr === null) {
            return ['status' => 'failed', 'message' => 'mihomo API 不可达'];
        }

        // 1. 实时读取 /proxies 做精确校验
        $proxiesUrl = 'http://' . $addr['host'] . ':' . $addr['port'] . '/proxies';
        $getRes = $this->execCurl('GET', $proxiesUrl, null, 5);

        if (!$getRes['ok'] || $getRes['code'] !== 200) {
            return ['status' => 'failed', 'message' => '无法读取当前策略组状态（API 不可达）'];
        }

        $data = json_decode($getRes['body'], true);
        if (!is_array($data) || !isset($data['proxies']) || !is_array($data['proxies'])) {
            return ['status' => 'failed', 'message' => '解析策略组状态失败'];
        }

        $allProxies = $data['proxies'];
        if (!isset($allProxies[$group]) || !is_array($allProxies[$group])) {
            return ['status' => 'failed', 'message' => '指定的策略组不存在'];
        }

        $groupObj = $allProxies[$group];
        $type = isset($groupObj['type']) ? (string)$groupObj['type'] : '';
        if ($type !== 'Selector') {
            return ['status' => 'failed', 'message' => '该策略组类型为 ' . $type . '，不可手动切换'];
        }

        $allNodes = isset($groupObj['all']) && is_array($groupObj['all']) ? $groupObj['all'] : [];
        if (!in_array($name, $allNodes, true)) {
            return ['status' => 'failed', 'message' => '所选节点不属于该策略组'];
        }

        // 2. 执行 PUT /proxies/{rawurlencode(group)} body {"name":"<name>"}
        $putUrl = 'http://' . $addr['host'] . ':' . $addr['port'] . '/proxies/' . rawurlencode($group);
        $body = json_encode(['name' => $name], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);

        $putRes = $this->execCurl('PUT', $putUrl, $body, 6);

        if (!$putRes['ok']) {
            return ['status' => 'failed', 'message' => '切换请求失败: ' . $putRes['error']];
        }

        // 成功判据：200 或 204
        if ($putRes['code'] === 200 || $putRes['code'] === 204) {
            return [
                'status' => 'ok',
                'message' => '已成功切换至 ' . $name,
            ];
        }

        // 失败：读取并截断响应体
        $errBody = trim($putRes['body']);
        if ($errBody === '') {
            $errBody = 'HTTP ' . $putRes['code'];
        } else {
            $errBody = mb_substr($errBody, 0, 200, 'UTF-8');
        }

        return [
            'status' => 'failed',
            'message' => '切换失败: ' . $errBody,
        ];
    }
}
