# DESIGN: external-controller 地址与端口可配置（v3.2 简化方案）

状态：v3.2（吸收第三轮审计：Gemini BLOCK 10 条 / DeepSeek BLOCK 26 条，确认 11 条含 9 条阻断级——全部吸收；方向本身（可配置）未被任何发现挑战）
日期：2026-10-18
版本史：v1/v2 PF CIDR（两轮 5 HIGH，废弃）→ v3 绑定直配 → v3.1 端口可配+零硬编码 → **v3.2 九条阻断吸收**（端口校验改 IntegerField、断言精确化+负向+轮询、secret 有效值门禁、端口 deny-list 硬拒、控制面/数据面解耦、apply-then-persist 时序、transport 门禁与清单修正、迁移与文档同步）。
关联：目标版本 1.0.8。

## 1. 目标与产品语义（不变）

- 面板配置 `general.api_bind`（默认 127.0.0.1；可为本机接口 IP / 0.0.0.0）与 `general.api_port`（默认 9090）。
- 渲染语义 = mihomo 原生 socket 绑定；**不做任何 PF 改动**；无 SSH 隧道强依赖。
- secret 是唯一认证层；**渲染非回环绑定的每一层都以 config.yaml 中实际生效的 secret 为准**（见 §2.2.0）。
- 最高约束：不断网 / WebGUI 失联 / DNS 失效；**管理面（API）故障不得连坐数据面（代理+DNS）**（见 §2.6，第三轮 HIGH 修正）。

## 2. 行为定义

### 2.1 值域与校验（端口部分重写）

- api_bind：模型 `<Mask>`（带分隔符 IPv4 正则）→ 控制器 filter_var → 渲染脚本本机地址核验（`ifconfig -a` 以 awk `$1=="inet" && $2==addr` 精确匹配，防 inet6/netmask 子串误配）。
- **api_port：IntegerField + `<MinimumValue>1024</MinimumValue> <MaximumValue>65535</MaximumValue>`**（废除 v3.1 的 Mask 正则——其实测放行 65536-99999 的笔误已被第三轮审计抓包；IntegerField 与仓库 DynDNS.xml 先例一致）。
- **端口 deny-list 硬拒绝（三层执行：模型范围 + 控制器 + 渲染脚本）**：
  - <1024（mihomo 以 root 运行，重启竞速会抢占 sshd/lighttpd → SSH/WebGUI 失联，红线）；
  - 插件自身内部端口 1053 / 7890 / 7891（listener 冲突 + 断言误判）；
  - 系统实际端口：动态读 config.xml 的 `system.webgui.port`（空则按协议 80/443）与 `system.ssh.port`（默认 22）。
  - 拒绝即返回 validation 错误不落盘（"拒绝或告警"的二义性废除——一律硬拒）。
- 非法值拒绝保存并报错；测试矩阵覆盖 1/22/80/443/1023/1024/1053/7890/7891/65535/65536/99999。

### 2.2 渲染与生效（断言与事务性重写）

**2.2.0 secret 有效值门禁（前置）**：渲染非 127.0.0.1 前，解析 config.yaml 的 `^secret:` **实际值**（mihomo 只认 config.yaml，不认 secret.key）：
- 非空 → 放行；
- 空但 secret.key 有值 → 锁内先调用 secret_manager 落地逻辑同步四处，再复检；
- 仍空 → 拒绝渲染非回环绑定（exit 1，指明原因）。控制器保存前置检查同一有效值口径（不再以 secret.key 存在性判定）。

**2.2.1 事务性写入**：锁内对 config.yaml 与 template 先做 0600 备份；任一步失败（grep 写后校验 / 第二文件写 / reload / 断言）→ 从备份恢复两文件并复验；恢复也失败 → 输出明确的手工恢复指引并写持久告警文件，exit 1。锁持有到事务结束（含回滚）。

