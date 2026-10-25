#!/usr/local/bin/php
<?php
/**
 * subscription_env_writer.php - F1 订阅 env 写入（服务端强校验的第二道防线）
 *
 * 用法：
 *   php subscription_env_writer.php <url|b64:<base64-url>> <auto_update:0|1> <interval:o6h|o12h|o24h>
 *   URL 含 & 等 shell 元字符时必须用 b64: 前缀（configd 参数经 shell 展开）
 *
 * 设计：docs/DESIGN-panel-features-v2.md D1
 *   - env 文件默认 /usr/local/etc/mihomo/sub/env，可用 MIHOMO_ENV_FILE 覆盖。
 *   - 读-改-写：保留 env 中其他行（mihomo_secret 等原样不动），只替换/追加
 *     mihomo_URL；值为 POSIX 单引号转义（' -> '\''）。
 *   - 同目录 mktemp（tempnam）+ chmod 0600 + rename 原子替换。
 *
 * 与 DESIGN-panel-features-v2.md 的显式偏差：
 *   本脚本只校验 auto_update / interval 参数的合法性，不注册/移除 Cron。
 *   Cron 项由 MVC 控制器通过 \OPNsense\Cron\Cron 模型 API 维护。
 */

const DEFAULT_ENV_FILE = '/usr/local/etc/mihomo/sub/env';

function fail(string $message): void
{
    fwrite(STDERR, '错误：' . $message . "\n");
    exit(1);
}

function usage_error(string $message): void
{
    fwrite(STDERR, $message . "\n");
    exit(64);
}

function env_file_path(): string
{
    $override = getenv('MIHOMO_ENV_FILE');
    if (is_string($override) && $override !== '') {
        return $override;
    }
    return DEFAULT_ENV_FILE;
}

// 服务端 URL 强校验：与 MVC 控制器保持同一套规则
function is_safe_subscription_url(string $url): bool
{
    if (substr($url, 0, 8) !== 'https://') {
        return false;
    }
    if (preg_match('/^https:\/\/[0-9A-Za-z._~:\/?#\[\]@!$&()*+,;=%-]+$/', $url) !== 1) {
        return false;
    }
    if (filter_var($url, FILTER_VALIDATE_URL) === false) {
        return false;
    }
    // 显式拒绝引号、反引号、命令替换前缀与控制字符（含 CR/LF/Tab/空格）
    if (
        strpos($url, "'") !== false ||
        strpos($url, '"') !== false ||
        strpos($url, '`') !== false ||
        strpos($url, '$(') !== false
    ) {
        return false;
    }
    $length = strlen($url);
    for ($i = 0; $i < $length; $i++) {
        if (ord($url[$i]) <= 32) {
            return false;
        }
    }
    return true;
}

// POSIX 单引号转义：' -> '\''
function posix_single_quote(string $value): string
{
    return str_replace(chr(39), chr(39) . chr(92) . chr(39) . chr(39), $value);
}

$args = array_slice($argv, 1);
if (count($args) !== 3) {
    usage_error('用法：php subscription_env_writer.php <url> <auto_update:0|1> <interval:o6h|o12h|o24h>');
}

list($url, $autoUpdate, $interval) = $args;

/* configd 对 %s 参数做 shell 展开，'&' 等元字符会截断命令——
 * 调用方（控制器/setup.sh）必须以 'b64:' 前缀 + base64 传 URL。
 * CLI 侧 base64(1) 默认按 76 列折行，解码前先剥离全部空白。 */
if (strncmp($url, 'b64:', 4) === 0) {
    $decoded = base64_decode(preg_replace('/\s+/', '', substr($url, 4)), true);
    if ($decoded === false || $decoded === '') {
        fail('b64: 前缀的订阅地址 base64 解码失败');
    }
    $url = $decoded;
}

if (!is_safe_subscription_url($url)) {
    fail('订阅 URL 未通过安全校验：必须为 https，且不得包含引号、反引号、控制字符或 "$("');
}
if ($autoUpdate !== '0' && $autoUpdate !== '1') {
    fail('auto_update 参数只能为 0 或 1');
}
if (!in_array($interval, ['o6h', 'o12h', 'o24h'], true)) {
    fail('interval 参数只能为 o6h、o12h 或 o24h');
}

$envFile = env_file_path();
$directory = dirname($envFile);
if (!is_dir($directory)) {
    if (!@mkdir($directory, 0700, true) && !is_dir($directory)) {
        fail('无法创建 env 目录：' . $directory);
    }
}

$existing = '';
if (file_exists($envFile)) {
    if (!is_file($envFile) || !is_readable($envFile)) {
        fail('env 路径不可读或不是普通文件：' . $envFile);
    }
    $existing = file_get_contents($envFile);
    if ($existing === false) {
        fail('读取 env 文件失败：' . $envFile);
    }
}

// 只改 mihomo_URL 行；其他行（尤其 mihomo_secret）逐行原样保留
$newLine = "mihomo_URL='" . posix_single_quote($url) . "'";
$lines = ($existing === '') ? [] : explode("\n", $existing);
$output = [];
$replaced = false;
foreach ($lines as $line) {
    if (strncmp($line, 'mihomo_URL=', 11) === 0) {
        if (!$replaced) {
            $output[] = $newLine;
            $replaced = true;
        }
        // 丢弃重复的 mihomo_URL 行，避免后面的赋值覆盖新值
        continue;
    }
    $output[] = $line;
}

if (!$replaced) {
    if (count($output) > 0 && $output[count($output) - 1] === '') {
        // 原文件以换行结尾：占位空串让追加行保持在最后一行之前
        array_pop($output);
        $output[] = $newLine;
        $output[] = '';
    } else {
        $output[] = $newLine;
    }
}

$content = implode("\n", $output);
if ($content !== '' && substr($content, -1) !== "\n") {
    $content .= "\n";
}

$realDir = realpath($directory);
if ($realDir === false) {
    fail('无法解析 env 目录：' . $directory);
}
$tmpFile = @tempnam($realDir, '.mihomo-env.');
if ($tmpFile === false) {
    fail('无法在 env 目录创建临时文件');
}
if (dirname($tmpFile) !== $realDir) {
    @unlink($tmpFile);
    fail('临时文件未落在 env 目录，拒绝继续');
}
@chmod($tmpFile, 0600);

$written = file_put_contents($tmpFile, $content, LOCK_EX);
if ($written === false || $written !== strlen($content)) {
    @unlink($tmpFile);
    fail('写入临时 env 文件失败');
}
@chmod($tmpFile, 0600);

if (!@rename($tmpFile, $envFile)) {
    @unlink($tmpFile);
    fail('原子替换 env 文件失败：' . $envFile);
}
@chmod($envFile, 0600);

echo "OK: subscription env updated\n";
exit(0);
