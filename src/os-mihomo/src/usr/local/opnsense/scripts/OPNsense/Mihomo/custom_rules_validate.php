#!/usr/local/bin/php
<?php
/**
 * custom_rules_validate.php - 自定义分流规则逐行校验器（单一真源）
 *
 * 用法：
 *   php custom_rules_validate.php <rules_file>
 *   php custom_rules_validate.php --targets [rules_file]
 *
 * 设计：docs/DESIGN-panel-features-v2.md D3
 *   - 校验通过 exit 0，输出 {"valid":true,"errors":[]}
 *   - 校验失败 exit 1，输出 {"valid":false,"errors":[{"line":N,"message":"..."}]}
 *   - --targets 输出 {"targets":[...]} 并 exit 0
 *     目标集合 = 内置目标 ∪ 订阅模板 proxy-groups 中解析出的组名
 *
 * 文件级错误（总字节数/规则行数超限）没有具体行号，使用 line=0 表示。
 * 本脚本不依赖 OPNsense MVC 框架，控制器与 shell 均直接调用。
 */

const DEFAULT_TEMPLATE_FILE = '/usr/local/etc/mihomo/sub/template_config.yaml';
const DEFAULT_CONFIG_FILE = '/usr/local/etc/mihomo/config.yaml';
const MAX_RULES_BYTES = 32768;
const MAX_RULE_LINES = 200;

const RULE_TYPES = [
    'DOMAIN',
    'DOMAIN-SUFFIX',
    'DOMAIN-KEYWORD',
    'IP-CIDR',
    'IP-CIDR6',
    'GEOIP',
    'GEOSITE',
    'DST-PORT',
];

const BUILTIN_TARGETS = ['DIRECT', 'REJECT', 'REJECT-DROP'];

function usage_error(string $message): void
{
    fwrite(STDERR, $message . "\n");
    exit(64);
}

function output_json(array $payload): void
{
    $flags = JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES;
    if (defined('JSON_INVALID_UTF8_SUBSTITUTE')) {
        $flags |= JSON_INVALID_UTF8_SUBSTITUTE;
    }
    $json = json_encode($payload, $flags);
    if ($json === false) {
        $json = '{"valid":false,"errors":[{"line":0,"message":"JSON 编码失败"}]}';
    }
    echo $json . "\n";
}

function template_file(): string
{
    $override = getenv('MIHOMO_TEMPLATE_FILE');
    if (is_string($override) && $override !== '') {
        return $override;
    }
    return DEFAULT_TEMPLATE_FILE;
}

// 解析 YAML 简单标量：剥掉成对引号与行尾注释
function yaml_scalar(string $raw): string
{
    $value = trim($raw);
    if ($value === '') {
        return '';
    }
    $first = $value[0];
    if ($first === "'" || $first === '"') {
        if (preg_match('/^([\'"])(.*)\1[ \t]*(?:#.*)?$/u', $value, $matches) === 1) {
            return $matches[2];
        }
        return $value;
    }
    $comment = strpos($value, ' #');
    if ($comment !== false) {
        $value = rtrim(substr($value, 0, $comment));
    }
    return $value;
}

// 从指定 YAML 文件的顶层 proxy-groups 块收集组名（到下一个顶层键为止，流式读取）
function parse_proxy_group_names(string $file): array
{
    if (!is_file($file) || !is_readable($file)) {
        fwrite(STDERR, "错误：无法读取目标配置文件：{$file}\n");
        return [];
    }
    $handle = @fopen($file, 'r');
    if ($handle === false) {
        fwrite(STDERR, "错误：无法读取目标配置文件：{$file}\n");
        return [];
    }

    $inGroups = false;
    $names = [];
    while (($line = fgets($handle)) !== false) {
        $line = rtrim($line, "\r\n");
        if (!$inGroups) {
            if (preg_match('/^proxy-groups[ \t]*:/', $line) === 1) {
                $inGroups = true;
            }
            continue;
        }
        // 下一个顶层键结束 proxy-groups 块；顶层序列项（- name:）仍属于本块
        if ($line !== '' && preg_match('/^[^ \t#-]/', $line) === 1) {
            break;
        }
        if (preg_match('/^[ \t]*-[ \t]+name[ \t]*:[ \t]*(.*)$/', $line, $matches) === 1) {
            $name = yaml_scalar($matches[1]);
            if ($name !== '' && !in_array($name, $names, true)) {
                $names[] = $name;
            }
        }
    }
    fclose($handle);

    return $names;
}