**2.2.2 生效断言（精确化，废除 OR 匹配）**：
- reload 后**有界轮询**（10-30s、0.5s 间隔；不再依赖 do_reload 内部 sleep 1）；
- `sockstat -l -p <port>`（不带 -4）**按期望 bind 精确匹配**：0.0.0.0 → `(\*|0.0.0.0):<port>`；127.0.0.1 → 仅 `127.0.0.1:<port>`；接口 IP → 仅 `<bind>:<port>`。**严禁 127.0.0.1 兜底 OR**（假阳性使回滚机制失效）；
- 按 mihomo 进程（PID/命令）限定行，防同端口其他进程串扰；
- **负向断言**：旧 bind:port 监听必须消失（收窄场景旧通配不消失 = 失败）；
- 回滚路径复用同一双向断言。

**2.2.3 时序（apply-then-persist）**：api-bind-apply 成功后才写 panel-state / 才算保存生效；失败时**回滚模型值**（或记录 desired/applied 两态并在面板展示差异）；setGeneralAction 在 apply 失败时**跳过**后续 restart 分支（防 do_start reconcile 按模型把失败值再次应用 → 服务 FAILED 的链条）。

### 2.3 配置驱动探测——零硬编码（清单修正）

真实盘点（第三轮审计核实）：**33 处 9090 / 13 个文件**（src+packaging，不含 GeoSite.dat；v3.1 写的 22/11 低估，已修正）；内部端口散布 16 个文件。归零口径：`grep -rn 9090 src packaging | grep -v tests | grep -v '\.dat'`（README/docs 的陈述性文字另行同步，不计入归零）。

- 单一读取口径：sub_lib.sh 导出 helper + system_status.py 同逻辑（解析 `^external-controller:` 的 bind:port；0.0.0.0 → 127.0.0.1 探测；接口 IP → 探测该 IP；解析失败回落 127.0.0.1:9090 + 告警）。
- 消费点（按风险排序）：
  1. **transport_manager.sh mihomo_healthy()（最高优先——透明代理 enable/recover 的门禁）**：硬编码 `(127.0.0.1|\*|0.0.0.0):9090` 正则改配置驱动（改 LAN IP/端口会导致透明代理彻底无法重挂，第三轮 HIGH）；
  2. +POST_INSTALL port_up：去 `-4`、动态解析（含 LAN IP 形态；否则升级后健康门禁必失败并阻断传输层恢复）；
  3. service_manager（check_api_ready/do_healthcheck）、watchdog、system_status.py、setup.sh、sub.sh 文案；
  4. scripts/opnsense/verify.sh、rescue.sh（运维脚本，改解析或明确标注默认值适用）；
  5. setup_firewall.php 死码 9090 规则块删除，**同步更新 test_pf_rules.sh 的旧断言**；test_socks_mode.sh 的 watchdog 1053 断言同步；
  6. index.volt 文案动态化（getGeneral 带 api_bind/api_port；0.0.0.0 显示推导 LAN IP 而非字面 0.0.0.0）；config.yaml.sample 同步。
- +POST_INSTALL 内嵌 manifest **禁 % 字符**约束重申（新探测逻辑 source helper 或零 %）。
- 内部端口（1053/7890/7891）：探测改从 config 解析；hev.yaml.sample / setup_unbound.php 中的引用标注"不受管耦合"（本版不改其值）。

### 2.4 生命周期（时序修正）

| 事件 | 行为 |
| --- | --- |
| 面板保存 | 前置校验（§2.1 deny-list + §2.2.0 secret 有效值）→ setAction 落盘 → api-bind-apply → **成功才写 panel-state**；失败回滚模型 + 跳过 restart（§2.2.3） |
| do_start | reconcile 插入点：already-running 早返回**之后**、`mihomo -t` 校验之前；持锁、永不非 0 退出（set -eu 安全）、失败仅告警（fail-closed 方向） |
| +POST_INSTALL | 快照恢复 → sample 兜底后**强制 secret apply**（防 secret.key 有值而 config 为空）→ reconcile（restart 前，未运行只改文件）→ 健康门禁（动态探测） |
| **升级迁移（新增）** | 首次升级到 1.0.8：把 config.yaml 现有 external-controller（bind+port）**导入模型**（如 VM 现存 0.0.0.0），避免"面板显示 127 默认值而运行态是通配"的认知错位与静默收窄 |
| 订阅更新 | 模板继承 |
| LAN IP 变化 | 绑定失败时按 §2.6 降级处理（不杀服务） |

