<div align="center">
  <a href="README.md">中文</a> |
  <a href="README.US.md">English</a>
</div>

# opn-mihomo

**OPNsense 的 Mihomo（Clash Meta）透明代理集成插件与软件源**

[![OPNsense](https://img.shields.io/badge/OPNsense-26.7%2B-orange)]()
[![Platform](https://img.shields.io/badge/Platform-FreeBSD%2015%20amd64-blue)]()
[![License](https://img.shields.io/badge/License-BSD--2--Clause-green)]()
[![GitHub Pages](https://img.shields.io/badge/Hosted-GitHub%20Pages-brightgreen)]()

`opn-mihomo` 是专为 OPNsense 防火墙打造的 Mihomo 代理集成插件（`os-mihomo`）官方维护仓库。本项目源自 `Opnwall/OPNsense-repo` 多插件市场形态，现由本仓库作者（DJBoy520）独立维护，聚焦于 `os-mihomo` 插件的质量、安全更新、自动化构建与全生命周期运维。

---

## 支持矩阵

| 系统 / 架构 | 运行环境 | 支持状态 | 说明 |
| :--- | :--- | :--- | :--- |
| **OPNsense 26.7+** | FreeBSD 15 (amd64) | **官方支持** | 默认提供二进制预编译包（FreeBSD:15:amd64） |
| **OPNsense 25.7 及以下** | FreeBSD 14 (amd64) | 计划中 | 待后续环境充分测试适配后提供 |

---

## 安装方法（三步快速上手）

在 OPNsense 终端（通过 SSH 或 控制台）执行以下命令：

### 第 1 步：添加软件源配置

```sh
fetch -o /usr/local/etc/pkg/repos/opn-mihomo.conf https://djboy520.github.io/opn-mihomo/opn-mihomo.conf
```

### 第 2 步：刷新软件源索引

```sh
pkg update -f
```

### 第 3 步：安装插件

通过命令行直接安装：
```sh
pkg install -r opn-mihomo os-mihomo
```
或者进入 OPNsense WebGUI 管理界面：
> **系统 (System)** ➔ **固件 (Firmware)** ➔ **插件 (Plugins)** ➔ 搜索并安装 `os-mihomo`。

---

## 内置组件与内核要求（hev-socks5-tunnel & if_tun）

1. **透明代理分流组件**：`os-mihomo` 安装包内已内置预编译好的 `hev-socks5-tunnel` 二进制程序，无需手动额外安装第三方依赖。
2. **内核模块 `if_tun`**：透明代理模式依赖 FreeBSD 的 `if_tun` 内核虚拟网络接口模块。插件服务管理脚本（`rc.d/mihomo_hev`）在启动时会自动检测并幂等加载（`kldload -q if_tun`），确保开箱即用。

---

## 软件源安全说明（Unsigned 仓库）

本仓库当前以 **Unsigned（未配置 RSA 私钥签名）** 模式分发。安全与完整性通过以下机制保障：
- **全链路 HTTPS 传输加密**：软件源由 GitHub Pages 通过 TLS 强加密传输，防止内容在传输途中被篡改或窃听。
- **发布产物 SHA-256 对账**：每次 Release 或构建均伴随官方 SHA256 哈希校验流程。
- **未签名原因**：降低自动化 CI/CD 与个人分发维护复杂度；后续规划将在引入安全密钥管线后升级支持 pkg 指纹签名。

---

## 卸载与清理

如需彻底移除 `os-mihomo` 插件及软件源：

```sh
# 1. 卸载插件本体
pkg delete os-mihomo

# 2. 清理仓库配置文件
rm -f /usr/local/etc/pkg/repos/opn-mihomo.conf
pkg update -f
```

> **备份留档说明**：卸载脚本会在 `/root/` 目录下生成类似 `/root/os-mihomo-removed-YYYYMMDD_HHMMSS/` 的备份归档目录，保存原有配置及运行状态文件以防误删；用户确认无需恢复后可手动清理该目录。

---

## 从旧源（opnwall.conf）平滑迁移

若此前已安装过来自 `opnwall` 源的插件，请按照以下步骤迁移至本仓库源：

```sh
# 1. 移除旧源配置文件
rm -f /usr/local/etc/pkg/repos/opnwall.conf

# 2. 添加新源并刷新
fetch -o /usr/local/etc/pkg/repos/opn-mihomo.conf https://djboy520.github.io/opn-mihomo/opn-mihomo.conf
pkg update -f

# 3. 强制重装插件以刷新软件源归属标记
pkg install -r opn-mihomo -f os-mihomo
```

---

## 本地构建与自动化门禁

本项目包含完整的本地打包与质量门禁脚本：

```sh
# 1. 运行质量与安全门禁
sh tests/test_syntax.sh
sh tests/test_uninstall_hygiene.sh
sh tests/test_no_sensitive.sh
sh tests/test_repo_hygiene.sh

# 2. 构建插件包（支持本地或容器/VM 环境）
bash scripts/build.sh
```

---

## 许可协议与免责声明

- **插件代码**：遵循 [BSD-2-Clause](LICENSE) 许可协议。
- **第三方组件**：Mihomo、hev-socks5-tunnel 等第三方组件遵循其各自的开源许可协议。
- **免责声明**：本项目为独立开源社区项目，**与 Deciso B.V. 及 OPNsense 官方团队无任何隶属或官方背书关系**。请在生产环境部署前完成充分测试。
