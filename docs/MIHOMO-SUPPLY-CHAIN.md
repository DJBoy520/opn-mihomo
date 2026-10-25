# Secure OPNsense Mihomo — 官方供应链与安全下载规范 (Phase 2)

> 文档编号：SUPPLY-CHAIN-001  
> 状态：正式锁定 (Phase 2)  
> 锁定版本：MetaCubeX Mihomo v1.19.30 (compatible/v1)  

---

## 一、 官方供应链铁律

1. **唯一合法源**：Mihomo 预编译二进制的唯一合法上游是官方仓库 [MetaCubeX/mihomo Releases](https://github.com/MetaCubeX/mihomo/releases)。
2. **严禁 latest**：禁止在任何构建或打包过程中动态引用 `latest` 标签，必须显式固定具体 Release Tag。
3. **严禁第三方二进制**：禁止使用任何个人或未经审计的第三方分发源（包括 Vincent-Loeng 等历史源）。
4. **强哈希硬性锁定**：每个锁定的版本必须在 `mihomo-version.env` 中固化其归档 SHA256 与解包二进制 SHA256。哈希不匹配立即中断构建。
5. **架构指令集兼容性**：为了兼容家庭主路由平台（如 AMD Ryzen 4500U 及通用 x86-64 CPU），优先采用官方 `freebsd-amd64-compatible` (v1) 指令集构建版本，防止因高级指令集（如 AVX2/AVX-512）缺失引起非法指令崩溃。

---

## 二、 当前固定的官方版本元数据

文件路径：`src/os-mihomo/build/mihomo-version.env`

```ini
MIHOMO_VERSION="v1.19.30"
MIHOMO_COMMIT="ac017cd"
MIHOMO_OS="freebsd"
MIHOMO_ARCH="amd64"
MIHOMO_VARIANT="compatible"
MIHOMO_ASSET="mihomo-freebsd-amd64-compatible-v1.19.30.gz"
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.30/mihomo-freebsd-amd64-compatible-v1.19.30.gz"
MIHOMO_SHA256="44ce8954f7c838372bf41266b354b9fca74c2cce89f0914592550c2064aaa950"
MIHOMO_UNPACKED_SHA256="a661c8e99ce41a5a6e16df2a9eb9b8278f8c5ba5a54418be45fffcde8884d26c"
```

---

## 三、 供应链管理脚本

### 3.1 官方下载与校验：`scripts/update-mihomo.sh`
* **执行流程**：
  1. 读取并校验 `mihomo-version.env` 中的环境变量；
  2. 使用 HTTPS 下载官方 Release Asset；
  3. 计算下载包 SHA256，与 `MIHOMO_SHA256` 比对（不匹配立即报错退出）；
  4. 解压得到 ELF 二进制，校验解包后哈希 `MIHOMO_UNPACKED_SHA256`；
  5. 调用 `file` 命令验证是否为 `FreeBSD ELF 64-bit LSB executable, x86-64`；
  6. 校验通过后，存入 `work/cache/mihomo` 供构建脚本使用。

### 3.2 官方版本检测报告：`scripts/check-mihomo-release.sh`
* 仅负责探测 MetaCubeX 官方是否有新 Release 发布并输出对比报告，不执行自动下载或发布，严格保持人工审核关口。

---

## 四、 供应链安全防护实测（异常注入测试）

在 Phase 2 验收过程中，执行了 4 组实测，结果如下：

| 测试场景 | 测试方法 | 预期行为 | 实际结果 | 状态 |
| :--- | :--- | :--- | :--- | :--- |
| **测试 1：标准合法下载** | `./scripts/update-mihomo.sh` 官方 URL 与正确 SHA256 | 成功下载并验证通过 | 归档与二进制 SHA256 100% 匹配，ELF 架构验证通过 | **PASS** |
| **测试 2：篡改 SHA256 注入** | 故意修改 `.env` 中的 `MIHOMO_SHA256` 为伪造哈希 | 立即报错并退出，禁止生成产物 | 提示 `SHA256 mismatch! Expected: ...` 并立即退出 (exit 1) | **PASS** |
| **测试 3：非 FreeBSD 架构注入** | 传入 Linux/Darwin 版本的二进制进行校验 | 架构检查拦截并退出 | 提示 `architecture mismatch` 并立即退出 (exit 1) | **PASS** |
| **测试 4：版本不匹配/破坏性测试** | 替换为空文件或不完整二进制 | 判定为非法空文件退出 | 提示 `unpacked binary is empty` 立即退出 (exit 1) | **PASS** |
