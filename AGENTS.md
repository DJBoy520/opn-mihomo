# opn-mihomo 仓库工作规则

## 自动提交推送（用户 2026-10-25 明确要求，长期有效，无需再次提醒）

- 每完成一个可提交的变更单元（构建/门禁通过后），**立即** `git commit`；本批工作收尾时 `git push origin main`。不要等用户提醒，不要逐次询问。
- 提交信息：中文 conventional 风格（`fix:` / `feat:` / `docs:`），标题带版本号（如适用），正文写动机与验证方式，参照既有历史风格。
- 红线：
  - `.private/`、`work/`、凭据、密钥、口令严禁入库（.gitignore 已覆盖，不得添加例外）；
  - 推送目标只认 **origin（DJBoy520/opn-mihomo）**；旧仓库 DJBoy520/OPNsense-repo 已转 Private 作历史存档，不得对其推送；upstream（Opnwall/OPNsense-repo）历史已分叉，未经用户明确决策不得对 upstream 做任何 push / merge / force 操作。

## 环境速查

- 测试 VM：见 `.private/deploy.conf`（gitignored，模板在 `scripts/deploy.conf.example`）（SSH 密钥直连，root shell 是 **csh**——一律 `ssh ... 'sh -s' <<'EOF'` heredoc）。
- 生产机：见 `.private/deploy.conf`（gitignored，模板在 `scripts/deploy.conf.example`）（WebGUI，SSH 密钥直连），改动需谨慎，登记类幂等操作除外。
- 构建入口：`bash scripts/build.sh`（版本真源 `src/os-mihomo/src/usr/local/opnsense/version/mihomo` + `Makefile` 两处同步）；`pkg repo` 元数据重建需 FreeBSD 环境（在 VM 上跑 `build-repo.sh`，记得传 `REPO_ROOT`）。
