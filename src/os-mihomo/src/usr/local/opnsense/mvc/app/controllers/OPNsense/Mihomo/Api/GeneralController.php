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

use OPNsense\Base\ApiMutableModelControllerBase;
use OPNsense\Core\Backend;
use OPNsense\Core\Config;
use OPNsense\Mihomo\Mihomo;

class GeneralController extends ApiMutableModelControllerBase
{
    protected static $internalModelClass = '\OPNsense\Mihomo\Mihomo';
    protected static $internalModelName = 'mihomo';

    const DEFAULT_API_BIND = '127.0.0.1';
    const DEFAULT_API_PORT = '9090';

    /**
     * 覆盖基类 getModelNodes，只暴露 general 子树，避免订阅 URL 等敏感信息被 General 子权限读取
     */
    protected function getModelNodes()
    {
        $nodes = $this->getModel()->getNodes();
        return [
            'general' => isset($nodes['general']) ? $nodes['general'] : []
        ];
    }

    /**
     * 读取系统实际占用的端口（WebGUI 端口与 SSH 端口），用于端口 deny-list
     */
    private function getSystemPorts()
    {
        $ports = [22];
        $config = null;
        try {
            $config = Config::getInstance()->object();
        } catch (\Exception $e) {
            $config = null;
        }
        if ($config === null && file_exists('/conf/config.xml')) {
            $config = @simplexml_load_file('/conf/config.xml');
        }

        if ($config !== null && isset($config->system)) {
            // SSH 端口（默认为 22）
            if (isset($config->system->ssh) && isset($config->system->ssh->port)) {
                $sshPort = trim((string)$config->system->ssh->port);
                if ($sshPort !== '' && ctype_digit($sshPort)) {
                    $ports = [(int)$sshPort];
                }
            }
            // WebGUI 端口（空则按 protocol 80/443）
            if (isset($config->system->webgui)) {
                $wg = $config->system->webgui;
                $wgPort = isset($wg->port) ? trim((string)$wg->port) : '';
                if ($wgPort !== '' && ctype_digit($wgPort)) {
                    $ports[] = (int)$wgPort;
                } else {
                    $proto = isset($wg->protocol) ? trim((string)$wg->protocol) : 'https';
                    $ports[] = ($proto === 'http') ? 80 : 443;
                }
            } else {
                $ports[] = 443;
            }
        } else {
            $ports[] = 443;
        }
        return array_values(array_unique($ports));
    }