### 2.5 面板与文案

同 v3.1（动态地址+端口显示、/ui/ 免密与明文 Bearer 如实声明、0.0.0.0 显示推导 LAN IP、metacubexd/内置面板名称统一），文案中的 9090/127 字面量全部随动。

### 2.6 控制面/数据面解耦（第三轮最重要 HIGH，对现有状态机的定向修改）

现状：API 探测是 do_start 与 watchdog 的**致命判据**——check_api_ready 30s 超时 → do_stop_internal；watchdog API 不可达 → trigger_failopen 杀进程。在 127.0.0.1 时代"API 死≈核心死"成立；绑定可变后（LAN IP/DHCP 漂移/接口就绪时序），API 不可达不再蕴含核心死亡，误杀会连带 1053 DNS 挂掉——违反"不 DNS 失效"红线。

修改：
1. **fail-open 判据改为数据面**：socks（7891，从 config 解析）+ DNS（1053）探测为致命判据；API 探测降级为"连续 N=3 次失败 → 告警 + 触发 reconcile"（不再杀进程）。
2. do_start：check_api_ready 失败不再 do_stop——改回退渲染 127.0.0.1 并重载一次；仍失败则**继续运行**（数据面为准）+ 告警。
3. 实施后 VM 回归两条硬断言：**杀 API 不杀服务（DNS/代理存活）；杀 socks/DNS 仍正常 fail-open**（原语义保持）。

## 3. 安全事实（增补 IPv6 与既有规则例外）

- 0.0.0.0 实测 tcp46 双栈：**IPv4+IPv6 通配、含 WAN v6**；"WAN 默认拒绝"仅在无显式 WAN pass 规则时成立——面板文案如实写明并推荐绑定 LAN IP。
- 其余同 v3.1（/ui/ 免密、Bearer 明文、secret 有效值门禁）。

## 4. 改动文件清单（修正）

v3.1 基础上增补：**transport_manager.sh（门禁级，最高优先）**、scripts/opnsense/{verify,rescue}.sh、tests/{test_pf_rules,test_socks_mode}.sh 断言同步、+POST_INSTALL（secret 强制 apply / reconcile 前置 / % 禁令）、mihomo_setup.php 或 +POST_INSTALL 内做**升级迁移**、全部文档陈述同步（SECURITY/TRANSPARENT-PROXY/FAIL-OPEN/WEBGUI/README 的"强制 127.0.0.1"表述更新为"默认 127.0.0.1，可配置"）。

## 5. 验收清单（增补）

v3.1 十项全部保留，另增：
11. 端口 deny-list 矩阵（22/80/443/8443/1053/7890/7891/1023/65536/99999 全拒；1024 与正常端口通过）。
12. 断言负向：0.0.0.0 收窄到 127 后 `*:port` 必须消失才判成功。
13. 旧 0.0.0.0 安装升级：模型导入、面板显示与运行态一致。
14. **解耦回归：kill API → 服务/DNS/代理存活且告警；kill socks → 正常 fail-open**。
15. transport enable/recover 门禁在 LAN IP + 自定义端口绑定下通过（透明代理可重挂）。
16. 归零断言：`grep -rn 9090 src packaging | grep -v tests | grep -v '\.dat'` 为空。

## 6. 决策存档

三轮审计轨迹：PF 方案因机制性风险废弃 → 绑定直配方向三轮未被动摇 → 剩余发现全部为实现契约（校验/断言/时序/解耦/清单），已逐条吸收为本版各节。**实施采用编码工作流：门禁测试先行 + 交叉审计 + 主控 VM 回归（含 §5.14 解耦行为）**。
