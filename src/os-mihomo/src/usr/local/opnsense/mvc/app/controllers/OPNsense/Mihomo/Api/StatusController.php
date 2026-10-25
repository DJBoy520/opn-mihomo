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
use OPNsense\Core\Backend;

class StatusController extends ApiControllerBase
{
    private const CONFIG_FILE = '/usr/local/etc/mihomo/config.yaml';
    private const MAX_CONFIG_READ_BYTES = 262144; // 256KB
    private const VERSION_FILE = '/usr/local/opnsense/version/mihomo';

    /**
     * 流式读取 config.yaml，提取 external-controller、secret 以及 mode
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
                $raw = trim($matches[1]);
                $commentPos = strpos($raw, ' #');
                if ($commentPos !== false) {
                    $raw = substr($raw, 0, $commentPos);
                }
                $m = strtolower(trim($raw, " \t\n\r\0\x0B\"'"));
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
     * 流式读取 config.yaml 中的 mode 配置项（回退 rule）
     */
    private function readConfigMode(): string
    {
        $info = $this->readConfigInfo();
        return $info['mode'] ?? 'rule';
    }

    /**
     * 读取插件版本号（从 version/mihomo 获取，失败回退 unknown）
     */
    private function readPluginVersion(): string
    {
        if (is_file(self::VERSION_FILE) && is_readable(self::VERSION_FILE)) {
            $handle = @fopen(self::VERSION_FILE, 'r');
            if ($handle !== false) {
                $content = '';
                while (($line = fgets($handle, 4096)) !== false) {
                    $content .= $line;
                    if (strlen($content) > 65536) {
                        break;
                    }
                }
                fclose($handle);
                $versionData = json_decode($content, true);
                if (is_array($versionData) && isset($versionData['product_version']) && is_string($versionData['product_version'])) {
                    return $versionData['product_version'];
                }
            }
        }
        return 'unknown';
    }

