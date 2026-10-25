#!/usr/local/bin/php
<?php
/**
 * mihomo_setup.php - 一键安装的 CLI 引导脚本（模型 + Cron 注册）
 *
 * 用法：
 *   php mihomo_setup.php <url> <transport:transparent|proxy> <auto_update:0|1> <interval:o6h|o12h|o24h>
 *
 * 参数：
 *   url         订阅地址；传空字符串表示保持模型现有值（不校验、不覆盖）
 *   transport   transparent 或 proxy
 *   auto_update 1 启用订阅自动更新任务；0 仅禁用既有任务、不删除
 *   interval    o6h / o12h / o24h
 *
 * 输出：
 *   成功：单行 JSON {"result":"ok","transport":...,"sub_cron":...,"watchdog_cron":true,"url_masked":...}
 *   失败：单行 JSON {"result":"failed","message":"中文原因"}，退出码 1
 *
 * 设计：docs/DESIGN-panel-features-v2.md（D1 与实施修订记录第 2 条）
 *   - 订阅 URL 的单一真源是 MVC 模型 //OPNsense/mihomo，本脚本不直接读写配置文件。
 *   - 调度写 /etc/cron.d/os-mihomo（系统官方支持，模型物化在 26.7 无可编程触发
 *     路径，见设计文档实施修订记录）；watchdog 每分钟常驻，fail-open 安全网。
 *   - 本脚本不执行 filter reload / transport-enable，PF 与传输层编排由 setup.sh 负责。
 */

use OPNsense\Core\Config;
use OPNsense\Cron\Cron;
use OPNsense\Mihomo\Mihomo;

/*
 * OPNsense CLI 引导：核心 php.ini 的 include_path 已包含 /usr/local/opnsense/mvc，
 * 该文件负责注册自动加载器并初始化 Config 单例。必须是第一个逻辑语句
 * （上面的 use 是编译期声明，不产生运行时动作）。
 */
require_once('script/load_phalcon.php');

/* 定时任务识别键：固定 description，与 SubscriptionController 保持一致，改动会导致既有任务无法识别 */
const MIHOMO_SETUP_CRON_SUB_DESCRIPTION = 'os-mihomo auto sub-update';
const MIHOMO_SETUP_CRON_SUB_COMMAND = 'mihomo sub-update';
const MIHOMO_SETUP_CRON_WATCHDOG_DESCRIPTION = 'os-mihomo watchdog';
const MIHOMO_SETUP_CRON_WATCHDOG_COMMAND = 'mihomo watchdog';

/* CLI 下 display_errors 可能写 stdout；改到 stderr，保证 stdout 只有单行 JSON */
ini_set('display_errors', 'stderr');

/**
 * 输出单行 JSON（不转义中文与斜杠，便于 shell 侧 grep 判定）
 */
function mihomo_setup_output(array $payload): void
{
    $flags = JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES;
    if (defined('JSON_INVALID_UTF8_SUBSTITUTE')) {
        $flags |= JSON_INVALID_UTF8_SUBSTITUTE;
    }
    $json = json_encode($payload, $flags);
    if ($json === false) {
        $json = '{"result":"failed","message":"JSON 编码失败"}';
    }
    echo $json . "\n";
}

/**
 * 失败退出：统一 JSON 结构 + 退出码 1
 */
function mihomo_setup_fail(string $message): void
{
    mihomo_setup_output(['result' => 'failed', 'message' => $message]);
    exit(1);
}

/**
 * 订阅 URL 强校验：与 SubscriptionController::validateUrl 完全同规则
 * 返回空字符串表示通过，否则返回中文原因。
 */
function mihomo_setup_validate_url(string $url): string
{
    $pattern = '/\Ahttps:\/\/[0-9A-Za-z._~:\/?#\[\]@!$&()*+,;=%-]+\z/';
    if (!preg_match($pattern, $url)) {
        return '订阅地址包含不允许的字符（仅支持 https 且限定 URL 字符集）';
    }
    if (filter_var($url, FILTER_VALIDATE_URL) === false) {
        return '订阅地址不是合法的 URL';
    }
    if (strpos($url, 'https://') !== 0) {
        return '订阅地址必须以 https:// 开头';
    }
    foreach (["'", '"', '`'] as $forbidden) {
        if (strpos($url, $forbidden) !== false) {
            return '订阅地址不得包含引号或反引号';
        }
    }
    if (strpos($url, '$(') !== false) {
        return '订阅地址不得包含 $( 子串';
    }
    for ($i = 0, $length = strlen($url); $i < $length; $i++) {
        if (ord($url[$i]) < 33) {
            return '订阅地址不得包含空白或控制字符';
        }
    }
    return '';
}