function resolve_targets(): array
{
    $targets = BUILTIN_TARGETS;
    $names = [];

    $envTargets = getenv('MIHOMO_TARGETS_FILE');
    if (is_string($envTargets) && $envTargets !== '' && is_file($envTargets) && is_readable($envTargets)) {
        $names = parse_proxy_group_names($envTargets);
        if (count($names) === 0) {
            fwrite(STDERR, "提示：指定的目标文件未解析出代理组，回退模板\n");
            $names = parse_proxy_group_names(template_file());
        }
    } elseif (is_file(DEFAULT_CONFIG_FILE) && is_readable(DEFAULT_CONFIG_FILE)) {
        $names = parse_proxy_group_names(DEFAULT_CONFIG_FILE);
        if (count($names) === 0) {
            fwrite(STDERR, "提示：生效配置未解析出代理组，回退模板\n");
            $names = parse_proxy_group_names(template_file());
        }
    } else {
        $names = parse_proxy_group_names(template_file());
    }

    foreach ($names as $name) {
        if (!in_array($name, $targets, true)) {
            $targets[] = $name;
        }
    }
    return $targets;
}

function validate_cidr_payload(string $payload, bool $ipv6): bool
{
    $slash = strpos($payload, '/');
    if ($slash === false) {
        return false;
    }
    $address = substr($payload, 0, $slash);
    $mask = substr($payload, $slash + 1);
    if ($address === '' || $mask === '' || !ctype_digit($mask)) {
        return false;
    }
    $prefix = (int)$mask;
    if ($ipv6) {
        if ($prefix < 0 || $prefix > 128) {
            return false;
        }
        return filter_var($address, FILTER_VALIDATE_IP, ['flags' => FILTER_FLAG_IPV6]) !== false;
    }
    if ($prefix < 0 || $prefix > 32) {
        return false;
    }
    return filter_var($address, FILTER_VALIDATE_IP, ['flags' => FILTER_FLAG_IPV4]) !== false;
}

function validate_payload(string $type, string $payload): ?string
{
    switch ($type) {
        case 'DOMAIN':
        case 'DOMAIN-SUFFIX':
            $pattern = '/^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/';
            return preg_match($pattern, $payload) === 1 ? null : '域名格式无效';
        case 'DOMAIN-KEYWORD':
            $length = function_exists('mb_strlen') ? mb_strlen($payload, 'UTF-8') : strlen($payload);
            if ($length < 1 || $length > 100) {
                return '域名关键字长度应为 1 到 100';
            }
            if (strpos($payload, ',') !== false) {
                return '域名关键字不得包含逗号';
            }
            return null;
        case 'IP-CIDR':
            return validate_cidr_payload($payload, false) ? null : 'IPv4 CIDR 格式无效';
        case 'IP-CIDR6':
            return validate_cidr_payload($payload, true) ? null : 'IPv6 CIDR 格式无效';
        case 'GEOIP':
            return preg_match('/^[A-Za-z0-9]{1,16}$/', $payload) === 1 ? null : 'GEOIP 代码格式无效';
        case 'GEOSITE':
            return preg_match('/^[A-Za-z0-9_-]{1,64}$/', $payload) === 1 ? null : 'GEOSITE 名称格式无效';
        case 'DST-PORT':
            if (!ctype_digit($payload)) {
                return '端口应为 1 到 65535 的整数';
            }
            $port = (int)$payload;
            return ($port >= 1 && $port <= 65535) ? null : '端口应为 1 到 65535 的整数';
        default:
            return '不支持的规则类型：' . $type;
    }
}