    /**
     * 安全执行 curl 命令，secret 写入 0600 临时配置文件（-K），并通过 try/finally 清理
     * 禁止 secret 进入命令行 argv
     */
    private function execCurl(string $method, string $url, ?string $body = null, int $timeout = 3): array
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
     * Return detailed Mihomo runtime status (7 states, versions, TUN, API, memory, mode, etc.)
     */
    public function getMihomoStatusAction()
    {
        $backend = new Backend();

        // 1. Raw status & version from configd
        $rawStatus = trim($backend->configdRun('mihomo status'));
        $rawVersion = trim($backend->configdRun('mihomo version'));
        $rawSystemStatus = trim($backend->configdRun('mihomo system-status'));

        $pluginVersion = $this->readPluginVersion();
        $configMode = $this->readConfigMode();

        // Direct state file inspection if accessible
        $stateFromFile = [];
        $stateFiles = ['/var/run/mihomo_state.json', '/var/db/os-mihomo/state.json'];
        foreach ($stateFiles as $sFile) {
            if (is_file($sFile) && is_readable($sFile)) {
                $handle = @fopen($sFile, 'r');
                if ($handle !== false) {
                    $content = '';
                    while (($line = fgets($handle, 4096)) !== false) {
                        $content .= $line;
                        if (strlen($content) > 65536) {
                            break;
                        }
                    }
                    fclose($handle);
                    if (!empty($content)) {
                        $json = json_decode($content, true);
                        if (is_array($json)) {
                            $stateFromFile = $json;
                            break;
                        }
                    }
                }
            }
        }

        $parsed = [
            'status' => 'stopped',
            'state' => 'STOPPED',
            'mode' => 'DIRECT',
            'core_mode' => $configMode,
            'state_code' => 0,
            'state_desc' => 'STOPPED',
            'message' => '',
            'last_change' => '',
            'plugin_version' => $pluginVersion,
            'mihomo_version' => 'Unknown',
            'commit' => 'Unknown',
            'sha256' => 'Unknown',
            'pid' => null,
            'memory' => '0 MB',
            'uptime' => '0s',
            'tun_status' => 'DOWN',
            'api_status' => 'DOWN',
            'raw_status' => $rawStatus,
        ];

        // Merge state from file if read directly
        if (!empty($stateFromFile)) {
            $parsed = array_merge($parsed, $stateFromFile);
        }

        // Parse system-status json from configd
        if (!empty($rawSystemStatus)) {
            $sysData = json_decode($rawSystemStatus, true);
            if (is_array($sysData)) {
                $parsed = array_merge($parsed, $sysData);
            }
        }

        // 确保 core_mode 为配置中的有效值
        $parsed['core_mode'] = $configMode;

        // Parse version output if not already parsed
        if ($parsed['mihomo_version'] === 'Unknown' && !empty($rawVersion)) {
            if (preg_match('/Mihomo(?: Meta)?\s+([^\s]+)/i', $rawVersion, $m)) {
                $parsed['mihomo_version'] = $m[1];
            }
            if (preg_match('/tags\/([^\s]+)/i', $rawVersion, $m)) {
                $parsed['mihomo_version'] = $m[1];
            }
            if (preg_match('/([0-9a-f]{7,40})/i', $rawVersion, $m)) {
                $parsed['commit'] = substr($m[1], 0, 7);
            }
        }

        // Calculate uptime and memory if PID exists
        if (!empty($parsed['pid']) && is_numeric($parsed['pid'])) {
            $pid = (int)$parsed['pid'];
            // Check process uptime via ps -o etime= -p <pid>
            $psUptime = @shell_exec(sprintf('ps -o etime= -p %d 2>/dev/null', $pid));
            if (!empty($psUptime)) {
                $parsed['uptime'] = trim($psUptime);
            }
        }

        // Ensure 7-state definitions:
        // DISABLED, STARTING, RUNNING, DEGRADED, STOPPING, STOPPED, FAILED
        $stateUpper = strtoupper($parsed['state'] ?? 'STOPPED');
        $parsed['state'] = $stateUpper;

        switch ($stateUpper) {
            case 'DISABLED':
                $parsed['state_code'] = -1;
                $parsed['status'] = 'disabled';
                $parsed['state_desc'] = 'Disabled';
                $parsed['mode'] = $parsed['mode'] ?: 'DIRECT';
                break;
            case 'STARTING':
                $parsed['state_code'] = 1;
                $parsed['status'] = 'starting';
                $parsed['state_desc'] = 'Starting';
                $parsed['mode'] = $parsed['mode'] ?: 'DIRECT';
                break;
            case 'RUNNING':
                $parsed['state_code'] = 2;
                $parsed['status'] = 'running';
                $parsed['state_desc'] = 'Running';
                $parsed['mode'] = $parsed['mode'] ?: 'UNKNOWN';
                break;
            case 'DEGRADED':
                $parsed['state_code'] = 3;
                $parsed['status'] = 'degraded';
                $parsed['state_desc'] = 'Degraded';
                break;
            case 'STOPPING':
                $parsed['state_code'] = 4;
                $parsed['status'] = 'stopping';
                $parsed['state_desc'] = 'Stopping';
                $parsed['mode'] = 'DIRECT';
                break;
            case 'STOPPED':
                $parsed['state_code'] = 0;
                $parsed['status'] = 'stopped';
                $parsed['state_desc'] = 'Stopped';
                $parsed['mode'] = 'DIRECT';
                break;
            case 'FAILED':
                $parsed['state_code'] = 5;
                $parsed['status'] = 'failed';
                $parsed['state_desc'] = 'Failed';
                $parsed['mode'] = 'DIRECT';
                break;
            default:
                $parsed['state_code'] = 0;
                $parsed['status'] = 'stopped';
                $parsed['state_desc'] = 'Stopped';
                $parsed['mode'] = 'DIRECT';
                break;
        }

        return $parsed;
    }