/**
 * 生成 scheme://host/*** 形式的掩码：path/query/token 与 userinfo 一律不返回
 */
function mihomo_setup_mask_url(string $url): string
{
    /* 用 ~ 作分隔符：# 会出现在字符类 [^/?#] 中，用 # 作分隔符会被 PHP 误判为结束符 */
    $pattern = '~^([A-Za-z][A-Za-z0-9+.-]*://)(?:[^/?#]*@)?([^/?#]+)~';
    if (preg_match($pattern, $url, $matches) === 1) {
        return $matches[1] . $matches[2] . '/***';
    }
    return '***';
}

/**
 * interval 到 cron hours 字段的映射（与 SubscriptionController::syncCronJob 的语义一致）
 *
 * 注意：OPNsense 核心 Cron 模型的 hours 掩码只允许 0-23 的值与步长（Cron.xml），
 * 以星号加斜杠表示的 24 小时步长会被 serializeToConfig() 的校验以 ValidationException 拒绝。
 * 该步长在 cron 中的实际触发时刻与 0 等价（每日 00:00），因此 o24h 映射为 0，
 * 既保持“每 24 小时一次”的语义，又能通过模型校验。
 */
function mihomo_setup_cron_hours(string $interval): string
{
    $hoursMap = ['o6h' => '*/6', 'o12h' => '*/12', 'o24h' => '0'];
    return isset($hoursMap[$interval]) ? $hoursMap[$interval] : '0';
}

/**
 * 订阅自动更新任务的标准字段
 */
function mihomo_setup_sub_cron_fields(string $hours): array
{
    return [
        'minutes' => '0',
        'hours' => $hours,
        'days' => '*',
        'months' => '*',
        'weekdays' => '*',
        'command' => MIHOMO_SETUP_CRON_SUB_COMMAND,
        'parameters' => '',
        'enabled' => '1',
        'description' => MIHOMO_SETUP_CRON_SUB_DESCRIPTION,
    ];
}

/**
 * watchdog 任务的标准字段（fail-open 安全网，始终启用）
 */
function mihomo_setup_watchdog_cron_fields(): array
{
    return [
        'minutes' => '*/1',
        'hours' => '*',
        'days' => '*',
        'months' => '*',
        'weekdays' => '*',
        'command' => MIHOMO_SETUP_CRON_WATCHDOG_COMMAND,
        'parameters' => '',
        'enabled' => '1',
        'description' => MIHOMO_SETUP_CRON_WATCHDOG_DESCRIPTION,
    ];
}

/**
 * 新建任务：无条件写入全部字段，避免依赖模型默认值是否已落盘
 */
function mihomo_setup_assign_fields($job, array $fields): void
{
    foreach ($fields as $name => $value) {
        $job->{$name} = (string)$value;
    }
}

/**
 * 既有任务：仅在字段实际不同时写入，返回是否发生变更
 */
function mihomo_setup_sync_fields($job, array $fields): bool
{
    $changed = false;
    foreach ($fields as $name => $value) {
        $value = (string)$value;
        if ((string)$job->{$name} !== $value) {
            $job->{$name} = $value;
            $changed = true;
        }
    }
    return $changed;
}

/* ------------------------------ 主流程 ------------------------------ */

$args = array_slice($argv, 1);

/* --cron-only 模式：只重写 /etc/cron.d/os-mihomo，不碰模型。
 * 供 configd 动作 setup-cron 调用（面板改自动更新设置时同步调度）。 */
if (count($args) === 3 && $args[0] === '--cron-only') {
    $autoUpdateArg = $args[1];
    $interval = $args[2];
    if ($autoUpdateArg !== '0' && $autoUpdateArg !== '1') {
        mihomo_setup_fail('auto_update 参数只能为 0 或 1');
    }
    if (!in_array($interval, ['o6h', 'o12h', 'o24h'], true)) {
        mihomo_setup_fail('interval 参数只能为 o6h、o12h 或 o24h');
    }
    if (!mihomo_setup_write_cron_d((int)$autoUpdateArg, $interval)) {
        mihomo_setup_fail('写入 /etc/cron.d/os-mihomo 失败');
    }
    mihomo_setup_output(['result' => 'ok', 'cron_file' => true]);
    exit(0);
}

if (count($args) !== 4) {
    mihomo_setup_fail(
        '参数数量错误，用法：php mihomo_setup.php <url> <transport:transparent|proxy> '
        . '<auto_update:0|1> <interval:o6h|o12h|o24h>'
    );
}

list($url, $transport, $autoUpdateArg, $interval) = $args;