function validate_rule_line(string $rawLine, array $targets): ?string
{
    $line = trim($rawLine);
    if ($line === '' || $line[0] === '#') {
        return null;
    }

    // 禁止字符与危险子串：在原始行上检查，制表符缩进同样拒绝
    if (strpbrk($rawLine, "'\"{}[]\t") !== false) {
        return '规则包含禁止字符（单引号、双引号、花括号、方括号或制表符）';
    }
    if (strpos($rawLine, ': ') !== false || strpos($rawLine, ' #') !== false) {
        return '规则包含禁止子串（": " 或 " #"）';
    }
    // 额外防线：C0 控制字符与 Unicode 行分隔符不得进入 YAML
    if (
        preg_match('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/', $rawLine) === 1 ||
        strpos($rawLine, "\xE2\x80\xA8") !== false ||
        strpos($rawLine, "\xE2\x80\xA9") !== false
    ) {
        return '规则包含控制字符或 Unicode 行分隔符';
    }

    $parts = explode(',', $line);
    $count = count($parts);
    if ($count !== 3 && $count !== 4) {
        return '规则必须为 3 或 4 个逗号分隔字段';
    }

    $type = $parts[0];
    if (!in_array($type, RULE_TYPES, true)) {
        return '不支持的规则类型：' . $type;
    }

    if ($count === 4) {
        if ($parts[3] !== 'no-resolve') {
            return '第 4 段只允许 no-resolve';
        }
        if ($type !== 'IP-CIDR' && $type !== 'IP-CIDR6' && $type !== 'GEOIP') {
            return 'no-resolve 仅允许用于 IP-CIDR、IP-CIDR6 或 GEOIP';
        }
    }

    $target = $parts[2];
    if (!in_array($target, $targets, true)) {
        return '目标不在允许集合：' . $target;
    }

    $payloadError = validate_payload($type, $parts[1]);
    if ($payloadError !== null) {
        return $payloadError;
    }

    return null;
}

$args = array_slice($argv, 1);
$targetsMode = false;
$positional = [];
foreach ($args as $arg) {
    if ($arg === '--targets') {
        $targetsMode = true;
    } elseif (substr($arg, 0, 2) === '--') {
        usage_error("错误：未知参数 {$arg}");
    } else {
        $positional[] = $arg;
    }
}

if ($targetsMode) {
    output_json(['targets' => resolve_targets()]);
    exit(0);
}

if (count($positional) !== 1) {
    usage_error('用法：php custom_rules_validate.php <rules_file> [--targets]');
}

$rulesFile = $positional[0];
if (!is_file($rulesFile) || !is_readable($rulesFile)) {
    output_json([
        'valid' => false,
        'errors' => [['line' => 0, 'message' => '规则文件不存在或无法读取']],
    ]);
    exit(1);
}

$size = filesize($rulesFile);
if ($size !== false && $size > MAX_RULES_BYTES) {
    output_json([
        'valid' => false,
        'errors' => [['line' => 0, 'message' => '规则文件超过 32768 字节上限']],
    ]);
    exit(1);
}

$content = file_get_contents($rulesFile);
if ($content === false) {
    output_json([
        'valid' => false,
        'errors' => [['line' => 0, 'message' => '规则文件读取失败']],
    ]);
    exit(1);
}

if (strlen($content) > MAX_RULES_BYTES) {
    output_json([
        'valid' => false,
        'errors' => [['line' => 0, 'message' => '规则文件超过 32768 字节上限']],
    ]);
    exit(1);
}

$targets = resolve_targets();
$lines = preg_split('/\r\n|\r|\n/', $content);
if ($lines === false) {
    $lines = [];
}

$errors = [];
$ruleCount = 0;
foreach ($lines as $index => $rawLine) {
    $lineNo = $index + 1;
    $trimmed = trim($rawLine);
    if ($trimmed === '' || $trimmed[0] === '#') {
        continue;
    }
    $ruleCount++;
    if ($ruleCount > MAX_RULE_LINES) {
        $errors[] = ['line' => $lineNo, 'message' => '规则行数超过 200 上限'];
        break;
    }
    $error = validate_rule_line($rawLine, $targets);
    if ($error !== null) {
        $errors[] = ['line' => $lineNo, 'message' => $error];
    }
}

if (count($errors) === 0) {
    output_json(['valid' => true, 'errors' => []]);
    exit(0);
}

output_json(['valid' => false, 'errors' => $errors]);
exit(1);