    /**
     * 获取当前内核运行时模式（GET /api/mihomo/status/getMode）
     * 从实时 GET /configs 读取 mode，白名单 rule|global|direct
     */
    public function getModeAction()
    {
        $configInfo = $this->readConfigInfo();
        $addr = $configInfo['addr'];
        $configMode = $configInfo['mode'] ?? 'rule';

        if ($addr === null) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'mode' => null,
                'config_mode' => $configMode,
                'note' => 'mihomo API 不可达',
            ];
        }

        $url = 'http://' . $addr['host'] . ':' . $addr['port'] . '/configs';
        $res = $this->execCurl('GET', $url, null, 3);

        if (!$res['ok'] || $res['code'] !== 200) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'mode' => null,
                'config_mode' => $configMode,
                'note' => 'mihomo API 不可达',
            ];
        }

        $bodyData = json_decode($res['body'], true);
        $runtimeMode = null;
        if (is_array($bodyData) && isset($bodyData['mode']) && is_string($bodyData['mode'])) {
            $m = strtolower(trim($bodyData['mode']));
            if (in_array($m, ['rule', 'global', 'direct'], true)) {
                $runtimeMode = $m;
            }
        }

        if ($runtimeMode === null) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'mode' => null,
                'config_mode' => $configMode,
                'note' => '内核模式解析失败',
            ];
        }

        return [
            'status' => 'ok',
            'reachable' => true,
            'mode' => $runtimeMode,
            'config_mode' => $configMode,
        ];
    }

    /**
     * 设置当前内核运行时模式（POST /api/mihomo/status/setMode）
     * 通过 PATCH /configs 局部更新运行时模式，不落盘、不改 config.yaml
     */
    public function setModeAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => '仅接受 POST 请求'];
        }

        $rawMode = $this->request->getPost('mode', 'string', null);
        if ($rawMode === null || !is_scalar($rawMode)) {
            return ['status' => 'failed', 'message' => '缺少 mode 参数'];
        }

        $mode = strtolower(trim((string)$rawMode));
        $validModes = ['rule', 'global', 'direct'];
        if (!in_array($mode, $validModes, true)) {
            return ['status' => 'failed', 'message' => '不支持的内核模式'];
        }

        $configInfo = $this->readConfigInfo();
        $addr = $configInfo['addr'];
        if ($addr === null) {
            return ['status' => 'failed', 'message' => 'mihomo API 不可达（配置未解析到有效监听）'];
        }

        $url = 'http://' . $addr['host'] . ':' . $addr['port'] . '/configs';
        $body = json_encode(['mode' => $mode]);

        $res = $this->execCurl('PATCH', $url, $body, 5);

        // HTTP 200 或 204 均判定成功
        if ($res['ok'] && ($res['code'] === 200 || $res['code'] === 204)) {
            $modeNames = [
                'rule' => '规则分流 (rule)',
                'global' => '全局代理 (global)',
                'direct' => '直连 (direct)',
            ];
            $desc = $modeNames[$mode] ?? $mode;
            return [
                'status' => 'ok',
                'mode' => $mode,
                'message' => '运行时模式已切换为 ' . $desc . '（重启后恢复配置默认）',
            ];
        }

        $errMsg = 'API 请求失败';
        if ($res['code'] > 0) {
            $errMsg .= ' (HTTP ' . $res['code'] . ')';
        }
        if (!empty($res['body'])) {
            $cleanBody = trim(preg_replace('/[\x00-\x1F\x7F]/u', '', $res['body']));
            if ($cleanBody !== '') {
                $errMsg .= ': ' . mb_substr($cleanBody, 0, 100, 'UTF-8');
            }
        } elseif (!empty($res['error'])) {
            $errMsg .= ': ' . $res['error'];
        }

        return [
            'status' => 'failed',
            'message' => $errMsg,
        ];
    }
}
