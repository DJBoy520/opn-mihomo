# os-mihomo 面板化增强设计方案（F1~F4 · 交 Gemini/DeepSeek 审核版）

> 设计：主控会话。实施：后续会话（内部交接文档不随公开仓库分发）。
> 基线：secure-mihomo 分支 + os-mihomo 1.0.4（内核 v1.19.30，已全量验证）。
> 最高约束：不得破坏现有已验证行为（socks 核心、原子订阅更新、fail-open）；生产上不碰 config.xml/Unbound/PF 主规则集（透明代理开关是本设计唯一需要动 PF 的功能，见 F2 的隔离方案）。

## F1 面板更新订阅

**模型**（Mihomo.xml 新增 `<subscription>` 段）：
- `url`（TextField，面板显示脱敏：保存后仅展示 `scheme://host/***`）
- `auto_update`（BooleanField，默认 0）
- `auto_interval`（OptionField：6/12/24/48 小时，默认 24）

**API**（`Api/SubscriptionController.php`，继承 ApiControllerBase）：
- `getAction`：返回模型（URL 脱敏）+ 最近一次更新结果（/var/db/os-mihomo/last-sub-update.json：时间/节点数/成功与否）
- `setAction`：POST 保存模型 → 通过 configd 动作 `mihomo sub-env-write` 落盘（见下），**禁止在 PHP 里直接拼接 shell 命令写 env**
- `updateAction`：POST → `configdRun('mihomo sub-update')`，返回完整脱敏输出；configd 调用需容忍长耗时（17MB 订阅 ~60s）

**configd 动作**（actions_mihomo.conf 新增）：
- `sub-env-write`：`/usr/local/opnsense/scripts/OPNsense/Mihomo/sub_env_write.php`——从 MVC 模型读 url/interval（PHP DOM 读 config.xml 模型挂载点，与 secret_manager 同风格），写 `/usr/local/etc/mihomo/sub/env`（0600，printf 单引号包裹），并增删 OPNsense Cron 项（auto_update 开时注册每日 `configctl mihomo sub-update`，关时移除；Cron 项用固定 description `os-mihomo auto sub-update` 便于幂等识别）
- 现有 `sub-update` 保持不变

**View**：General 页新增"订阅"表单区（url 输入框 + 自动更新开关 + 间隔下拉 + 【立即更新】按钮 + 最近更新结果展示区）。

## F2 透明代理开关（关闭 = 普通代理）

**模型**：`general.transport`（OptionField：`none`（普通代理，默认）/ `transparent`（透明代理））。

**语义**：
- `none`：仅 socks 7891 + mixed 7890（新增 mixed-port 7890 于模板，HTTP 代理可直填浏览器）+ DNS 1053。客户端手动配代理。hev 不运行、PF 无 mihomo 规则。
- `transparent`：在 `none` 之上启动 hev 隧道（上游 127.0.0.1:7891）并装载 PF route-to 规则，使"网关/DNS 指向本机"的设备无感走代理。

**实现核心**：新脚本 `transport_manager.sh`（configd 动作 `mihomo transport-enable|disable|status`）：
- `enable`：①确认 hev 二进制与配置（`/usr/local/etc/mihomo/transport/hev.yml`，tun0 10.0.0.2/30 → socks5 127.0.0.1:7891）②`kldload if_tun`（幂等）③启动 hev（`daemon -f -p /var/run/mihomo-hev.pid`；**hev 的配置是位置参数，没有 -c**；stop 需 pkill 兜底——pidfile 不可信）④装载 PF：dump `pfctl -sr` → 若无 `anchor "mihomo-transport" on <IF>` 引用则插入（IF 从 `configctl interface list` 或 config.xml lan 取）→ `pfctl -a mihomo-transport -f` 规则文件（首条 bypass 到本机自身，防 SSH 锁死；bypass RFC1918 可选参数）⑤验证 tun0 UP + anchor 引用在 + 本机服务存活，任一失败自动 disable 回滚
- `disable`：flush anchor 内容 + 从主规则集移除引用行（重载）+ pkill hev + 删 tun0
- **持久性自愈**：`configctl filter reload` 会重生成主规则集并丢掉 anchor 引用。对策三层：① `mihomo.inc` 的 newwanip 钩子追加 transport re-enable；② watchdog 巡检时若 transport=transparent 但主规则集无引用/tun0 消失 → 自动 re-enable；③ 文档明示"修改防火墙规则后如断流，重开一次开关"
- **DNS 提示**：transparent 模式生效还需客户端 DNS 可用（fake-ip 需 DNS 指向 1053，或无 fake-ip 靠嗅探）。插件在 status API 里返回 `dns_ready` 提示位，面板显示引导文案（生产上指向 AGH→1053 的既有链路），**不自动改 Unbound/AGH**（保持零侵入原则）

