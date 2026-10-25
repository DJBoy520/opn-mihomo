#!/usr/local/bin/php
<?php
/**
 * transport_render.php - D2 PF anchor 渲染器
 *
 * 用法：
 *   php transport_render.php [rules|lan-net|vars] [--template <path>]    # 默认 rules
 *
 * 数据来源优先级：
 *   环境变量覆盖（MIHOMO_LAN_IFACES / MIHOMO_LAN_NETS / MIHOMO_SELF_ADDRS /
 *   MIHOMO_GW_IP，空格分隔、按序对应） > /conf/config.xml 解析 > 报错 exit 1
 *
 * rules 模式读取 pf-transport.conf 模板（--template 指定或运行期 /usr/local/etc/mihomo/pf-transport.conf），
 * 替换 __MIHOMO_SELF_ADDRS__ / __MIHOMO_GW_IP__，并把 __MIHOMO_LAN_IF__ 注释占位替换为每个 LAN 接口一对
 * route-to 规则。模板中禁止出现以 block/reject 开头的规则行。
 *
 * 安全：所有进入 PF 规则的值（接口名、网段、地址）都经过白名单/IP 校验；
 * route-to 规则使用 "to ! <mihomo_bypass>"，不匹配的流量落回主规则集，
 * 不覆盖管理员策略。本脚本只读 /conf/config.xml，不写任何配置。
 */

// 模板查找顺序：CLI --template <path> 参数 > 运行期安装路径
const RUNTIME_PF_TEMPLATE = '/usr/local/etc/mihomo/pf-transport.conf';
const CONFIG_XML = '/conf/config.xml';
const DEFAULT_TUN_DEV = 'tun0';
const DEFAULT_TUN_GW = '10.0.0.1';

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

function env_value(string $name): ?string
{
    $value = getenv($name);
    if (!is_string($value)) {
        return null;
    }
    $value = trim($value);
    return $value === '' ? null : $value;
}

function split_words(string $value): array
{
    $parts = preg_split('/\s+/', trim($value));
    return $parts === false ? [] : $parts;
}

function is_valid_iface(string $value): bool
{
    return preg_match('/^[A-Za-z0-9_.-]{1,15}$/', $value) === 1;
}

function is_valid_ipv4(string $value): bool
{
    return filter_var($value, FILTER_VALIDATE_IP, ['flags' => FILTER_FLAG_IPV4]) !== false;
}

