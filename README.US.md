<div align="center">
  <a href="README.md">中文</a> |
  <a href="README.US.md">English</a>
</div>

# opn-mihomo

**Mihomo (Clash Meta) Integration Plugin & Package Repository for OPNsense**

[![OPNsense](https://img.shields.io/badge/OPNsense-26.7%2B-orange)]()
[![Platform](https://img.shields.io/badge/Platform-FreeBSD%2015%20amd64-blue)]()
[![License](https://img.shields.io/badge/License-BSD--2--Clause-green)]()
[![GitHub Pages](https://img.shields.io/badge/Hosted-GitHub%20Pages-brightgreen)]()

`opn-mihomo` is the dedicated repository for the `os-mihomo` plugin on OPNsense. Originally derived from the multi-plugin marketplace `Opnwall/OPNsense-repo`, this project is now independently maintained by DJBoy520 with a laser focus on `os-mihomo` quality, security patching, CI automation, and lifecycle maintenance.

---

## Support Matrix

| OS / Architecture | Underlying Base | Status | Notes |
| :--- | :--- | :--- | :--- |
| **OPNsense 26.7+** | FreeBSD 15 (amd64) | **Supported** | Precompiled binary repository provided (FreeBSD:15:amd64) |
| **OPNsense 25.7 & earlier** | FreeBSD 14 (amd64) | Planned | Pending full validation and testing |

---

## Installation (3-Step Quick Start)

Run the following commands in the OPNsense shell (via SSH or Console):

### Step 1: Add Repository Configuration

```sh
fetch -o /usr/local/etc/pkg/repos/opn-mihomo.conf https://djboy520.github.io/opn-mihomo/opn-mihomo.conf
```

### Step 2: Update Package Repository Index

```sh
pkg update -f
```

### Step 3: Install the Plugin

Install directly via CLI:
```sh
pkg install -r opn-mihomo os-mihomo
```
Or open the OPNsense WebGUI:
> **System** ➔ **Firmware** ➔ **Plugins** ➔ Search for `os-mihomo` and click Install.

---

## Bundled Dependencies & Kernel Requirements (hev-socks5-tunnel & if_tun)

1. **Bundled Transparent Proxy Helper**: The `os-mihomo` package bundles the official `hev-socks5-tunnel` binary out-of-the-box, eliminating manual external dependency setups.
2. **Kernel Module `if_tun`**: Transparent proxy routing requires FreeBSD's `if_tun` kernel virtual interface module. The service script (`rc.d/mihomo_hev`) automatically and idempotently loads it on startup (`kldload -q if_tun`).

---

## Repository Security Notice (Unsigned Repository)

This package repository is currently published in **Unsigned mode (without pkg RSA signature keys)**. Integrity and security are preserved via:
- **HTTPS/TLS Transport Encryption**: Packages and catalogs are delivered over GitHub Pages HTTPS TLS encryption to prevent transit tampering.
- **SHA-256 Checksum Verification**: Every package release undergoes SHA-256 integrity audits against upstream release binaries.
- **Reason for Unsigned State**: Keeps automated CI/CD and independent publishing pipelines lightweight; pkg signature keyrings may be adopted in future releases.

---

## Uninstallation & Cleanup

To completely remove `os-mihomo` and the repository configuration:

```sh
# 1. Remove the plugin package
pkg delete os-mihomo

# 2. Delete repository configuration
rm -f /usr/local/etc/pkg/repos/opn-mihomo.conf
pkg update -f
```

> **Archive Notice**: The deinstallation hook automatically archives leftover configurations and runtime states under `/root/os-mihomo-removed-YYYYMMDD_HHMMSS/` for disaster recovery. You may delete that directory once you confirm it is no longer needed.

---

## Migrating from Legacy opnwall.conf

If you previously installed packages using the legacy `opnwall` repository configuration:

```sh
# 1. Remove old repository configuration
rm -f /usr/local/etc/pkg/repos/opnwall.conf

# 2. Add new repository configuration and update
fetch -o /usr/local/etc/pkg/repos/opn-mihomo.conf https://djboy520.github.io/opn-mihomo/opn-mihomo.conf
pkg update -f

# 3. Force-reinstall to update package repository tracking
pkg install -r opn-mihomo -f os-mihomo
```

---

## Local Build & Quality Gates

The repository includes a comprehensive test and build suite:

```sh
# 1. Run hygiene and security test gates
sh tests/test_syntax.sh
sh tests/test_uninstall_hygiene.sh
sh tests/test_no_sensitive.sh
sh tests/test_repo_hygiene.sh

# 2. Build plugin package (local or FreeBSD VM environment)
bash scripts/build.sh
```

---

## License & Disclaimer

- **Plugin Code**: Licensed under the [BSD-2-Clause](LICENSE) License.
- **Third-Party Components**: Mihomo, hev-socks5-tunnel, and other bundled assets adhere to their respective open source licenses.
- **Disclaimer**: This is an independent open-source project and is **not affiliated with or endorsed by Deciso B.V. or the official OPNsense team**. Please verify thoroughly in staging environments before production rollout.
