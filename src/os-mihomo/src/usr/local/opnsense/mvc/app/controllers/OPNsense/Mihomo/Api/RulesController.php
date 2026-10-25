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
use OPNsense\Core\Config;
use OPNsense\Mihomo\Mihomo;

/**
 * 持久自定义分流规则 API（F3）
 *
 * 校验单一真源是 custom_rules_validate.php；控制器只负责把内容交给校验器，
 * 校验通过后写模型并把文本原子写入 custom-rules.txt，再由 configd 动作
 * mihomo rules-apply 做编译级预检并原子替换生产配置。
 */
class RulesController extends ApiControllerBase
{
    const VALIDATOR = '/usr/local/opnsense/scripts/OPNsense/Mihomo/custom_rules_validate.php';
    const RULES_FILE = '/usr/local/etc/mihomo/custom-rules.txt';
    const CONFIG_FILE = '/usr/local/etc/mihomo/config.yaml';
    const MAX_LINES = 200;
    const MAX_BYTES = 32768;

    /**
     * 返回当前规则、允许的类型列表、允许的目标集合与上限（类型与目标均由校验器解析，失败时回退）
     */
    public function getAction()
    {
        $model = new Mihomo();
        return [
            'status' => 'ok',
            'content' => (string)$model->customRules->content,
            'ruleTypes' => $this->fetchRuleTypes(),
            'targets' => $this->fetchTargets(),
            'limits' => [
                'maxLines' => self::MAX_LINES,
                'maxBytes' => self::MAX_BYTES,
            ],
            /* 与 setAction 的拒绝规则保持一致：空内容必须显式 clear=1 才允许写入 */
            'clearRequiresExplicit' => true,
        ];
    }

