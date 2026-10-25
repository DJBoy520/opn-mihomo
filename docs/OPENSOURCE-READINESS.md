# os-mihomo 开源前脱敏扫描报告（只读，2026-10-24）

> 本文件**不含任何真实地址、账号、口令、密钥或个人路径**，只记录类别、文件位置与处理建议。
> 扫描范围：当前工作区 tracked 文件 + `git log` 元数据；未执行任何修改、未重写历史、未 push。
> 结论：**工作区可以脱敏，但 Git 历史仍含敏感信息；公开前必须选择“干净快照”或“重写历史”。**

---

## 1. 扫描结果（按类别）

| 类别 | 位置 | 风险 | 建议 |
| --- | --- | --- | --- |
| 内部交接文档 | 内部交接文档（已从公开历史移除） | 含测试/生产防火墙私网地址、WebGUI 默认账号口令、SSH 登录方式、个人绝对路径、内部工作流 | **移入 `.private/`（已 gitignore）或从公开树删除**；本地保留用于交接 |
| 工作日志 | `progress.md` | 含测试环境私网地址与内部操作记录 | 脱敏为占位符，或移入 `.private/` |
| 设计文档示例 | `docs/DESIGN-panel-features-v2.md` | 含 1 处私网地址 | 改为 `<LAN_IP>` 等占位符 |
| 源码个人路径 | `src/os-mihomo/src/usr/local/opnsense/scripts/OPNsense/Mihomo/transport_render.php:23` | `DEV_PF_TEMPLATE` 写死个人绝对路径 | 删除该常量；改为 `--template <path>` CLI 参数 > 运行期安装路径 |
| Git 历史 | 全部 commit | **9 个提交**包含用户网段；**5 个作者邮箱** | 公开前二选一：A. 干净快照（推荐）；B. `git filter-repo` 重写（需授权） |
| 构建产物 | `output/*.pkg`、`repo/` | 二进制包可能内嵌构建路径/作者邮箱；不是源码必需 | 公开仓库排除，发布包单独分发 |
| 其它插件样例 | `src/os-easytier`、`src/os-sing-box`、`src/os-ddns-go`、`src/os-ddclient-opnwall` | 含私网地址/样例凭据，需逐项判断是否为上游示例 | 开源前逐项复审；本方案只强制处理 os-mihomo |
| 公开身份 | `LICENSE`、`README*`、`version/mihomo` 的 `product_email`、提交作者 | 可能暴露个人姓名/邮箱 | 统一为项目公开身份；公开前确认 |

> 注：通用测试里的 RFC1918/TEST-NET 示例地址（如 `10.0.0.0/8`、`192.0.2.0/24`）是正常技术示例，不在泄露范围内；需要区分“真实环境值”和“示例值”。

---

## 2. 建议的处理顺序

1. **先决定历史策略**（需要用户授权）：
   - **A. 干净快照（推荐）**：导出当前工作区为全新 orphan 提交/新仓库，不带历史。最简单、最安全；不会改写现有仓库。
   - **B. 重写历史**：`git filter-repo` 替换真实网段/邮箱/路径；需先 `git bundle` 备份，强推前与所有协作者协调。会改写全部 commit hash。
2. 把内部交接文档与工作日志移入 `.private/`；确认 `.gitignore` 已覆盖。
3. 清除 `transport_render.php` 的个人路径；按 §3.7.2 清单处理其它硬编码。
4. 文档/测试示例占位化：私网地址、账号口令、真实订阅名称/表情、个人路径。
5. 排除 `output/`、`repo/` 二进制；确认 `output/build-info.json` 不含构建用户/路径。
6. 统一公开身份（作者、邮箱、`product_email`、LICENSE）。
7. 跑 `scripts/audit-sensitive.sh` + 全量测试；确认 `git grep` 与历史扫描都干净。
8. 在全新的公开仓库/分支上发布；不要直接从当前历史强推。

---

## 3. 防复发门禁（待实现）

- `scripts/audit-sensitive.sh`
  - 优先读取 `.private/sensitive-patterns.txt`（gitignored）中的真实网段/口令/路径模式；
  - 无该文件时执行通用检查：个人主目录路径、OPNsense 默认账号口令、明文 `password=`/`secret=`、邮箱、私网 IPv4（TEST-NET/RFC1918 示例需显式 allowlist）；
  - 命中输出 `文件:行号`，**不打印命中值**；退出码非 0。
- `tests/test_no_sensitive.sh` 包装该脚本，纳入全量测试。
- `tests/test_ui_no_emoji.sh`：插件自有视图/表单/菜单/ACL 不得出现 emoji。
- `scripts/export-public.sh`（可选）：复制 tracked 文件到 `dist/public/`，排除内部文档、日志、`work/`、`output/`、`repo/`、`.private/`，随后跑敏感扫描。

---

## 4. 公开前检查清单

- [ ] 历史策略已选定并执行（A 或 B），备份已做
- [ ] 内部交接文档（已从公开历史移除）、`progress.md`、`.private/` 不在公开树
- [ ] 源码无个人绝对路径、真实私网地址、账号口令、订阅链接/密钥
- [ ] 文档/测试示例全部占位化或使用 TEST-NET
- [ ] `output/`、`repo/` 二进制不随公开仓库分发
- [ ] 作者姓名/邮箱/`product_email` 已统一为公开身份
- [ ] `scripts/audit-sensitive.sh` 通过
- [ ] 全量测试通过
- [ ] 公开仓库为干净快照或已重写历史，且未从旧历史强推
- [ ] 已确认现有 remote 是私有仓库；若历史已推送过，重写前先与协作者协调并备份（`git bundle`）