/* url 为空表示保持模型现有值；非空则先过与控制器完全一致的强校验 */
if ($url !== '') {
    $urlError = mihomo_setup_validate_url($url);
    if ($urlError !== '') {
        mihomo_setup_fail($urlError);
    }
}

if (!in_array($transport, ['transparent', 'proxy'], true)) {
    mihomo_setup_fail('transport 参数只能为 transparent 或 proxy');
}
if ($autoUpdateArg !== '0' && $autoUpdateArg !== '1') {
    mihomo_setup_fail('auto_update 参数只能为 0 或 1');
}
if (!in_array($interval, ['o6h', 'o12h', 'o24h'], true)) {
    mihomo_setup_fail('interval 参数只能为 o6h、o12h 或 o24h');
}

$autoUpdate = (int)$autoUpdateArg;
$effectiveUrl = '';

/* 写入 //OPNsense/mihomo：只经 MVC 模型与 Config 单例，不碰配置文件本身 */
try {
    $model = new Mihomo();
    if ($url !== '') {
        $model->subscription->url = $url;
    }
    $model->subscription->auto_update = ($autoUpdate === 1) ? '1' : '0';
    $model->subscription->auto_interval = $interval;
    $model->general->transport_mode = $transport;

    $model->serializeToConfig();
    if (Config::getInstance()->save() === false) {
        mihomo_setup_fail('模型配置写入失败（config.xml 可能被锁定）');
    }
    $effectiveUrl = (string)$model->subscription->url;
} catch (\Throwable $e) {
    mihomo_setup_fail('保存模型配置失败：' . $e->getMessage());
}

/* ------------------------------ 调度：/etc/cron.d ------------------------------ */

/**
 * 生成 /etc/cron.d/os-mihomo（调度唯一真源）。
 *
 * 设计依据（实施修订记录 0.b）：OPNsense 26.7 的 Cron 模型没有可编程的物化触发
 * 路径（system_cron_configure 只消费遗留 autocron），因此调度直接落在系统官方
 * 支持的 /etc/cron.d（生成 crontab 头注释明确认可）。模型里不再登记 cron 任务，
 * 避免将来物化后双重调度；模型旧任务在下方清理为禁用。
 */
function mihomo_setup_write_cron_d($autoUpdate, $interval)
{
    $hoursMap = ['o6h' => '*/6', 'o12h' => '*/12', 'o24h' => '0'];
    $hours = isset($hoursMap[$interval]) ? $hoursMap[$interval] : '0';

    $lines = [
        '# os-mihomo managed schedule — regenerated by mihomo_setup.php, do not edit',
    ];
    if ($autoUpdate === 1) {
        $lines[] = '0 ' . $hours . ' * * * root /usr/local/sbin/configctl mihomo sub-update >/dev/null 2>&1';
    }
    $lines[] = '*/1 * * * * root /usr/local/sbin/configctl mihomo watchdog >/dev/null 2>&1';

    $content = implode("\n", $lines) . "\n";
    $tmpFile = tempnam('/etc/cron.d', '.os-mihomo-');
    if ($tmpFile === false || dirname($tmpFile) !== '/etc/cron.d') {
        return false;
    }
    if (file_put_contents($tmpFile, $content) === false) {
        @unlink($tmpFile);
        return false;
    }
    chmod($tmpFile, 0644);
    if (!@rename($tmpFile, '/etc/cron.d/os-mihomo')) {
        @unlink($tmpFile);
        return false;
    }
    return true;
}

$cronFileOk = mihomo_setup_write_cron_d($autoUpdate, $interval);

/* 清理模型里的旧 cron 登记（1.0.5 早期版本写入过），统一禁用避免双重调度 */
try {
    $cron = new Cron();
    $cleaned = false;
    foreach ($cron->jobs->job->iterateItems() as $job) {
        $description = (string)$job->description;
        if ($description === MIHOMO_SETUP_CRON_SUB_DESCRIPTION || $description === MIHOMO_SETUP_CRON_WATCHDOG_DESCRIPTION) {
            if ((string)$job->enabled !== '0') {
                $job->enabled = '0';
                $cleaned = true;
            }
        }
    }
    if ($cleaned) {
        $cron->serializeToConfig();
        Config::getInstance()->save();
    }
} catch (\Throwable $e) {
    /* 清理失败不阻塞主流程：cron.d 已是真源 */
}

mihomo_setup_output([
    'result' => 'ok',
    'transport' => $transport,
    'cron_file' => $cronFileOk,
    'auto_update' => ($autoUpdate === 1),
    'url_masked' => ($effectiveUrl !== '') ? mihomo_setup_mask_url($effectiveUrl) : '',
]);
exit(0);
