# os-mihomo 面板化增强设计方案 v2（F1~F4 · 吸收 DeepSeek BLOCK 审核后的修订版）

> v1（DESIGN-panel-features.md）被 DeepSeek 审核 BLOCK（31 条发现，核心：pfctl 整表重载丢 NAT、env 单引号注入可 root 执行、升级覆盖配置、watchdog 语义冲突）。本 v2 为**唯一有效设计**，v1 保留作审核对照。Gemini 审核结论待出，出后合并。
> 实施前必读：内部交接文档（不随公开仓库分发）。基线 1.0.4（内核 v1.19.30）。

## D1（原 F1）订阅管理面板化

**单一真源**：订阅 URL 只存 MVC 模型；`sub/env` 文件由动作生成，不再是手工编辑对象（内部交接文档（已从公开历史移除）的手工步骤作废）。

- **模型** `subscription`：`url`（可写，强校验）、`url_masked`（只读，get 时生成 `scheme://host/***`）、`auto_update`(B)、`auto_interval`(选项 6h/12h/24h，**不做 48h**——Cron 字段表达不清)。
- **URL 服务端强校验**（setAction 与 sub-env-write 双侧）：`\Ahttps://[0-9A-Za-z._~:/?#\[\]@!$&()*+,;=%-]+\z`，显式拒绝 `'`、`"`、反引号、CR/LF、Tab、控制字符、空白。**不合规直接拒绝并说明**。
- **env 写入**（configd 动作 `sub-env-write`，PHP 实现）：保留 env 中未知的其他行（读-改-写），`mihomo_URL` 行用 POSIX 安全转义：`'` → `'\''`（**不是**单引号裸包裹）；写 0600；同时用 `\OPNsense\Cron\Cron` 模型 API 注册/移除每日任务（command=`mihomo sub-update`，description 固定 `os-mihomo auto sub-update` 幂等），保存后触发 regenerate。
- **updateAction**：`configdRun('mihomo sub-update', detach=true)` 立即返回（Backend 默认 120s 不够，sub.sh 最坏 ~10 分钟）；前端每 3s 轮询 `getAction`，读 `/var/db/os-mihomo/last-sub-update.json`（sub.sh 成功/失败时写入：时间/节点数/结果/错误摘要）。动作入口加锁复用 /var/run/mihomo-sub.lock（防重复点击）。
- **回归测试**：注入 payload `https://x/'; echo INJECTED; #'` 必须（a）被校验拒绝（b）即使构造成功也不产生命令执行（测试里 source 生成后的 env 断言无 INJECTED 输出）。

## D2（原 F2）透明代理开关

**PF 机制（颠覆 v1）**：不走任何 pfctl 整表 dump/重载。
1. `plugins.inc.d/mihomo.inc` 新增：
   ```php
   function mihomo_firewall($fw) {
       if (模型 transport == 'transparent') {
           $fw->registerAnchor('mihomo-transport', 'fw', 0, 'head', true);
       }
   }
   ```
   → 每次 `configctl filter reload` 自动重建引用（head+quick，先于用户规则），**无自愈窗口**；transport≠transparent 时不注册=干净移除。
2. anchor 规则文件随包分发：`/usr/local/etc/mihomo/pf-transport.conf`（入库，脱敏自生产 xray-proxy anchor），内容**只含 pass/route-to，禁止 block/reject**：
   - bypass：目的=本机自身地址、RFC1918、组播/广播、DHCP(67/68)
   - `pass in quick on <LAN_IF> route-to (tun0 10.0.0.1) inet proto tcp from <LAN_NET> to any flags S/SA keep state`
   - 同上 udp；LAN_IF/LAN_NET 从 config.xml 动态解析，多接口/IPv6 列入实施验证清单
3. `transport_manager.sh`：enable/disable **只做** `pfctl -a mihomo-transport -f 规则文件 / -F all` + hev 启停 + 幂等，**永不 pfctl -f 主规则集**。

**hev 所有权**：插件自带 rc 脚本 `mihomo_hev`（daemon -p 记子 pid；stop=按 pid kill，禁全局 pkill）。迁移时序：先停外部 `xray-proxy-watchdog` → 停 xray_proxy → 插件 transport-enable 接管 tun0。生产既有 hev rc 不复用不冲突。

