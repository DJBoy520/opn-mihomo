# Secure OPNsense Mihomo — 构建基线文档 (Phase 0)

> 文档编号：BUILD-BL-001  
> 审计日期：2026-08-31  
> 状态：基线锁定  

---

## 一、 当前构建体系深度剖析

### 1.1 构建与打包机制 (`build.sh` & `Makefile`)
当前 Opnwall 仓库中 `src/os-mihomo` 的构建方式主要由 `build.sh` 独立实现：
1. **工作区准备**：创建 `work/freebsd-pkg/stage`、`meta`、`downloads` 等目录。
2. **源码收集**：使用 `tar` 将 `src/` 下的文件树镜像拷贝到 `stage`。
3. **二进制获取**：优先查找本地 `src/usr/local/bin/clash-meta-freebsd-amd64.xz`，不存在则从 `https://github.com/Vincent-Loeng/clash-meta/releases/latest/download/...` 下载并解压。
4. **生成 Manifest 与包描述**：遍历 `stage` 下的文件生成 `pkg-plist` 并逐个计算 SHA256，生成 `+MANIFEST` 元数据文件。
5. **打包**：使用 `tar -cPzf` 将 staged 文件及 `+MANIFEST` 打包成 `.pkg`（本质是包含元数据的 tar.gz 压缩包）。
6. **校验**：调用系统 `pkg info -F` 检查包的合规性。

### 1.2 外部工具链依赖
当前构建脚本强依赖以下工具：
* `pkg` (FreeBSD 包管理器命令，用于 ABI 查询和校验)
* `sha256` (FreeBSD 原生哈希计算命令，与 Linux `sha256sum` 参数不同)
* `xz`、`tar`
* `fetch` 或 `curl`
* `jq`

---

## 二、 Ubuntu 构建可行性分析与跨平台挑战

### 2.1 核心冲突点
1. **`pkg` 工具缺失**：Ubuntu/Debian 默认无 FreeBSD 的 `pkg` 命令（`pkg-static`）。Ubuntu 上的 `pkg` 实际上是 Debian 自己的包或者不兼容的二进制。
2. **`sha256` 工具差异**：FreeBSD 提供 `sha256 -q`，而 Linux 默认使用 coreutils 的 `sha256sum`。
3. **二进制格式与架构**：Mihomo 需要的是 FreeBSD ELF 64-bit LSB 可执行文件，不能在 Linux 上原生执行 `mihomo -v` 进行自校验。

### 2.2 跨平台打包可行性评估
* **FreeBSD `.pkg` 格式本质**：FreeBSD pkg 实际上是一个由 `+COMPACT_MANIFEST`、`+MANIFEST` 以及安装路径文件组成的普通 `tar.gz` (或 `.pkg`) 归档。
* **纯脚本打包在 Linux 上的可行性**：
  * 通过封装跨平台的哈希计算（`sha256sum` / `sha256` 自动适配）与规范的 `tar` 参数，**完全可以在 Ubuntu 上直接生成合法的 FreeBSD `.pkg` 包**。
  * 对于验证环节（如 `pkg info` 与 `mihomo -v` 执行），可采用以下两种演进方案之一。

---

## 三、 构建演进方案设计 (面向 Phase 1)

### 方案 A：跨平台原生构建脚本 + 容器化/VM 验证（推荐）
* **开发构建阶段 (Ubuntu)**：
  * 改造 `scripts/build.sh`，使其在 Ubuntu 环境下使用 POSIX 标准工具（`tar`、`gzip`、`sha256sum`）直接组装生成标准 `+MANIFEST` 与 `.pkg`。
  * 二进制文件由官方 MetaCubeX Release 预先下载并根据固定的 SHA256 校验通过后打包。
* **CI / 深度验证阶段**：
  * 使用 FreeBSD VM (如 QEMU/KVM 或 CI 中的 FreeBSD runner) 执行 `pkg add` / `pkg info` 及 `mihomo -v` 测试。

### 方案 B：标准 FreeBSD Docker / Jail 容器构建
* 在 Ubuntu 宿主机上通过 `podman`/`docker` 运行包含 FreeBSD userland (qemu-bsd-user) 或 OPNsense 官方 build tools 的容器环境，调用原生 `pkg` 完成构建。
