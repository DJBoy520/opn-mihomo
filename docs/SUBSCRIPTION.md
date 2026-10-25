# Secure OPNsense Mihomo — 订阅管理与隐私保护设计 (Phase 9)

> 文档编号：SUBSCRIPTION-001  
> 状态：正式完成 (Phase 9)  
> 核心实现：`sub.sh` / `mihomo_sub` / `atomic_config_updater.sh`  

---

## 一、 订阅隐私保护与零第三方原则

在 Secure OPNsense Mihomo 架构中，**用户的订阅 URL（包含 Token 与节点资产信息）被视为最高安全级别的 Secret**。

```
+---------------------------------------------------------------------------------------+
|                              SUBSCRIPTION SECURITY MODEL                              |
+---------------------------------------------------------------------------------------+
|  1. 彻底删除第三方转换   | 杜绝调用 subconverters.com 等公网公共转换服务，防止 Token 泄露      |
|                         | 与节点劫持（MITM）。                                                 |
+-------------------------+-------------------------------------------------------------+
|  2. 原生直拉与自建适配  | 默认直接下载 Clash/Mihomo 标准 YAML 订阅；支持用户自建私有          |
|                         | 转换服务（通过 CUSTOM_SUBCONVERTER 环境变量配置）。                 |
+-------------------------+-------------------------------------------------------------+
|  3. 强制标准 TLS 校验   | 彻底移除 -k / --insecure / INSECURE_TLS 降级参数，强制校验证书。    |
+-------------------------+-------------------------------------------------------------+
|  4. 全链路脱敏输出      | 终端输出与日志中，URL 自动掩码 query token 参数；密钥显示脱敏。       |
+-------------------------+-------------------------------------------------------------+
|  5. 原子化配置更新集成  | 下载解析后统一经由 atomic_config_updater.sh 完成语法预检与原子覆盖。  |
+---------------------------------------------------------------------------------------+
```

---

## 二、 订阅更新流水线

```
  用户触发更新 (手动 / cron)
         │
         ▼
  [ 步骤 1: 读取 mihomo_URL 并进行 URL 安全校验 ]
         │
         ▼
  [ 步骤 2: 经由标准 HTTPS curl 拉取订阅配置 (严禁 -k) ]
         │ (支持 SOCKS5 本地 7891 代理回退下载)
         ▼
  [ 步骤 3: 提取 proxies 节点段；按策略来源合成 ]
         │   - subscription（默认）：同时提取 proxy-groups / rule-providers / sub-rules / rules，
         │     只替换模板策略层，保留端口/DNS/sniffer/secret/geodata 等基础设施
         │   - template：沿用 template_config.yaml 的固定策略组与规则
         ▼
  [ 步骤 4: 调用 atomic_config_updater.sh 执行 mihomo -t 验证 ]
         │
    (验证成功)
         ▼
  [ 步骤 5: 原子替换生产 config.yaml 并触发 Mihomo SIGHUP 热重载 ]
```

---

## 三、 策略来源（v1.1.0）

面板「订阅与策略 → 策略来源」提供两种模式：

| 值 | 含义 | 适用场景 |
| :--- | :--- | :--- |
| `subscription`（默认） | 沿用订阅自带的策略组与分流规则（代理模式/黑名单/白名单/全球拦截/地区组等），与 Windows/Clash 客户端一致 | 机场订阅自带完整分流模板 |
| `template` | 使用插件内置的「🌍选择节点 / 自动选择 / 负载均衡 / AI / Apple / 漏网之鱼」 | 订阅只有节点，或需要插件统一策略 |

合成规则：

1. 基础设施始终来自 `template_config.yaml`：端口、`external-controller`、`secret`、`allow-lan`、`bind-address`、DNS/fake-ip、sniffer、geodata、`tun: false`。
2. `subscription` 模式下，模板的 `proxy-groups:`、`rules:`（以及可能存在的 providers/sub-rules）被整块替换为订阅的对应块；`rule-providers`/`sub-rules`/`proxy-providers` 有则一并保留。
3. 自定义规则注入到 `rules:` 顶部；随后固定注入 `GEOSITE,private,DIRECT`，最后才是订阅规则。
4. 订阅缺少 `proxy-groups:` 或 `rules:` 时自动回退 `template`，状态消息写明原因；配置仍走 `mihomo -t` 预检，失败不覆盖生产配置。
5. 订阅策略片段缓存在 `/var/db/os-mihomo/subscription-strategy.yaml`（0600）；模式状态在 `/var/db/os-mihomo/strategy-mode`。`rules-recompose`（改自定义规则、轮换密钥、切换策略来源）优先使用该缓存，无需重新下载订阅。
6. `subscription` 模式下若尚无策略缓存，切换后请点「立即更新」；控制器的 message 会明确提示，不再误报“已合成”。

**35.7 万条规则的分页**：订阅实测 17.2MB / 357,229 条生效规则。插件「当前生效规则」不再调用 Clash API `/rules` 全量返回，而是 `/version` 探测后由 PHP 流式读取 `config.yaml` 的 `rules:` 块，支持 `limit` / `offset` / `q` 服务端搜索；前端每页 200 条并显示总数与窗口。

**已知限制**：订阅必须为块状 YAML 且带内联 `proxies:`；`proxy-providers` 型订阅、YAML 锚点/别名、FreeBSD 不支持的规则类型会被 `mihomo -t` 拦下并保持旧配置。恢复 `config.xml` 后建议重新保存一次订阅设置，以同步 `strategy-mode` 投影。