**fail-open（修正方向）**：watchdog 维持纯 fail-open；新增：watchdog/healthcheck 判定 7891 或 1053 不健康时，除停 mihomo 外**必须 `pfctl -a mihomo-transport -F all`（清空 anchor=恢复直连）**——防 route-to 进死端口黑洞。健康恢复后由 rc.d/cron 按模型幂等 re-enable。

**生命周期**：
- `+PRE_INSTALL` / `+PRE_DEINSTALL`：第一步 `transport-manager disable`（幂等），并删 /var/run/mihomo.pid 与状态文件（防 pid 误判跳过启动）
- `+POST_INSTALL`：健康门禁通过后才按模型 transport==transparent 幂等 re-enable
- 开机：`mihomo` rc.d 启动脚本在 mihomo 健康后读 `/var/db/os-mihomo/transport-mode`（transport_manager 维护）决定是否 enable
- enable 全程 SSH 存活断言（每步后 `kill -0 $PPID` 探测父会话）+ 失败即 disable；磁盘 VM 演练必须含 transparent on/off 各一轮且 SSH 全程存活

**普通代理模式语义**：mixed-port 7890 绑定 **127.0.0.1（保持）**；LAN 客户端使用的暴露方案=可选启用“LAN 暴露”（模型项，默认关）：开启时模板 `mixed-port` 改绑 `0.0.0.0` + `authentication`（user/pass，密码=secret）+ `lan-allowed-ips: LAN_NET`，健康门禁同步改为探测 LAN 绑定。默认关闭（无认证开放代理不做）。当前 VM 的 9090 LAN 绑定是用户单独授权的既有事实，不受此项影响。

## D3（原 F3）持久自定义分流规则

- **白名单类型**（socks-core 语义修正）：`DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, IP-CIDR, IP-CIDR6, GEOIP, GEOSITE, DST-PORT`（移除 SRC-IP-CIDR/PROCESS-NAME——socks 入口源地址恒为 127.0.0.1，无意义）。
- **逐行校验**（PHP，无 lookahead）：行内先按 `\r\n` 拆分、去注释/空行；每行 `str` 必须通过：禁 `'` `"` `{` `}` `[` `]` Tab、禁子串 `: ` 与 ` #`；字段按类型规定 2~4 段（逗号分割，IP-CIDR/IP-CIDR6/GEOIP 允许第 4 段 `no-resolve`）；目标 ∈ {DIRECT, REJECT, REJECT-DROP} ∪ 模板 proxy-groups 实际组名集合（构建时从 template_config.yaml 解析生成）。
- **写入**：PHP `file_put_contents(temp) → chmod 0600 → rename`（LOCK_EX），限制 ≤200 行/≤32KB；configd 动作只执行应用，不接收规则文本参数。
- **注入**：sub.sh 合成阶段把合法规则插到 `rules:` 顶部（`# __MIHOMO_CUSTOM_RULES__` 占位）；随后 mihomo -t 校验（坏规则=校验失败=生产配置不动）。
- **报错可见性**：rules-apply 自行运行 `mihomo -t 2>/tmp/err` 并把 stderr 映射到 custom-rules 行号后返回（atomic updater 保持静默语义不变）。
- **缓存一致性**：仅当 `atomic_config_updater` 成功后，`temp+rename` 写 `/var/db/os-mihomo/subscription-cache.yaml`(0600) 并在 last-sub-update.json 记 hash；`rules-apply` 与 sub.sh 共用 `/var/run/mihomo-sub.lock`，且复用 sub.sh 的合成函数（避免双实现互删临时文件——把 sub.sh 下载/合成重构为可 source 的函数库 `sub_lib.sh`）。

## D4（原 F4）升级配置保护（含 pkg 行为修正）