function ipv4_to_cidr(string $ip, int $prefix): ?string
{
    if (!is_valid_ipv4($ip) || $prefix < 0 || $prefix > 32) {
        return null;
    }
    $long = ip2long($ip);
    if ($long === false) {
        return null;
    }
    if ($prefix === 0) {
        $mask = 0;
    } else {
        $mask = (0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF;
    }
    $network = $long & $mask;
    return long2ip($network) . '/' . $prefix;
}

// config.xml 的 subnet 可能是前缀长度（24）或点分掩码（255.255.255.0）
function mask_to_prefix(string $mask): ?int
{
    $mask = trim($mask);
    if ($mask === '') {
        return 32;
    }
    if (ctype_digit($mask)) {
        $prefix = (int)$mask;
        return ($prefix >= 0 && $prefix <= 32) ? $prefix : null;
    }
    $long = ip2long($mask);
    if ($long === false) {
        return null;
    }
    $prefix = 0;
    $seenZero = false;
    for ($bit = 31; $bit >= 0; $bit--) {
        $current = ($long >> $bit) & 1;
        if ($current === 1) {
            if ($seenZero) {
                return null;
            }
            $prefix++;
        } else {
            $seenZero = true;
        }
    }
    return $prefix;
}

// 校验并归一化为网络地址 CIDR（例如 192.168.1.7/24 -> 192.168.1.0/24）
function canonical_cidr(string $cidr): ?string
{
    $cidr = trim($cidr);
    $slash = strpos($cidr, '/');
    if ($slash === false) {
        return null;
    }
    $ip = substr($cidr, 0, $slash);
    $mask = substr($cidr, $slash + 1);
    if ($mask === '' || !ctype_digit($mask)) {
        return null;
    }
    $prefix = (int)$mask;
    if ($prefix < 0 || $prefix > 32) {
        return null;
    }
    return ipv4_to_cidr($ip, $prefix);
}

function run_ifconfig(string $arguments): ?string
{
    $output = @shell_exec('/sbin/ifconfig ' . $arguments . ' 2>/dev/null');
    if (!is_string($output) || $output === '') {
        $output = @shell_exec('ifconfig ' . $arguments . ' 2>/dev/null');
    }
    return is_string($output) ? $output : null;
}

function ifconfig_inet(string $device): ?string
{
    $info = ifconfig_inet_info($device);
    return $info === null ? null : $info['ip'];
}

/**
 * 从 ifconfig 实时取 IPv4 地址与前缀长度（DHCP 或 config.xml 无 subnet 时使用）。
 * 返回 ['ip' => ..., 'prefix' => 0..32] 或 null。
 */
function ifconfig_inet_info(string $device): ?array
{
    if (!is_valid_iface($device)) {
        return null;
    }
    $output = run_ifconfig(escapeshellarg($device));
    if ($output === null) {
        return null;
    }
    if (preg_match('/^[ \t]*inet[ \t]+([0-9.]+)[ \t]+netmask[ \t]+(0x[0-9a-fA-F]+|[0-9.]+)/m', $output, $matches) === 1) {
        if (!is_valid_ipv4($matches[1])) {
            return null;
        }
        $prefix = 32;
        $maskText = $matches[2];
        if (preg_match('/^0x/i', $maskText) === 1) {
            $long = (int)hexdec(substr($maskText, 2));
            $prefix = 0;
            for ($bit = 31; $bit >= 0; $bit--) {
                if ((($long >> $bit) & 1) === 1) {
                    $prefix++;
                } else {
                    break;
                }
            }
        } elseif (strpos($maskText, '.') !== false) {
            $decoded = mask_to_prefix($maskText);
            $prefix = $decoded === null ? 32 : $decoded;
        }
        return ['ip' => $matches[1], 'prefix' => $prefix];
    }
    if (preg_match('/^[ \t]*inet[ \t]+([0-9.]+)/m', $output, $matches) === 1) {
        if (is_valid_ipv4($matches[1])) {
            return ['ip' => $matches[1], 'prefix' => 32];
        }
    }
    return null;
}

function collect_self_addrs(): array
{
    $output = run_ifconfig('');
    $addresses = [];
    if ($output !== null) {
        $count = preg_match_all('/^[ \t]*inet[ \t]+([0-9.]+)/m', $output, $matches);
        if ($count !== false && $count > 0) {
            foreach ($matches[1] as $address) {
                if (is_valid_ipv4($address)) {
                    $addresses[$address] = true;
                }
            }
        }
    }
    $addresses['127.0.0.1'] = true;
    return array_keys($addresses);
}

function resolve_gateway(): string
{
    $override = env_value('MIHOMO_GW_IP');
    if ($override !== null) {
        if (!is_valid_ipv4($override)) {
            fail('MIHOMO_GW_IP 不是合法的 IPv4 地址：' . $override);
        }
        return $override;
    }
    $output = @shell_exec('route -n get default 2>/dev/null');
    if (is_string($output) && preg_match('/^[ \t]*gateway:[ \t]+([0-9.]+)/m', $output, $matches) === 1) {
        if (is_valid_ipv4($matches[1])) {
            return $matches[1];
        }
    }
    return '';
}

function load_config_interfaces(): array
{
    if (!is_file(CONFIG_XML) || !is_readable(CONFIG_XML)) {
        fail('无法读取 ' . CONFIG_XML);
    }
    $xml = @simplexml_load_file(CONFIG_XML, 'SimpleXMLElement', LIBXML_NONET);
    if ($xml === false || !isset($xml->interfaces)) {
        fail('解析 ' . CONFIG_XML . ' 失败或缺少 interfaces 节点');
    }

    $result = [];
    foreach ($xml->interfaces->children() as $key => $interface) {
        $keyName = strtolower((string)$key);
        if ($keyName === 'wan') {
            continue;
        }
        if (!isset($interface->enable)) {
            continue;
        }
        $enabled = trim((string)$interface->enable);
        if ($enabled === '' || $enabled === '0') {
            continue;
        }

        $device = trim((string)$interface->{'if'});
        if ($device === '') {
            continue;
        }
        if (!is_valid_iface($device)) {
            fail('接口 ' . $keyName . ' 的设备名非法：' . $device);
        }
        if (preg_match('/^(lo|tun|pflog|pfsync|enc|gif|gre|stf|ovpn|wg|bridge|vlan)/', $device) === 1) {
            continue;
        }

        $ipaddr = trim((string)$interface->ipaddr);
        $isDhcp = strtolower($ipaddr) === 'dhcp';
        if ($isDhcp) {
            $resolved = ifconfig_inet_info($device);
            if ($resolved === null) {
                continue;
            }
            $ipaddr = $resolved['ip'];
        }
        if (!is_valid_ipv4($ipaddr)) {
            continue;
        }

        $subnet = trim((string)$interface->subnet);
        $prefix = $subnet === '' ? null : mask_to_prefix($subnet);
        if ($prefix === null || $isDhcp) {
            // DHCP 接口或配置缺 subnet：以 ifconfig 实时掩码为准，仍取不到才退 /32
            $live = ifconfig_inet_info($device);
            $prefix = $live === null ? 32 : $live['prefix'];
        }
        $cidr = ipv4_to_cidr($ipaddr, $prefix);
        if ($cidr === null) {
            continue;
        }
        $result[] = ['iface' => $device, 'net' => $cidr];
    }

    return $result;
}

function resolve_lan_pairs(): array
{
    $ifacesValue = env_value('MIHOMO_LAN_IFACES');
    $netsValue = env_value('MIHOMO_LAN_NETS');

    if ($ifacesValue !== null || $netsValue !== null) {
        if ($ifacesValue === null || $netsValue === null) {
            fail('MIHOMO_LAN_IFACES 与 MIHOMO_LAN_NETS 必须同时设置');
        }
        $ifaces = split_words($ifacesValue);
        $nets = split_words($netsValue);
        if (count($ifaces) !== count($nets)) {
            fail('MIHOMO_LAN_IFACES 与 MIHOMO_LAN_NETS 数量不一致');
        }
        $pairs = [];
        foreach ($ifaces as $index => $iface) {
            if (!is_valid_iface($iface)) {
                fail('非法的 LAN 接口名：' . $iface);
            }
            $cidr = canonical_cidr($nets[$index]);
            if ($cidr === null) {
                fail('非法的 LAN 网段：' . $nets[$index]);
            }
            $pairs[] = ['iface' => $iface, 'net' => $cidr];
        }
        if (count($pairs) === 0) {
            fail('没有可用的 LAN 接口');
        }
        return $pairs;
    }

    $pairs = load_config_interfaces();
    if (count($pairs) === 0) {
        fail('config.xml 中没有可用的 LAN 接口（需启用并配置 IPv4）');
    }
    return $pairs;
}

function resolve_self_addrs(): array
{
    $override = env_value('MIHOMO_SELF_ADDRS');
    if ($override !== null) {
        $addresses = [];
        foreach (split_words($override) as $address) {
            if (!is_valid_ipv4($address)) {
                fail('非法的本机地址：' . $address);
            }
            if (!in_array($address, $addresses, true)) {
                $addresses[] = $address;
            }
        }
        if (count($addresses) === 0) {
            fail('MIHOMO_SELF_ADDRS 为空');
        }
        return $addresses;
    }
    return collect_self_addrs();
}

function tun_device(): string
{
    $value = env_value('MIHOMO_TUN_DEV');
    if ($value === null) {
        $value = DEFAULT_TUN_DEV;
    }
    if (!is_valid_iface($value)) {
        fail('非法的 TUN 设备名：' . $value);
    }
    return $value;
}

function tun_gateway(): string
{
    $value = env_value('MIHOMO_TUN_GW');
    if ($value === null) {
        $value = DEFAULT_TUN_GW;
    }
    if (!is_valid_ipv4($value)) {
        fail('非法的 TUN 网关地址：' . $value);
    }
    return $value;
}

function resolve_template_path(?string $cliTemplate = null): string
{
    if ($cliTemplate !== null && $cliTemplate !== '') {
        if (!is_file($cliTemplate) || !is_readable($cliTemplate)) {
            fail('无法读取 PF 模板：' . $cliTemplate);
        }
        return $cliTemplate;
    }
    // 运行期安装路径
    if (is_file(RUNTIME_PF_TEMPLATE) && is_readable(RUNTIME_PF_TEMPLATE)) {
        return RUNTIME_PF_TEMPLATE;
    }
    fail('找不到 PF 模板：' . RUNTIME_PF_TEMPLATE);
}

function assert_safe_template(string $content): void
{
    $lines = preg_split('/\r\n|\r|\n/', $content);
    if ($lines === false) {
        $lines = [];
    }
    foreach ($lines as $line) {
        if (preg_match('/^[ \t]*(block|reject)\b/i', $line) === 1) {
            fail('PF 模板包含禁止的 block/reject 规则：' . trim($line));
        }
    }
    if (preg_match('/^[ \t]*table[ \t]+<mihomo_bypass>/m', $content) !== 1) {
        fail('PF 模板缺少 table <mihomo_bypass> 定义');
    }
    if (strpos($content, '__MIHOMO_LAN_IF__') === false) {
        fail('PF 模板缺少 __MIHOMO_LAN_IF__ 占位符');
    }
}

function render_rules(?string $cliTemplate = null): string
{
    $templateFile = resolve_template_path($cliTemplate);
    $content = file_get_contents($templateFile);
    if ($content === false) {
        fail('读取 PF 模板失败：' . $templateFile);
    }
    assert_safe_template($content);

    $pairs = resolve_lan_pairs();
    $selfAddrs = resolve_self_addrs();
    $gateway = resolve_gateway();
    $tunDev = tun_device();
    $tunGw = tun_gateway();

    $content = str_replace('__MIHOMO_SELF_ADDRS__', implode(' ', $selfAddrs), $content);
    if ($gateway !== '') {
        $content = str_replace('__MIHOMO_GW_IP__', $gateway, $content);
    } else {
        // 网关为空：连占位符前的空格一起剔除，不留空位
        $content = str_replace(' __MIHOMO_GW_IP__', '', $content);
        $content = str_replace('__MIHOMO_GW_IP__ ', '', $content);
        $content = str_replace('__MIHOMO_GW_IP__', '', $content);
    }

    $sourceLines = preg_split('/\r\n|\r|\n/', $content);
    if ($sourceLines === false) {
        $sourceLines = [];
    }

    $output = [];
    $inserted = false;
    foreach ($sourceLines as $line) {
        if (preg_match('/^[ \t]*#[ \t]*pass[ \t]+in[ \t]+quick[ \t]+on[ \t]+__MIHOMO_LAN_IF__/', $line) === 1) {
            if (!$inserted) {
                foreach ($pairs as $pair) {
                    $output[] = 'pass in quick on ' . $pair['iface']
                        . ' route-to (' . $tunDev . ' ' . $tunGw . ')'
                        . ' inet proto tcp from ' . $pair['net']
                        . ' to ! <mihomo_bypass> flags S/SA keep state';
                    $output[] = 'pass in quick on ' . $pair['iface']
                        . ' route-to (' . $tunDev . ' ' . $tunGw . ')'
                        . ' inet proto udp from ' . $pair['net']
                        . ' to ! <mihomo_bypass> keep state';
                }
                $inserted = true;
            }
            continue;
        }
        $output[] = $line;
    }
    if (!$inserted) {
        fail('PF 模板缺少 LAN 规则占位注释');
    }

    return implode("\n", $output);
}

$mode = 'rules';
$cliTemplate = null;

$args = array_slice($argv, 1);
while (count($args) > 0) {
    $arg = array_shift($args);
    if ($arg === '--template') {
        if (count($args) === 0) {
            usage_error('用法：php transport_render.php [rules|lan-net|vars] [--template <path>]');
        }
        $cliTemplate = array_shift($args);
    } elseif (in_array($arg, ['rules', 'lan-net', 'vars'], true)) {
        $mode = $arg;
    } else {
        usage_error('用法：php transport_render.php [rules|lan-net|vars] [--template <path>]');
    }
}

if ($mode === 'rules') {
    $output = render_rules($cliTemplate);
    if (substr($output, -1) !== "\n") {
        $output .= "\n";
    }
    echo $output;
    exit(0);
}

if ($mode === 'lan-net') {
    $pairs = resolve_lan_pairs();
    echo $pairs[0]['net'] . "\n";
    exit(0);
}

// vars 模式：输出三行 shell 可 eval 的赋值
$pairs = resolve_lan_pairs();
$selfAddrs = resolve_self_addrs();
$ifaces = [];
$nets = [];
foreach ($pairs as $pair) {
    $ifaces[] = $pair['iface'];
    $nets[] = $pair['net'];
}
echo 'MIHOMO_LAN_IFACES=' . escapeshellarg(implode(' ', $ifaces)) . "\n";
echo 'MIHOMO_LAN_NETS=' . escapeshellarg(implode(' ', $nets)) . "\n";
echo 'MIHOMO_SELF_ADDRS=' . escapeshellarg(implode(' ', $selfAddrs)) . "\n";
exit(0);