**View**：General 页新增"传输模式"单选（普通代理/透明代理）+ 状态徽章（tun0、anchor 引用、hev 进程三态）。

**安全边界**：transparent 开启=改变本机 PF 行为，enable 失败自动回滚 + 全程不触碰 WAN 方向规则；本设计不含 DNS 劫持（客户端 DNS 仍指向网关既有服务）。

## F3 持久自定义分流规则

**存储**：`/usr/local/etc/mihomo/custom-rules.txt`（0600，每行一条，`#` 注释），**不放进 config.yaml 也不放进订阅模板**——这是"订阅更新不消失"的根基。

**格式校验**（写入时强校验，防 YAML 注入）：
```
^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|GEOIP|GEOSITE|SRC-IP-CIDR|DST-PORT|PROCESS-NAME),(?=DIRECT|REJECT|🚫|国外|...)[^,']+...$
```
具体实现：类型白名单 + 目标必须是 `DIRECT|REJECT|REJECT-DROP|PASS` 或当前 config.yaml 里真实存在的策略组名（从模板解析）；行内禁止出现 `'`、`{`、`}`、`[`、换行，避免破坏 YAML 结构。

**注入点**：`sub.sh` 合成阶段——在模板展开后的临时配置里，把自定义规则插到 `rules:` 段**最顶部**（最高优先级）；随后 `mihomo -t` 校验（坏规则会在校验步被拦，生产配置不动——复用既有原子防线）。

**免联网应用**：`sub.sh` 新增缓存机制——每次成功下载的原始订阅存 `/var/db/os-mihomo/subscription-cache.yaml`（0600）；新增 configd 动作 `mihomo rules-apply`：用缓存订阅 + 当前模板 + 当前自定义规则离线重合成 → 原子应用（改规则不需要重新联网拉订阅）。

**API/View**：`Api/RulesController.php`（get/set/validate）+ 新页面 Services→Mihomo→Rules：textarea 编辑器（每行一条）+ 校验按钮 + 保存即 rules-apply；显示"当前生效规则（只读，来自订阅合成结果）"与"自定义规则（可编辑）"两个区块，避免用户混淆。

## F4 升级配置保护（今天 VM 实测证实的问题，必修）

`pkg add -f`/升级会用包内默认文件覆盖 `config.yaml`、`sub/env`（今天 VM 演练：订阅 URL 被打回 bing.com），并叠加 **bbolt cache.db 锁竞态**（旧进程未死净时新实例 `[CacheFile] can't open cache file: timeout` + controller 假死——今天复现两次）。

**方案**：
1. 包内配置文件改名为 `config.yaml.sample`、`env.sample`（plist 随之调整），+POST_INSTALL 仅在目标不存在时 `cp sample → real`（0600）
2. 新增 `+PRE_INSTALL`：`service mihomo stop` + `pkill -9 -f /usr/local/bin/mihomo` + 等待 cache.db 锁释放（循环 sockstat/pgrep 最多 10s），杜绝新旧实例竞态
3. +POST_DEINSTALL 的保留逻辑保持（已实现）

## 版本与交付

- 本次已完成：内核 v1.19.30 重建为 1.0.4（v1.19.32 在 live VM 上 controller 挂起复现 3 次，**pin 暂缓升级**，待磁盘版 VM 复测通过后再切；zashboard v3.29.1 已是最新）
- 功能实施后版本号 1.0.5；实施会话交付物：代码 + 测试（新增 test_persistent_rules.sh、test_transport_toggle.sh）+ 磁盘版 VM 全量演练 + 交接回执

## 验收标准（实施会话自测 + 审核人复查）

1. F1：面板改 URL→env 0600 生效；面板点更新→节点数变化且 secret 不丢；URL 注入 `'; rm -rf /x'` 类内容无法逃逸
2. F2：开关切 transparent→tun0+anchor 生效且 SSH 不断；切 none→hev 停、PF 无 mihomo 规则；客户端配 mixed 7890 可正常走 HTTP 代理
3. F3：添加规则→订阅更新后规则仍在且优先级最高；坏规则→mihomo -t 拦截、生产配置不动、报错指向自定义规则
4. F4：`pkg add -f` 重装后订阅 URL/节点/config 保留、无 cache.db 竞态
5. 全量 tests/ + 新增测试 PASS；零回归（现有 8 项测试语义不变）