- 包内文件：`config.yaml.sample`、`sub/env.sample`、`sub/template_config.yaml`（**保持原名但升级覆盖已在快照恢复中处理**）、`custom-rules.txt` 由运行时生成不入包。
- **+PRE_INSTALL**（新增，两套 build.sh 的 manifest scripts 段都必须生成 `"pre-install"`；need_file 清单同步）：stop + `pkill -9 -f '^/usr/local/bin/mihomo'` + 等 pgrep 清空（≤10s，超时中止安装并告警）→ **快照** config.yaml/sub/env/custom-rules.txt/secret.key/template_config.yaml → `/var/db/os-mihomo/pre-upgrade/`(0600) → 删 /var/run/mihomo.pid 与 state 文件 → transport-disable。
- **+POST_INSTALL 顺序（严格）**：①从 pre-upgrade 恢复存在文件，缺失项 cp .sample（0600）②secret 仅在 secret.key 缺失/为空时 generate（升级保留原 secret）③health gate ④按模型幂等 transport-enable。
- **+PRE_DEINSTALL**：先 transport-disable，再既有停服逻辑。
- **+POST_DEINSTALL**：同步搬移（去掉 sleep 3 后台），重装竞态由 PRE_INSTALL 快照天然兜底。
- `rc.conf.d/mihomo` 仅在文件缺失时写 enable=YES。
- 回归测试：VM 上 `pkg add -f` 升级后断言 URL/节点数/secret 保留、无 cache.db 竞态、transport 状态按模型恢复。

## 工程集成检查单（实施会话逐项勾）

- [ ] 新脚本全部加入两套 build.sh 的 chmod 列表与 need_file
- [ ] Menu.xml 加 Rules 页；ACL.xml 加 `api/mihomo/subscription/*`、`api/mihomo/rules/*`
- [ ] index.volt：transport 单选、订阅表单、立即更新按钮（detach+轮询）、规则编辑器——全部 JS 接线到新 API
- [ ] General 页 Save 现在只 setGeneral+restart——需按字段分发动作（transport 变更→transport-enable/disable；url 变更→sub-env-write）
- [ ] `mihomo.inc` 增加 `mihomo_firewall()`；build-info 的 commit 字段允许为空
- [ ] verify-package.sh 增加断言：pre-install 段存在、pf-transport.conf 在包内、无 __pycache__
- [ ] 全部新脚本遵守零反斜杠续行、零 % 转义（manifest 内嵌三脚本）
- [ ] README.US.md 同步（遗留欠账）

## 双审核合并修正（Gemini APPROVE-WITH-FIXES + DeepSeek BLOCK，已全部吸收）

两家在核心结论完全收敛：标准 plugin filter 钩子（registerAnchor head+quick）替代任何主规则集篡改；订阅更新异步化+轮询；env 注入强校验+转义；F4 PRE_INSTALL 快照+build.sh 补 pre-install 段。以下为 Gemini 独有补充，已并入上文对应章节：

1. **anchor bypass 强制清单（防管理员锁死，严禁可选）**：目的=本机自身地址（任意端口，覆盖 WebGUI 8443/443/80、SSH 22、API 端口默认 9090）、网关 IP、RFC1918、组播/广播、DHCP 67/68。anchor 只放 pass/route-to，禁止 block/reject。
2. **F1 长动作**：PHP 侧同时显式 `set_time_limit(≥300)`；前端 Web 服务器超时配置一并核对。
3. **F1 env 写入**：`filter_var($url, FILTER_VALIDATE_URL)` + scheme https 强制 + `str_replace("'", "'\\''", $url)` 转义 + 拒绝 CR/LF。
4. **F3 rules-apply**：保存前必须离线跑 `mihomo -t` 编译级预检、失败拒存；缓存缺失时优雅降级为自动触发一次在线订阅更新；与 sub-update 强制共用 LOCK。
5. **F4 +PRE_INSTALL**：先 SIGTERM 优雅等待 3~5s，超时才 SIGKILL（避免 bbolt 脏状态）；`rc.conf.d/mihomo` 仅在缺失时写 YES（不覆盖用户禁用状态）；manifest 内嵌脚本彻底清除一切 `%` 字符。
6. **hev 所有权**：生产切换前必须先停用并 disable 既有 `hev_socks5_tunnel` 系统服务，tun0 全权移交 transport_manager（双守护进程会争抢 tun0）。

## 版本与验收

