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

class LogsController extends ApiControllerBase
{
    /**
     * 日志源文件路径，直接由 PHP 以增量游标方式读取（fopen/fseek/fread），不再走 configd。
     * 注：此路径与 actions.d/actions_mihomo.conf [log] 的 /var/log/mihomo.log 同源。
     * 兼容性注释：旧版本使用 configdpRun('mihomo log', ...) 读取，v1.0.9 升级为增量游标直读。
     */
    private const LOG_FILE_PATH = '/var/log/mihomo.log';

    /**
     * 单次增量读取的最大字节数限制（256KB）。
     * 超过此限制时判定为增量过大，直接拉取末尾最新行并置 truncated=true 提示前端全量重拉。
     */
    private const MAX_DELTA_BYTES = 262144; // 256 * 1024

    /**
     * Sanitize sensitive information from log lines (passwords, secrets, tokens, etc.)
     */
    private function sanitizeLogLine($line)
    {
        if (!is_string($line) || $line === '') {
            return $line;
        }
        // Redact secret: "..." or secret: ...
        $line = preg_replace('/(secret:\s*["\']?)([^"\'\s]+)(["\']?)/i', '$1******$3', $line);
        // Redact password: "..."
        $line = preg_replace('/(password:\s*["\']?)([^"\'\s]+)(["\']?)/i', '$1******$3', $line);
        // Redact uuid / tokens / keys
        $line = preg_replace('/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-)[a-f0-9]{12}/i', '$1************', $line);
        // Redact Bearer tokens
        $line = preg_replace('/(Bearer\s+)[A-Za-z0-9_\-\.]+/i', '$1******', $line);
        return $line;
    }

    /**
     * 将单行原始日志解析为结构化数据，若不符合 logfmt 格式则放入 raw 字段。
     * 所有输出字段均经 sanitizeLogLine 脱敏。
     */
    private function parseLogEntry($line)
    {
        // 匹配 logfmt time="..." level=... msg="..." 格式
        $pattern = '/^time=(?:"([^"]*)"|(\S+))\s+level=(?:"([^"]*)"|(\S+))\s+msg=(?:"([^"]*)"|(.*))$/';
        if (preg_match($pattern, $line, $matches)) {
            $time = !empty($matches[1]) ? $matches[1] : (!empty($matches[2]) ? $matches[2] : '');
            $level = !empty($matches[3]) ? $matches[3] : (!empty($matches[4]) ? $matches[4] : 'info');
            $msg = isset($matches[5]) && $matches[5] !== '' ? $matches[5] : (isset($matches[6]) ? $matches[6] : '');

            $levelLower = strtolower($level);
            if ($levelLower === 'warn') {
                $levelLower = 'warning';
            }

            return [
                'time' => $this->sanitizeLogLine($time),
                'level' => $this->sanitizeLogLine($levelLower),
                'msg' => $this->sanitizeLogLine($msg),
            ];
        }

        return [
            'raw' => $this->sanitizeLogLine($line),
        ];
    }

    /**
     * 判断日志条目是否符合目标 level 过滤条件
     */
    private function matchLevelFilter($entry, $targetLevel)
    {
        if ($targetLevel === 'all') {
            return true;
        }

        if (isset($entry['level'])) {
            return $entry['level'] === $targetLevel;
        }

        // 若为 raw 格式，尝试通过正则探测级别
        if (isset($entry['raw'])) {
            if (preg_match('/\blevel=(debug|info|warning|warn|error|fatal|silent)\b/i', $entry['raw'], $m) ||
                preg_match('/\[(debug|info|warning|warn|error|fatal|silent)\]/i', $entry['raw'], $m)) {
                $lineLevel = strtolower($m[1]);
                if ($lineLevel === 'warn') {
                    $lineLevel = 'warning';
                }
                return $lineLevel === $targetLevel;
            }
        }

        return false;
    }

    /**
     * 寻找文件中最后一个换行符之后的字节偏移。
     * 若末尾存在未写完的半行，游标仅推进到换行符之后，避免截断与重复读取。
     */
    private function findLastNewlineOffset($handle, $fileSize)
    {
        if ($fileSize <= 0) {
            return 0;
        }
        $bufferSize = 4096;
        $pos = $fileSize;
        while ($pos > 0) {
            $readSize = min($bufferSize, $pos);
            $pos -= $readSize;
            fseek($handle, $pos, SEEK_SET);
            $chunk = fread($handle, $readSize);
            $nlPos = strrpos($chunk, "\n");
            if ($nlPos !== false) {
                return $pos + $nlPos + 1;
            }
        }
        return 0;
    }

    /**
     * 从文件最后一个完整换行符处向前读取指定数量的有效行
     */
    private function readTailLines($handle, $validEnd, $maxLines)
    {
        if ($validEnd <= 0) {
            return [];
        }

        $bufferSize = 4096;
        $pos = $validEnd;
        $remaining = '';
        $lines = [];

        while ($pos > 0 && count($lines) <= $maxLines) {
            $readSize = min($bufferSize, $pos);
            $pos -= $readSize;
            fseek($handle, $pos, SEEK_SET);
            $chunk = fread($handle, $readSize) . $remaining;
            $chunkLines = preg_split("/\r\n|\n|\r/", $chunk);

            if ($pos > 0) {
                $remaining = array_shift($chunkLines);
                $lines = array_merge($chunkLines, $lines);
            } else {
                $lines = array_merge($chunkLines, $lines);
            }
        }

        if (!empty($lines) && end($lines) === '') {
            array_pop($lines);
        }

        if (count($lines) > $maxLines) {
            $lines = array_slice($lines, -$maxLines);
        }

        return $lines;
    }

