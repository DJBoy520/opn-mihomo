# Secure OPNsense Mihomo — 构建与打包指南 (Phase 1)

> 文档编号：BUILD-DOC-001  
> 适用版本：os-mihomo 1.0.2+  
> 运行环境：Ubuntu / Linux / FreeBSD / OPNsense  

---

## 一、 构建环境与依赖要求

本项目的构建链已实现**跨平台自包含打包**，能够在 Ubuntu/Debian 宿主机上直接构建出符合 FreeBSD 标准的 `.pkg` 插件安装包，无需提前安装 FreeBSD 虚拟机即可完成基础打包与静态哈希自校验。

### 1.1 系统与基础工具依赖
* `POSIX Shell` (`/bin/sh` 或 `/bin/bash`)
* `tar` (支持 GNU tar 或 BSD tar)
* `gzip`
* `xz` (用于解包 Mihomo 二进制资产)
* `sha256sum` (Linux) 或 `sha256` (FreeBSD)
* `jq` (可选，用于 JSON 格式化验证)
* `file` (用于验证 ELF 二进制文件类型)

---

## 二、 核心构建工具说明

```
scripts/
├── build.sh            # 主构建脚本 (可重复、跨平台打包)
└── verify-package.sh   # 产物验证脚本 (校验哈希、解包结构、ELF类型及 build-info.json)
```

### 2.1 产物输出结构
执行构建后，将在 `output/` 目录下生成标准化的构建产物：
```
output/
├── os-mihomo-1.0.2.pkg      # 标准 FreeBSD amd64 安装包
├── SHA256SUMS              # 所有产物的 SHA256 校验列表
└── build-info.json         # 构建元数据清单 (版本、哈希、架构、Git Commit)
```

---

## 三、 构建与验证操作步骤

### 3.1 一键构建
在项目根目录下执行：
```bash
./scripts/build.sh
```
* 构建过程将自动执行以下流程：
  1. 解析 `src/os-mihomo` 中的包名与版本信息；
  2. 创建干净的临时 stage 目录并镜像文件结构；
  3. 解压并准备 Mihomo 二进制可执行文件（权限 0755）；
  4. 遍历所有安装文件生成标准的 `+MANIFEST` 与 `+COMPACT_MANIFEST` 元数据；
  5. 组装生成 `.pkg` 安装包；
  6. 自动计算输出 `SHA256SUMS` 和 `build-info.json`。

### 3.2 产物验证
在构建完成后执行：
```bash
./scripts/verify-package.sh
```
验证脚本将严格测试：
1. `SHA256SUMS` 校验值与实际文件哈希完全匹配；
2. `.pkg` 内包含合法的 `+MANIFEST` 与 `+COMPACT_MANIFEST`；
3. `+MANIFEST` 中的 ABI (`FreeBSD:*:amd64`) 及文件哈希清单 100% 正确；
4. `usr/local/bin/mihomo` 确实为 FreeBSD 64-bit ELF 可执行格式；
5. `build-info.json` 元数据结构完整。

---

## 四、 故障排查 (Troubleshooting)

1. **缺失 xz 工具**：
   * 现象：`xz command not found`
   * 解决：`sudo apt-get install xz-utils` (Ubuntu/Debian) 或 `pkg install xz` (FreeBSD)。
2. **源码未携带二进制**：
   * 现象：`missing bundled mihomo asset`
   * 解决：确保 `src/os-mihomo/src/usr/local/bin/clash-meta-freebsd-amd64.xz` 存在（Phase 2 将迁移至官方供应链自动下载校验）。

---

## 五、 固件页插件登记机制（1.4.4 起）

OPNsense 固件页的插件状态由 `config.xml` 的 `<system><firmware><plugins>` 逗号列表决定：GUI 安装路径（configd `firmware install` → `register.php install`）会自动登记，而 `pkg add` 直装不会——已安装但未登记的插件会显示「(配置错误)」（misconfigured）标签。

os-mihomo 自 1.4.4 起在打包脚本内自行维护该台账：

- `+POST_INSTALL` Step 6：安装/升级后自动 `register.php install os-mihomo`（幂等，`timeout 60` 兜底 Config::save 的无限 flock 等待）；
- `+POST_DEINSTALL`：卸载后自动 `register.php remove os-mihomo`（按 pkg-script(5)，post-deinstall 在包文件删除之后执行，`plugins_disk_found` 判定失败走注销分支），防 `pkg delete` 后固件页出现「(缺失)」幽灵标签。

运维注意：

1. 从 1.4.3 及更早版本升级、或从 /conf/backup 恢复了不含 os-mihomo 登记项的 config.xml 后，固件页可能重新出现「(配置错误)」。手动补一次登记即可（幂等）：

   ```sh
   /usr/local/bin/php /usr/local/opnsense/scripts/firmware/register.php install os-mihomo
   ```

2. 登记后标签变为「(孤儿/orphaned)」属预期——os-mihomo 不在任何已启用的 pkg 仓库中（`provided==0`）。如需「(已安装)」标签与 GUI 升级通道，须把包发布进已配置的自定义仓库（`build-repo.sh` + 机器侧 repo conf）。
3. `pkg delete` 时 POST_DEINSTALL 会把 `/usr/local/etc/mihomo` 整体搬移留档到 `/root/os-mihomo-removed-*`；pkg 随后对已被搬走的自有文件报 unlinkat 提示属正常噪音。后缀在 pkg 内嵌环境下可能被破坏为字面量（如 `mHS`），留档功能不受影响。