- 实施 = 1.0.5；磁盘版 VM 全量演练（含重启自启、F2 on/off SSH 存活、F4 升级保留、payload 注入回归）全部通过后才可提请生产窗口。
- 红线更新：config.xml 仅允许 `//OPNsense/mihomo` 与 `//OPNsense/cron` 经模型 API 写入；PF 仅允许 mihomo-transport anchor（head+quick，只 pass/route-to）；Unbound 永不触碰。

## 实施修订记录（2026-10-18，主控审计定稿）

0. **一键安装（用户 2026-10-18 追加需求）**：目标 = 拷包 + 一条命令完成透明代理部署，订阅 URL 是唯一必填项。实现三层：
   - `+POST_INSTALL` 环境变量钩子：pkg 会把调用方环境传给安装脚本，`MIHOMO_SETUP_URL='https://…' pkg add os-mihomo-1.0.5.pkg` 即装即部署（`MIHOMO_SETUP_TRANSPORT`/`MIHOMO_SETUP_INTERVAL` 可选，默认 transparent/o24h）。
   - `/usr/local/etc/mihomo/setup.sh`（随包）：独立入口，装包后可随时重跑改设置；编排 sub-env-write → mihomo_setup.php（模型+Cron）→ filter reload → transport-enable → 订阅拉取 → 终检报告。
   - `mihomo_setup.php`（随包）：CLI 合法引导 = `require_once('script/load_phalcon.php')`（核心 include_path 自带），经 MVC 模型 API 写 `//OPNsense/mihomo`（订阅字段 + transport_mode）与 `//OPNsense/cron`（自动更新任务 + **watchdog 每分钟常驻任务**，fail-open 引擎从此有人兜底）——红线机制不破。
   - DNS 无缝：生产 AdGuardHome 上游本就指向 127.0.0.1:1053，mihomo 接管同端口，迁移零 DNS 改动；LAN 客户端网关保持 .2 不变，零客户端配置。
   - 已验证锚点：load_phalcon.php 为 OPNsense 核心 CLI 引导（ntpd_status.php 等核心脚本同款，测试 VM 实机核实）。

1. **D2 bypass 改为表排除法**（替代 D2 原文「bypass 逐条 quick pass 规则」）：anchor 内的 route-to 规则写成 `to ! <mihomo_bypass>`（表内含本机地址、网关、RFC1918、组播 224/4、240/4、255.255.255.255、0.0.0.0/8），不匹配的包自然落回主规则集。原因：原方案 bypass pass 带 quick 会先于用户策略命中，把管理员自己的 block 规则短路掉（比如对特定 LAN 客户端的封锁）。Gemini 强制清单中的 bypass 目的地一个不少，只是实现更保守。
2. **F1 cron 注册移到 MVC 控制器**（替代「sub-env-write 动作内用 Cron 模型 API」）：独立 CLI PHP 无法可靠引导 MVC 框架；SubscriptionController::setAction 保存模型后直接经 `\OPNsense\Cron\Model` 注册/禁用每日任务（description 固定 `os-mihomo auto sub-update`），保存后 `cron regenerate`。红线不受影响（cron 仍经模型 API）。另：auto_update=0 时置 enabled=0 而非删除任务项（可逆、避免依赖不确定的 del API）。
3. **hev.yaml 采用生产实证 schema**：tun0 地址 10.0.0.2、`ipv4-gateway: 10.0.0.1`（route-to 目标保持 `(tun0 10.0.0.1)`）、mtu 1500；hev-socks5-tunnel 在 FreeBSD 需要伪终端，`mihomo_hev` rc 用 `daemon -p` 包 `script -q /dev/null` 启动，stop 严格按 pid（必要时按 pid 找子进程），禁全局 pkill（生产只读核实，2026-10-18）。
4. **F2 服务生命周期补强**：service_manager 的 do_stop/do_failopen 在停进程前先 transport-disable（flush anchor + 停 hev），do_start 在健康通过后按 transport-mode 幂等 enable——彻底杜绝「mihomo 停了 anchor 还在」的 route-to 黑洞窗口；watchdog fail-open 里保留 `pfctl -a mihomo-transport -F all` 作为双保险，全部健康且 anchor 为空时调 recover 幂等重挂。