    /**
     * 校验并保存规则，随后同步应用（mihomo -t 预检失败则生产配置不动）
     */
    public function setAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => '仅接受 POST 请求'];
        }

        // mihomo -t 处理 17MB 级配置可能超过默认脚本时限
        set_time_limit(180);
        $content = $this->postedContent();
        if ($content === null) {
            return ['status' => 'failed', 'message' => '规则内容格式无效'];
        }

        // 空内容会把事故（前端空白）固化成 custom-rules.txt 清空：仅显式 clear=1 才允许
        $clearRequested = (string)$this->request->getPost('clear') === '1';
        if (!$clearRequested && trim($content) === '') {
            return [
                'status' => 'failed',
                'message' => '空内容将清空自定义规则，如需清空请显式传 clear=1',
            ];
        }

        $tmpFile = tempnam(sys_get_temp_dir(), 'mihomo-rules-');
        if ($tmpFile === false) {
            return ['status' => 'failed', 'message' => '无法创建临时文件'];
        }
        chmod($tmpFile, 0600);
        if (file_put_contents($tmpFile, $content) === false) {
            @unlink($tmpFile);
            return ['status' => 'failed', 'message' => '无法写入临时文件'];
        }

        $command = '/usr/local/bin/php ' . escapeshellarg(self::VALIDATOR) . ' '
            . escapeshellarg($tmpFile) . ' 2>/dev/null';
        $output = shell_exec($command);
        @unlink($tmpFile);

        $decoded = is_string($output) ? json_decode(trim($output), true) : null;
        if (!is_array($decoded) || !isset($decoded['valid'])) {
            return ['status' => 'failed', 'message' => '规则校验器不可用或返回了无法解析的结果'];
        }
        if ($decoded['valid'] !== true) {
            $errors = isset($decoded['errors']) && is_array($decoded['errors'])
                ? $decoded['errors']
                : [];
            return ['status' => 'failed', 'message' => '规则校验失败', 'errors' => $errors];
        }

        try {
            $model = new Mihomo();
            $model->customRules->content = $content;
            $model->serializeToConfig();
            if (Config::getInstance()->save() === false) {
                throw new \Exception('config.xml 写入失败（可能被锁定）');
            }
        } catch (\Exception $e) {
            return ['status' => 'failed', 'message' => '保存规则失败: ' . $e->getMessage()];
        }

        $writeError = $this->writeRulesFile($content);
        if ($writeError !== '') {
            return ['status' => 'failed', 'message' => $writeError];
        }

        $applyOutput = trim((string)(new Backend())->configdRun('mihomo rules-apply'));
        $firstWord = '';
        if ($applyOutput !== '') {
            $parts = preg_split('/\s+/', $applyOutput);
            $firstWord = isset($parts[0]) ? $parts[0] : '';
        }
        // rules-apply 成功时首词为 OK 或 OK:（如 "OK: config recomposed from cache"）
        if (!preg_match('/^OK(?::|$)/', $firstWord)) {
            return [
                'status' => 'failed',
                'message' => '规则已保存，但应用失败: ' . $this->truncate($applyOutput),
            ];
        }

        return [
            'status' => 'ok',
            'message' => $applyOutput !== '' ? $this->truncate($applyOutput) : '规则已保存并应用',
        ];
    }

    /**
     * 允许目标集合：优先取校验器（含模板 proxy-groups），失败回退基础集合
     */
    private function fetchTargets()
    {
        $command = '/usr/local/bin/php ' . self::VALIDATOR . ' --targets 2>/dev/null';
        $output = shell_exec($command);
        if (is_string($output)) {
            $decoded = json_decode(trim($output), true);
            if (is_array($decoded) && isset($decoded['targets']) && is_array($decoded['targets'])) {
                return array_map('strval', array_values($decoded['targets']));
            }
        }
        return ['DIRECT', 'REJECT', 'REJECT-DROP'];
    }

    /**
     * 兼容扁平 content 与 mihomo[customRules][content] 两种提交形态
     * 返回 null 表示提交内容类型非法（数组等），调用方应直接拒绝。
     */
    private function postedContent()
    {
        $nested = $this->request->getPost('mihomo');
        if (is_array($nested) && isset($nested['customRules'])) {
            $rules = $nested['customRules'];
            if (!is_array($rules) || !isset($rules['content'])) {
                return null;
            }
            return is_scalar($rules['content']) ? (string)$rules['content'] : null;
        }
        $direct = $this->request->getPost('content');
        if ($direct !== null) {
            return is_scalar($direct) ? (string)$direct : null;
        }
        return '';
    }

    /**
     * 同目录 tmp（0600）→ rename 原子替换，避免读到半截文件
     * 返回空字符串表示成功，否则返回中文错误。
     */
    private function writeRulesFile($content)
    {
        $directory = dirname(self::RULES_FILE);
        if (!is_dir($directory) && !@mkdir($directory, 0750, true)) {
            return '规则目录不存在且无法创建: ' . $directory;
        }

        $tmpFile = tempnam($directory, '.custom-rules.');
        if ($tmpFile === false) {
            return '无法在规则目录创建临时文件';
        }
        // tempnam 在目标目录不可写时会退回到系统临时目录，必须同目录才能保证原子 rename
        if (dirname($tmpFile) !== $directory) {
            @unlink($tmpFile);
            return '规则目录不可写: ' . $directory;
        }
        chmod($tmpFile, 0600);
        if (file_put_contents($tmpFile, $content, LOCK_EX) === false) {
            @unlink($tmpFile);
            return '写入自定义规则临时文件失败';
        }
        chmod($tmpFile, 0600);
        if (!@rename($tmpFile, self::RULES_FILE)) {
            @unlink($tmpFile);
            return '替换自定义规则文件失败';
        }
        return '';
    }

    private function truncate($text, $limit = 300)
    {
        $text = trim((string)$text);
        if (strlen($text) > $limit) {
            return substr($text, 0, $limit) . '...';
        }
        return $text;
    }

    /**
     * 读取生效的分流规则（流式读取 config.yaml rules: 块 + 分页与搜索；/version 安全探测）
     *
     * 遵循契约：
     * - 服务端解析 /usr/local/etc/mihomo/config.yaml：
     *   ^external-controller: 的 host:port（0.0.0.0 归一化为 127.0.0.1）
     *   ^secret: 实际值（非空才带 Authorization: Bearer 头）
     * - curl 调 http://<host>:<port>/version 进行安全探测（-m 3 超时；所有拼参 escapeshellarg）
     * - 为防止进程列表泄漏 secret，通过 0600 临时 curl 配置文件传 header
     * - 非 200/失败/超时 → 返回 {status:"ok", reachable:false, rules:[], total:0, offset:0, limit:$limit, truncated:false, query:$q, note:"mihomo API 不可达"}，绝不抛错
     * - 可达时不再请求 /rules，改用 fopen/fgets 流式读取 config.yaml rules: 块
     * - 查询参数：limit（默认 200，1~1000）、offset（>=0）、q（<=200 字符，去控制字符）
     * - 返回 {status:'ok', reachable:true, rules:[{type,payload,proxy}], total, offset, limit, truncated, query}
     * - 规则解析：MATCH,proxy 的 payload 为空、proxy 取第二段；其余取前三段；坏行跳过
     * - secret 绝不能出现在响应里
     */
    public function getEffectiveRulesAction()
    {
        $rawLimit = $this->request->get('limit', 'int', 200);
        $limit = ($rawLimit !== null && (int)$rawLimit >= 1) ? min(1000, (int)$rawLimit) : 200;

        $rawOffset = $this->request->get('offset', 'int', 0);
        $offset = ($rawOffset !== null && (int)$rawOffset >= 0) ? (int)$rawOffset : 0;

        $rawQ = $this->request->get('q', 'string', '');
        $q = '';
        if ($rawQ !== null && is_scalar($rawQ)) {
            // <=200 字符，去除控制字符（保留常规 Unicode/中文与普通 ASCII）
            $sanitized = preg_replace('/[\x00-\x1F\x7F]/u', '', (string)$rawQ);
            $q = mb_substr(trim($sanitized), 0, 200, 'UTF-8');
        }

        $addr = $this->readApiAddr();
        if ($addr === null) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'rules' => [],
                'total' => 0,
                'offset' => $offset,
                'limit' => $limit,
                'truncated' => false,
                'query' => $q,
                'note' => 'mihomo API 不可达',
            ];
        }

        $host = $addr['host'];
        $port = $addr['port'];
        $secret = $this->readConfigSecret();

        $url = 'http://' . $host . ':' . $port . '/version';
        $cmd = '/usr/local/bin/curl -s -m 3 --connect-timeout 2';

        $cfgFile = null;
        if ($secret !== '') {
            $cfgFile = tempnam(sys_get_temp_dir(), 'mihomo-curl-');
            if ($cfgFile !== false) {
                chmod($cfgFile, 0600);
                // curl 配置文件格式：header = "..."，防止 secret 进入命令行 argv
                $cfgContent = 'header = "Authorization: Bearer ' . str_replace(['\\', '"'], ['\\\\', '\\"'], $secret) . "\"\n";
                if (file_put_contents($cfgFile, $cfgContent) !== false) {
                    $cmd .= ' -K ' . escapeshellarg($cfgFile);
                } else {
                    @unlink($cfgFile);
                    $cfgFile = null;
                }
            }
        }

        $cmd .= ' -w ' . escapeshellarg("\n%{http_code}") . ' ' . escapeshellarg($url) . ' 2>/dev/null';

        $output = shell_exec($cmd);
        if ($cfgFile !== null) {
            @unlink($cfgFile);
        }

        if (!is_string($output) || $output === '') {
            return [
                'status' => 'ok',
                'reachable' => false,
                'rules' => [],
                'total' => 0,
                'offset' => $offset,
                'limit' => $limit,
                'truncated' => false,
                'query' => $q,
                'note' => 'mihomo API 不可达',
            ];
        }

        $lastNewline = strrpos($output, "\n");
        if ($lastNewline === false) {
            return [
                'status' => 'ok',
                'reachable' => false,
                'rules' => [],
                'total' => 0,
                'offset' => $offset,
                'limit' => $limit,
                'truncated' => false,
                'query' => $q,
                'note' => 'mihomo API 不可达',
            ];
        }

        $httpCode = trim(substr($output, $lastNewline + 1));
        if ($httpCode !== '200') {
            return [
                'status' => 'ok',
                'reachable' => false,
                'rules' => [],
                'total' => 0,
                'offset' => $offset,
                'limit' => $limit,
                'truncated' => false,
                'query' => $q,
                'note' => 'mihomo API 不可达',
            ];
        }

        // API 探测可达，流式解析 config.yaml 的 rules: 块
        $parsed = $this->parseConfigRulesPaged(self::CONFIG_FILE, $offset, $limit, $q);

        return [
            'status' => 'ok',
            'reachable' => true,
            'rules' => $parsed['rules'],
            'total' => $parsed['total'],
            'offset' => $offset,
            'limit' => $limit,
            'truncated' => $parsed['truncated'],
            'query' => $q,
        ];
    }

    /**
     * 流式读取 config.yaml 中的 rules: 块，逐行匹配与分页
     */
    private function parseConfigRulesPaged($configFile, $offset, $limit, $q)
    {
        $rules = [];
        $total = 0;
        $truncated = false;

        if (!is_file($configFile) || !is_readable($configFile)) {
            return [
                'rules' => $rules,
                'total' => $total,
                'truncated' => $truncated,
            ];
        }

        $handle = @fopen($configFile, 'r');
        if ($handle === false) {
            return [
                'rules' => $rules,
                'total' => $total,
                'truncated' => $truncated,
            ];
        }

        $inRules = false;
        $hasQ = ($q !== '');
        $qLower = $hasQ ? mb_strtolower($q, 'UTF-8') : '';

        while (($line = fgets($handle)) !== false) {
            $line = rtrim($line, "\r\n");

            if (!$inRules) {
                if (preg_match('/^rules[ \t]*:/', $line) === 1) {
                    $inRules = true;
                }
                continue;
            }

            // 遇到下一个顶层键退出 rules 块
            if ($line !== '' && preg_match('/^[^ \t#-]/', $line) === 1) {
                break;
            }

            // 规则行必须以 "- " 引导
            if (preg_match('/^[ \t]*-[ \t]+(.*)$/', $line, $matches) !== 1) {
                continue;
            }

            $rawRule = trim($matches[1]);
            if ($rawRule === '' || $rawRule[0] === '#') {
                continue;
            }

            // 剥离可能的外层引号（如 - "DOMAIN-SUFFIX,google.com,DIRECT" 或 - '...'）
            if (($rawRule[0] === '"' && substr($rawRule, -1) === '"') ||
                ($rawRule[0] === "'" && substr($rawRule, -1) === "'")) {
                $rawRule = substr($rawRule, 1, -1);
            }

            // 逗号分段
            $parts = explode(',', $rawRule);
            $partCount = count($parts);
            if ($partCount < 2) {
                // 坏行跳过
                continue;
            }

            $type = trim($parts[0]);
            if ($type === '') {
                continue;
            }

            $payload = '';
            $proxy = '';

            if (strcasecmp($type, 'MATCH') === 0) {
                // MATCH,proxy 的 payload 为空、proxy 取第二段
                $proxy = trim($parts[1]);
            } else {
                if ($partCount < 3) {
                    // 非 MATCH 至少需要 3 段
                    continue;
                }
                // 其余 type/payload/proxy 取前三段
                $payload = trim($parts[1]);
                $proxy = trim($parts[2]);
            }

            if ($proxy === '') {
                continue;
            }

            // 搜索过滤（支持 type / payload / proxy）
            if ($hasQ) {
                $typeMatch = (mb_stripos($type, $qLower, 0, 'UTF-8') !== false);
                $payloadMatch = ($payload !== '' && mb_stripos($payload, $qLower, 0, 'UTF-8') !== false);
                $proxyMatch = (mb_stripos($proxy, $qLower, 0, 'UTF-8') !== false);
                if (!$typeMatch && !$payloadMatch && !$proxyMatch) {
                    continue;
                }
            }

            // 匹配项计数
            if ($total >= $offset && count($rules) < $limit) {
                $rules[] = [
                    'type' => $type,
                    'payload' => $payload,
                    'proxy' => $proxy,
                ];
            }
            $total++;
        }

        fclose($handle);

        // 当前窗口之后仍有匹配项时标记 truncated，供前端/调用方判断
        $truncated = (($offset + count($rules)) < $total);

        return [
            'rules' => $rules,
            'total' => $total,
            'truncated' => $truncated,
        ];
    }

    /**
     * 解析 config.yaml 中的 external-controller，0.0.0.0 归一化为 127.0.0.1
     * 解析失败或损坏时返回 null（视为不可达分支，不自动回退端口）
     */
    private function readApiAddr()
    {
        if (!is_file(self::CONFIG_FILE) || !is_readable(self::CONFIG_FILE)) {
            return null;
        }

        $lines = @file(self::CONFIG_FILE, FILE_IGNORE_NEW_LINES);
        if ($lines === false) {
            return null;
        }

        foreach ($lines as $line) {
            if (preg_match('/^external-controller:\s*(.*)$/', $line, $matches)) {
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
                            return ['host' => $h, 'port' => $pInt];
                        }
                    }
                }
                break;
            }
        }

        return null;
    }

    /**
     * 直接读取 /usr/local/etc/mihomo/config.yaml 中生效的 ^secret: 实际值
     * 缺失或空值返回空字符串。注释只在带有前置空格的 ' #' 处剥离，与 YAML 规范保持一致。
     */
    private function readConfigSecret()
    {
        if (!is_file(self::CONFIG_FILE) || !is_readable(self::CONFIG_FILE)) {
            return '';
        }

        $lines = @file(self::CONFIG_FILE, FILE_IGNORE_NEW_LINES);
        if ($lines === false) {
            return '';
        }

        foreach ($lines as $line) {
            if (preg_match('/^secret:[[:space:]]*(.*)$/', $line, $matches)) {
                $raw = trim($matches[1]);
                if ($raw === '') {
                    return '';
                }
                if (preg_match('/^(["\'])(.*)\1\s*(?:#.*)?$/', $raw, $qMatches)) {
                    return trim($qMatches[2]);
                }
                $commentPos = strpos($raw, ' #');
                if ($commentPos !== false) {
                    $raw = substr($raw, 0, $commentPos);
                }
                return trim($raw, " \t\n\r\0\x0B\"'");
            }
        }

        return '';
    }

    /**
     * 从校验器 custom_rules_validate.php 动态提取 RULE_TYPES 常量，保证单一真源
     */
    private function fetchRuleTypes()
    {
        $defaultTypes = [
            'DOMAIN',
            'DOMAIN-SUFFIX',
            'DOMAIN-KEYWORD',
            'IP-CIDR',
            'IP-CIDR6',
            'GEOIP',
            'GEOSITE',
            'DST-PORT',
        ];

        if (!is_file(self::VALIDATOR) || !is_readable(self::VALIDATOR)) {
            return $defaultTypes;
        }

        $content = @file_get_contents(self::VALIDATOR);
        if ($content === false) {
            return $defaultTypes;
        }

        if (preg_match('/const\s+RULE_TYPES\s*=\s*\[(.*?)\];/s', $content, $matches)) {
            if (preg_match_all('/[\'"]([A-Za-z0-9_-]+)[\'"]/', $matches[1], $itemMatches)) {
                if (!empty($itemMatches[1])) {
                    return array_values(array_unique($itemMatches[1]));
                }
            }
        }

        return $defaultTypes;
    }
}