    /**
     * 直接读取 /usr/local/etc/mihomo/config.yaml 中生效的 ^secret: 实际值
     * 遵循 mihomo 核心实际行为：只认 config.yaml，不认 secret.key。空值或缺失返回空字符串。
     */
    private function getConfigSecret()
    {
        $configFile = '/usr/local/etc/mihomo/config.yaml';
        if (!is_file($configFile) || !is_readable($configFile)) {
            return '';
        }
        $lines = @file($configFile, FILE_IGNORE_NEW_LINES);
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
                $parts = explode('#', $raw, 2);
                return trim($parts[0], " \t\n\r\0\x0B\"'");
            }
        }
        return '';
    }

    /**
     * 覆盖基类 setAction，只接收并更新 mihomo.general 子树，防止跨节点篡改
     */
    public function setAction()
    {
        $result = ['result' => 'failed'];
        if ($this->request->isPost()) {
            $postData = $this->request->getPost(static::$internalModelName);
            if (!is_array($postData) || !isset($postData['general']) || !is_array($postData['general'])) {
                return $result;
            }

            $general = $postData['general'];

            // 1. filter_var(FILTER_VALIDATE_IP) 复核 bind
            if (isset($general['api_bind'])) {
                $bind = trim((string)$general['api_bind']);
                if ($bind === '' || filter_var($bind, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false) {
                    return [
                        'result' => 'failed',
                        'message' => 'API 绑定地址无效，必须为合法的 IPv4 单地址（如 127.0.0.1、0.0.0.0 或本机接口 IP）',
                        'validations' => [
                            'mihomo.general.api_bind' => '请输入合法的 IPv4 单地址',
                        ],
                    ];
                }

                // 3. bind != self::DEFAULT_API_BIND 时：解析 /usr/local/etc/mihomo/config.yaml 的 ^secret: 实际值
                if ($bind !== self::DEFAULT_API_BIND) {
                    $activeSecret = $this->getConfigSecret();
                    if ($activeSecret === '') {
                        return [
                            'result' => 'failed',
                            'message' => '绑定非回环地址前必须先配置有效的 API 密钥（mihomo 仅认 config.yaml 中的实际生效 secret）',
                            'validations' => [
                                'mihomo.general.api_bind' => '请先在下方配置并保存 API 密钥后再绑定非回环地址',
                            ],
                        ];
                    }
                }
            }

            // 2. port int 1024-65535 且不在 {1053,7890,7891}，且不等于系统 WebGUI 端口与 SSH 端口
            if (isset($general['api_port'])) {
                $portRaw = trim((string)$general['api_port']);
                if ($portRaw === '' || !ctype_digit($portRaw)) {
                    return [
                        'result' => 'failed',
                        'message' => 'API 端口必须为数字',
                        'validations' => [
                            'mihomo.general.api_port' => '请输入合法的端口号（1024-65535）',
                        ],
                    ];
                }
                $port = (int)$portRaw;
                if ($port < 1024 || $port > 65535) {
                    return [
                        'result' => 'failed',
                        'message' => 'API 端口超出合法范围（1024-65535）',
                        'validations' => [
                            'mihomo.general.api_port' => 'API 端口必须在 1024 到 65535 之间',
                        ],
                    ];
                }

                $denyPorts = [1053, 7890, 7891];
                $systemPorts = $this->getSystemPorts();
                $allDeny = array_merge($denyPorts, $systemPorts);
                if (in_array($port, $allDeny, true)) {
                    return [
                        'result' => 'failed',
                        'message' => "API 端口 {$port} 不可用：保留端口、插件内部端口（1053/7890/7891）或系统端口（WebGUI/SSH）已被占用",
                        'validations' => [
                            'mihomo.general.api_port' => "端口 {$port} 为受保护或已占用的系统端口，请更换其他端口",
                        ],
                    ];
                }
            }

            Config::getInstance()->lock();
            $mdl = $this->getModel();
            $mdl->setNodes(['general' => $postData['general']]);
            $result = $this->validate();
            if (empty($result['result'])) {
                $this->setActionHook();
                return $this->save(false, true);
            }
        }
        return $result;
    }

    public function getGeneralAction()
    {
        /* 26.7 基类读走 getAction()（现通过 getModelNodes 只返回 general 子树） */
        $result = $this->getAction();
        $backend = new Backend();
        $maskedSecret = trim((string)$backend->configdRun('mihomo secret-masked'));
        if (empty($maskedSecret)) {
            $maskedSecret = 'NOT_CONFIGURED';
        }

        $targetKey = isset($result['mihomo']['general']) ? 'mihomo' : 'general';
        if ($targetKey === 'mihomo') {
            $gen = &$result['mihomo']['general'];
        } else {
            $gen = &$result['general'];
        }

        $gen['secret_masked'] = $maskedSecret;

        // 提取并归一化展示用探测地址
        $bind = isset($gen['api_bind']) ? (string)$gen['api_bind'] : self::DEFAULT_API_BIND;
        $port = isset($gen['api_port']) ? (string)$gen['api_port'] : self::DEFAULT_API_PORT;
        if ($bind === '') {
            $bind = self::DEFAULT_API_BIND;
        }
        if ($port === '') {
            $port = self::DEFAULT_API_PORT;
        }

        $probeBind = ($bind === '0.0.0.0') ? self::DEFAULT_API_BIND : $bind;
        $gen['probe_bind'] = $probeBind;
        $gen['probe_port'] = $port;
        $gen['probe_addr'] = $probeBind . ':' . $port;
        $gen['api_addr'] = $bind . ':' . $port;

        return $result;
    }

    public function setGeneralAction()
    {
        if (!$this->request->isPost()) {
            return ['result' => 'failed', 'status' => 'failed', 'message' => '仅接受 POST 请求'];
        }

        // 先快照旧值：后续动作只按“实际变化”分发；同时供 apply 失败时整棵 general 回滚使用
        $model = $this->getModel();
        $oldNodes = $model->getNodes();
        $oldGeneral = (isset($oldNodes['general']) && is_array($oldNodes['general']))
            ? $oldNodes['general']
            : [];
        $old = [
            'api_bind' => (string)$model->general->api_bind,
            'api_port' => (string)$model->general->api_port,
            'transport_mode' => (string)$model->general->transport_mode,
            'lan_expose' => (string)$model->general->lan_expose,
            'lan_user' => (string)$model->general->lan_user,
            'enabled' => (string)$model->general->enabled,
        ];
        if ($old['api_bind'] === '') {
            $old['api_bind'] = self::DEFAULT_API_BIND;
        }
        if ($old['api_port'] === '') {
            $old['api_port'] = self::DEFAULT_API_PORT;
        }

        try {
            /* 26.7 基类标准保存：构造模型→校验→setActionHook→落盘（已包含 setAction 内前置门禁） */
            $saveResult = $this->setAction();
        } catch (\Exception $e) {
            return ['result' => 'failed', 'status' => 'failed', 'message' => '保存设置失败: ' . $e->getMessage()];
        }
        if (!isset($saveResult['result']) || $saveResult['result'] !== 'saved') {
            return [
                'result' => 'failed',
                'status' => 'failed',
                'message' => isset($saveResult['message']) ? $saveResult['message'] : '保存设置失败',
                'validations' => isset($saveResult['validations']) ? $saveResult['validations'] : [],
            ];
        }

        // 重新加载模型，以配置文件中的新值为准
        $model = new Mihomo();
        $new = [
            'api_bind' => (string)$model->general->api_bind,
            'api_port' => (string)$model->general->api_port,
            'transport_mode' => (string)$model->general->transport_mode,
            'lan_expose' => (string)$model->general->lan_expose,
            'lan_user' => (string)$model->general->lan_user,
            'enabled' => (string)$model->general->enabled,
        ];
        if ($new['api_bind'] === '') {
            $new['api_bind'] = self::DEFAULT_API_BIND;
        }
        if ($new['api_port'] === '') {
            $new['api_port'] = self::DEFAULT_API_PORT;
        }

        $messages = [];
        $backend = new Backend();

        // 0) apply-then-persist：调用 configd 执行 api-bind-apply
        $applyOutput = trim((string)$backend->configdpRun('mihomo api-bind-apply', [
            $new['api_bind'],
            $new['api_port'],
        ]));

        // apply 失败 → 整棵 general 回滚 + 跳过 enabled=1 的 restart + 返回 failed 并附 stdout 摘要
        // 只回滚 api_bind/api_port 会把 transport_mode 等新值留在 config.xml：重试保存时
        // 前后模型相同，transport-enable/disable 永不触发，透明层因此永久不挂载。
        if (stripos($applyOutput, 'OK: api bind') === false) {
            try {
                Config::getInstance()->lock();
                $rollbackMdl = $this->getModel();
                $rollbackGeneral = !empty($oldGeneral) ? $oldGeneral : $old;
                $rollbackMdl->setNodes(['general' => $rollbackGeneral]);
                $this->save(false, true);
            } catch (\Exception $e) {
                // 容错处理
            }

            $summary = ($applyOutput !== '') ? $applyOutput : '未收到服务响应';
            return [
                'result' => 'failed',
                'status' => 'failed',
                'message' => '应用 API 绑定失败，配置已自动回滚: ' . $summary,
            ];
        }

        $messages[] = 'api-bind-apply: ' . $applyOutput;

        // 1) LAN 暴露与 API 绑定状态文件：写入 panel-state.env
        if (!preg_match('/^[A-Za-z0-9_.@-]{1,32}$/', $new['lan_user'])) {
            $new['lan_user'] = 'mihomo';
        }
        $messages[] = $this->writePanelState(
            $new['lan_expose'],
            $new['lan_user'],
            $new['api_bind'],
            $new['api_port']
        );

        // 2) 传输模式切换（先 filter reload 再挂 anchor；关闭时反过来，避免规则引用悬空）
        // 运行态与模型双条件：config.xml 可能已落盘新值（例如 apply 失败回滚不完整），
        // 只比较前后模型会漏掉 enable/disable，导致重试时透明层永不挂载。
        $transportNeedsApply = ($old['transport_mode'] !== $new['transport_mode']);
        $runtimeTransportMode = $this->readTransportMode($backend);
        if (!$transportNeedsApply && $runtimeTransportMode !== '') {
            $transportNeedsApply = ($runtimeTransportMode !== $new['transport_mode']);
        }
        if ($transportNeedsApply) {
            if ($new['transport_mode'] === 'transparent') {
                $messages[] = $this->runConfigd($backend, 'filter reload');
                $messages[] = $this->runConfigd($backend, 'mihomo transport-enable');
            } else {
                $messages[] = $this->runConfigd($backend, 'mihomo transport-disable');
                $messages[] = $this->runConfigd($backend, 'filter reload');
            }
        }

        // 3) LAN 暴露参数变化：按订阅缓存重组配置（绑定地址/认证用户来自模板）
        if ($old['lan_expose'] !== $new['lan_expose'] || $old['lan_user'] !== $new['lan_user']) {
            $messages[] = $this->runConfigd($backend, 'mihomo rules-recompose');
        }

        // 4) 服务启停（保留“保存即让 enabled 生效”的原语义）
        if ($new['enabled'] === '1') {
            $messages[] = $this->runConfigd($backend, 'mihomo restart');
        } elseif ($old['enabled'] !== '0') {
            $messages[] = $this->runConfigd($backend, 'mihomo stop');
        }

        return ['result' => 'saved', 'status' => 'ok', 'messages' => $messages];
    }

    /**
     * 读取运行态传输模式（transport-status 的 Mode 行）；无法判定时返回空串。
     * 与模型前后值共同判定切换：落盘值与运行态不一致时仍要执行 enable/disable。
     */
    private function readTransportMode($backend)
    {
        $output = (string)$backend->configdRun('mihomo transport-status');
        if (preg_match('/^Mode:[ \t]*([A-Za-z0-9_-]+)/m', $output, $matches)) {
            $mode = trim($matches[1]);
            if ($mode === 'proxy' || $mode === 'transparent') {
                return $mode;
            }
        }
        return '';
    }

    /**
     * 写 /var/db/os-mihomo/panel-state.env（同目录 tmp + rename，0600）
     * 扩展记录 MIHOMO_API_BIND 与 MIHOMO_API_PORT，值已过白名单与格式校验。
     */
    private function writePanelState($lanExpose, $lanUser, $apiBind = self::DEFAULT_API_BIND, $apiPort = self::DEFAULT_API_PORT)
    {
        $stateFile = '/var/db/os-mihomo/panel-state.env';
        $stateDir = dirname($stateFile);
        if (!is_dir($stateDir)) {
            @mkdir($stateDir, 0750, true);
        }

        $tmpFile = tempnam($stateDir, '.panel-state.');
        if ($tmpFile === false) {
            return '写入面板状态失败: 无法在 ' . $stateDir . ' 创建临时文件';
        }
        // tempnam 在目标目录不可写时会退回到系统临时目录，必须同目录才能保证原子 rename
        if (dirname($tmpFile) !== $stateDir) {
            @unlink($tmpFile);
            return '写入面板状态失败: 目标目录不可写 ' . $stateDir;
        }

        chmod($tmpFile, 0600);
        $content = "MIHOMO_LAN_EXPOSE='" . ($lanExpose === '1' ? '1' : '0') . "'\n"
            . "MIHOMO_LAN_USER='" . $lanUser . "'\n"
            . "MIHOMO_API_BIND='" . $apiBind . "'\n"
            . "MIHOMO_API_PORT='" . $apiPort . "'\n";
        if (file_put_contents($tmpFile, $content, LOCK_EX) === false || !@rename($tmpFile, $stateFile)) {
            @unlink($tmpFile);
            return '写入面板状态失败: ' . $stateFile;
        }
        chmod($stateFile, 0600);
        return '面板状态已写入 ' . $stateFile;
    }

    /**
     * 执行 configd 动作并把结果带回消息数组（失败不中断后续动作）
     */
    private function runConfigd($backend, $command)
    {
        $output = $backend->configdRun($command);
        $text = is_string($output) ? trim($output) : '';
        if ($text === '') {
            return $command . ': 无输出（请核对服务日志）';
        }
        return $command . ': ' . $text;
    }

    /**
     * 刷新并热加载 mihomo 配置，确保 config.yaml 内的 secret 与 authentication 同步更新
     * 订阅缓存存在时先 recompose（重写 config.yaml），再显式 reload 确保生效
     */
    private function applySecretReload($backend)
    {
        $cacheFile = '/var/db/os-mihomo/subscription-cache.yaml';
        if (is_file($cacheFile) && filesize($cacheFile) > 0) {
            $recomposeOutput = trim((string)$backend->configdpRun('mihomo rules-recompose'));
            if (stripos($recomposeOutput, 'OK') === false) {
                return 'recompose failed: ' . ($recomposeOutput !== '' ? $recomposeOutput : '未收到合成响应');
            }
        }
        $reloadOutput = trim((string)$backend->configdRun('mihomo reload'));
        if ($this->isReloadSuccess($reloadOutput)) {
            /* hev.yaml 仍持有旧凭证：同步失败只记 warning，不阻断已生效的密钥轮换响应。
               transport_manager.sh hev-sync 成功输出不含 OK（「未运行」也是成功），按错误标记判定。 */
            try {
                $syncOutput = trim((string)$backend->configdpRun('mihomo hev-sync'));
                if ($syncOutput !== '' &&
                    (stripos($syncOutput, '错误') !== false || stripos($syncOutput, 'error') !== false)) {
                    syslog(LOG_WARNING, 'mihomo hev-sync failed after secret reload: ' . $syncOutput);
                }
            } catch (\Throwable $e) {
                syslog(LOG_WARNING, 'mihomo hev-sync failed after secret reload: ' . $e->getMessage());
            }
        }
        return $reloadOutput;
    }

    /**
     * 判断 reload 输出是否代表服务成功加载或启动
     */
    private function isReloadSuccess($output)
    {
        return stripos($output, 'SIGHUP') !== false ||
               stripos($output, 'Mihomo started successfully') !== false;
    }

    /**
     * 返回面板登录用的完整密钥（external-controller）
     * 仅 page-services-mihomo* ACL 可达；与订阅 URL 不同，密钥必须能被
     * 管理员查看/复制，否则无法登录内置面板。
     * M7: 仅接受 POST 请求，受 CSRF 保护
     */
    public function secretRevealAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => '仅接受 POST 请求'];
        }
        $secret = trim((string)(new Backend())->configdRun('mihomo secret-get'));
        if ($secret === '') {
            return ['status' => 'failed', 'message' => '尚未配置 API 密钥'];
        }
        return ['status' => 'ok', 'secret' => $secret];
    }

    /**
     * 设置自定义密钥（b64 经 configd 传给 secret_manager.sh set），并热加载生效
     */
    public function secretSetAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => '仅接受 POST 请求'];
        }

        $rawSecret = $this->request->getPost('secret');
        $nested = $this->request->getPost('mihomo');
        if (($rawSecret === '' || $rawSecret === null) && is_array($nested) && isset($nested['secret'])) {
            $rawSecret = $nested['secret'];
        }
        if (!is_string($rawSecret)) {
            return ['status' => 'failed', 'message' => '密钥格式无效，必须为字符串'];
        }
        $secret = trim($rawSecret);

        $length = strlen($secret);
        if ($length < 4 || $length > 128) {
            return ['status' => 'failed', 'message' => '密钥长度需在 4~128 个字符之间'];
        }
        if (preg_match('/\A[A-Za-z0-9._~@#%^+=:;,!?*-]+\z/', $secret) !== 1) {
            return [
                'status' => 'failed',
                'message' => '密钥仅允许字母数字与 . _ ~ @ # % ^ + = : ; , ! ? * -'
            ];
        }

        $backend = new Backend();
        $output = (string)$backend->configdpRun(
            'mihomo secret-set',
            ['b64:' . base64_encode($secret)]
        );
        if (stripos($output, 'OK') === false) {
            return ['status' => 'failed', 'message' => '写入密钥失败: ' . trim($output)];
        }

        // 订阅缓存存在时 recompose 再 reload；否则直接 reload。校验重载输出
        $reloadOutput = $this->applySecretReload($backend);
        if (!$this->isReloadSuccess($reloadOutput)) {
            return [
                'status' => 'failed',
                'message' => '密钥已写入，但热重载失败（旧配置仍在运行）: ' . ($reloadOutput !== '' ? $reloadOutput : '未收到服务响应')
            ];
        }
        $masked = trim((string)$backend->configdRun('mihomo secret-masked'));

        return [
            'status' => 'ok',
            'message' => 'API 密钥已更新' . ($reloadOutput !== '' ? '（' . $reloadOutput . '）' : ''),
            'secret_masked' => $masked !== '' ? $masked : 'CONFIGURED',
        ];
    }

    public function regenerateSecretAction()
    {
        if ($this->request->isPost()) {
            $backend = new Backend();
            $genOutput = trim((string)$backend->configdRun('mihomo secret-generate'));
            if (stripos($genOutput, 'OK') === false) {
                return ['status' => 'failed', 'message' => '生成密钥失败: ' . $genOutput];
            }
            $reloadOutput = $this->applySecretReload($backend);
            if (!$this->isReloadSuccess($reloadOutput)) {
                return [
                    'status' => 'failed',
                    'message' => '新密钥已生成，但热重载失败（旧配置仍在运行）: ' . ($reloadOutput !== '' ? $reloadOutput : '未收到服务响应')
                ];
            }
            $maskedSecret = trim((string)$backend->configdRun('mihomo secret-masked'));
            return [
                'status' => 'ok',
                'message' => $genOutput . ($reloadOutput !== '' ? '；已热加载 mihomo' : ''),
                /* 新密钥仅在本次响应中完整返回一次，供面板立即复制登录 */
                'secret' => trim((string)$backend->configdRun('mihomo secret-get')),
                'secret_masked' => $maskedSecret ?: 'CONFIGURED'
            ];
        }
        return ['status' => 'failed', 'message' => 'Invalid request method'];
    }
}