    /**
     * Get Mihomo logs with optional cursor, level filter, and sensitive information masking.
     * 直接通过 PHP 读 /var/log/mihomo.log（fopen/fseek/fread），不再走 configd。
     */
    public function getLogsAction()
    {
        $level = strtolower($this->request->get('level', 'string', 'all'));
        $limit = (int)$this->request->get('limit', 'int', 500);
        if ($limit <= 0 || $limit > 2000) {
            $limit = 500;
        }

        $cursor = (int)$this->request->get('cursor', 'int', 0);

        if (!file_exists(self::LOG_FILE_PATH)) {
            return [
                'status' => 'ok',
                'entries' => [],
                'cursor' => 0,
                'truncated' => false,
            ];
        }

        // 清除文件状态缓存，获取真实大小
        clearstatcache(true, self::LOG_FILE_PATH);
        $fileSize = (int)filesize(self::LOG_FILE_PATH);

        $handle = @fopen(self::LOG_FILE_PATH, 'rb');
        if ($handle === false) {
            // 打开失败（如权限不足，noroot 环境等），返回明确错误状态以便前端提示
            return [
                'status' => 'failed',
                'message' => 'Unable to read log file: /var/log/mihomo.log (permission denied or file locked)',
                'entries' => [],
                'cursor' => $cursor > 0 ? $cursor : 0,
                'truncated' => false,
            ];
        }

        $entries = [];
        $truncated = false;
        $newCursor = $cursor;

        if ($cursor <= 0) {
            // 全量拉取末尾 min(limit, 2000) 行
            $maxLines = min($limit, 2000);
            $validEnd = $this->findLastNewlineOffset($handle, $fileSize);
            $rawLines = $this->readTailLines($handle, $validEnd, $maxLines);
            foreach ($rawLines as $line) {
                $trimmed = trim($line);
                if ($trimmed === '') {
                    continue;
                }
                $entry = $this->parseLogEntry($trimmed);
                if ($this->matchLevelFilter($entry, $level)) {
                    $entries[] = $entry;
                }
            }
            $newCursor = $validEnd;
        } else {
            // 增量读取模式
            if ($fileSize < $cursor) {
                // 文件被轮转或截断：重置读末尾并置 truncated=true
                $truncated = true;
                $maxLines = min($limit, 2000);
                $validEnd = $this->findLastNewlineOffset($handle, $fileSize);
                $rawLines = $this->readTailLines($handle, $validEnd, $maxLines);
                foreach ($rawLines as $line) {
                    $trimmed = trim($line);
                    if ($trimmed === '') {
                        continue;
                    }
                    $entry = $this->parseLogEntry($trimmed);
                    if ($this->matchLevelFilter($entry, $level)) {
                        $entries[] = $entry;
                    }
                }
                $newCursor = $validEnd;
            } elseif (($fileSize - $cursor) > self::MAX_DELTA_BYTES) {
                // 单次增量超过 256KB：只读末尾 limit 行并置 truncated=true（前端全量重拉）
                $truncated = true;
                $maxLines = min($limit, 2000);
                $validEnd = $this->findLastNewlineOffset($handle, $fileSize);
                $rawLines = $this->readTailLines($handle, $validEnd, $maxLines);
                foreach ($rawLines as $line) {
                    $trimmed = trim($line);
                    if ($trimmed === '') {
                        continue;
                    }
                    $entry = $this->parseLogEntry($trimmed);
                    if ($this->matchLevelFilter($entry, $level)) {
                        $entries[] = $entry;
                    }
                }
                $newCursor = $validEnd;
            } else {
                // 正常增量获取 cursor 到当前文件末尾的字节
                fseek($handle, $cursor, SEEK_SET);
                $deltaBytes = $fileSize - $cursor;
                if ($deltaBytes > 0) {
                    $content = fread($handle, $deltaBytes);
                    $lastNl = strrpos($content, "\n");
                    if ($lastNl !== false) {
                        $completeChunk = substr($content, 0, $lastNl);
                        $newCursor = $cursor + $lastNl + 1;
                        $rawLines = preg_split("/\r\n|\n|\r/", $completeChunk);
                        foreach ($rawLines as $line) {
                            $trimmed = trim($line);
                            if ($trimmed === '') {
                                continue;
                            }
                            $entry = $this->parseLogEntry($trimmed);
                            if ($this->matchLevelFilter($entry, $level)) {
                                $entries[] = $entry;
                            }
                        }
                    } else {
                        // 本次 delta 尚无换行符，说明整段均为未完成的半行，保持原 cursor 等待下次完成
                        $newCursor = $cursor;
                    }
                } else {
                    $newCursor = $cursor;
                }
            }
        }

        fclose($handle);

        return [
            'status' => 'ok',
            'entries' => $entries,
            'cursor' => $newCursor,
            'truncated' => $truncated,
        ];
    }
}
