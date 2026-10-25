#!/bin/sh
set -eu

# scripts/publish-repo.sh
# os-mihomo 插件包发布进 FreeBSD pkg 自定义仓库
#
# 用法:
#   sh scripts/publish-repo.sh <path/to/os-mihomo-X.Y.Z.pkg>
#   sh scripts/publish-repo.sh --seed
#
# 设计要点与环境约束：
# 1. 读 .private/deploy.conf（VM_HOST/PROD_HOST/REPO_ABI），配置文件为唯一真源，显式校验非空。
# 2. 本地校验包存在及 +MANIFEST 元数据 (%n=os-mihomo)。
# 3. VM 环境约束：Live ISO（/ 只读、/usr 可写、/tmp ~300MB）、无 rsync、无 git、root shell 为 csh。
#    远程操作一律使用 ssh root@"$VM_HOST" 'sh -s' <<'EOF' ... EOF。
# 4. 远端暂存目录 /usr/local/opn-repo。发布前检查 /usr 余量 ≥ 2× 传输体积。
# 5. 远端 pkg repo 重建元数据后，回传 meta, meta.conf, packagesite.pkg, data.pkg 到本地，原子替换。
# 6. flock /tmp/opn-publish.lock 防并发，trap 清理临时文件与远端 .tmp。

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

# -------------------------------------------------------------
# 0. 并发锁 (flock)
# -------------------------------------------------------------
LOCK_FILE="/tmp/opn-publish.lock"
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "ERROR: Another publish-repo process is currently running (lock: $LOCK_FILE)." >&2
        exit 1
    fi
fi

# -------------------------------------------------------------
# 1. 配置加载与锁死 (唯一真源)
# -------------------------------------------------------------
CONF_FILE="$ROOT_DIR/.private/deploy.conf"
if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONF_FILE" >&2
    echo "Please copy the template and configure your environment:" >&2
    echo "  cp scripts/deploy.conf.example .private/deploy.conf" >&2
    exit 1
fi

# 清除环境变量防止反向覆盖
unset VM_HOST VM_USER PROD_HOST PROD_PORT PROD_USER REPO_ABI

# 读取配置文件
# shellcheck disable=SC1090
. "$CONF_FILE"

# 显式校验必要变量非空
: "${VM_HOST:?Variable VM_HOST must be set in .private/deploy.conf (see scripts/deploy.conf.example)}"
: "${REPO_ABI:?Variable REPO_ABI must be set in .private/deploy.conf (see scripts/deploy.conf.example)}"
VM_USER="${VM_USER:-root}"

SSH_TARGET="${VM_USER}@${VM_HOST}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

# -------------------------------------------------------------
# 2. 参数解析与本地前置校验
# -------------------------------------------------------------
SEED_MODE=0
PKG_PATH=""

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <path/to/os-mihomo-X.Y.Z.pkg>" >&2
    echo "       $0 --seed" >&2
    exit 1
fi

if [ "$1" = "--seed" ]; then
    SEED_MODE=1
else
    PKG_PATH="$1"
fi

LOCAL_REPO_ABI_DIR="$ROOT_DIR/repo/$REPO_ABI"
VM_REPO_BASE="/usr/local/opn-repo"
VM_REPO_ABI_DIR="$VM_REPO_BASE/$REPO_ABI"

# 临时目录管理与清理 trap
LOCAL_TMP_DIR="$(mktemp -d /tmp/opn-publish-meta.XXXXXX)"
REMOTE_TMP_CLEANUP=""

cleanup() {
    rm -rf "$LOCAL_TMP_DIR"
    if [ -n "$REMOTE_TMP_CLEANUP" ]; then
        # 尽力清理远端残余临时文件
        ssh $SSH_OPTS "$SSH_TARGET" "sh -s" >/dev/null 2>&1 <<EOF || true
rm -f $REMOTE_TMP_CLEANUP
EOF
    fi
}
trap cleanup EXIT INT TERM

# -------------------------------------------------------------
# 3. 播种模式 (--seed)
# -------------------------------------------------------------
if [ "$SEED_MODE" -eq 1 ]; then
    echo "===> Running --seed mode: Initializing VM staging directory from local repo tree..."
    if [ ! -d "$LOCAL_REPO_ABI_DIR" ]; then
        echo "ERROR: Local repo directory $LOCAL_REPO_ABI_DIR does not exist." >&2
        exit 1
    fi

    # 计算本地 repo/$REPO_ABI 体积 (MB)
    LOCAL_TREE_MB="$(du -sm "$LOCAL_REPO_ABI_DIR" | cut -f1)"
    [ "$LOCAL_TREE_MB" -lt 1 ] && LOCAL_TREE_MB=1
    REQUIRED_MB=$(( LOCAL_TREE_MB * 2 ))
    echo "--> Local repo tree size: ${LOCAL_TREE_MB}MB (Required VM /usr free space: >= ${REQUIRED_MB}MB)"

    # 检查 VM 连通性并检查 /usr 余量
    echo "--> Checking VM connection and /usr free space..."
    VM_USR_FREE_MB=$(ssh $SSH_OPTS "$SSH_TARGET" 'sh -s' <<'EOF'
set -eu
df -m /usr | tail -1 | awk '{print $4}'
EOF
)
    echo "--> VM /usr available: ${VM_USR_FREE_MB}MB"
    if [ "$VM_USR_FREE_MB" -lt "$REQUIRED_MB" ]; then
        echo "ERROR: Insufficient free space on VM /usr (${VM_USR_FREE_MB}MB available, required ${REQUIRED_MB}MB)." >&2
        exit 1
    fi

    # 打包本地 repo/$REPO_ABI 整树经 ssh 写入 VM 暂存目录
    # 注意：管道传输不能用 'sh -s' <<EOF 形式——heredoc 会覆盖管道 stdin，
    # 远端 tar 读到的是 heredoc 剩余字节而非数据流；必须用直接远端命令。
    echo "--> Transferring repo tree to VM $VM_REPO_ABI_DIR..."
    tar -C "$ROOT_DIR/repo" -cf - "$REPO_ABI" | ssh $SSH_OPTS "$SSH_TARGET" "mkdir -p '$VM_REPO_BASE' && tar -xpf - -C '$VM_REPO_BASE'"

    echo "--> Verifying staged files on VM..."
    ssh $SSH_OPTS "$SSH_TARGET" 'sh -s' <<EOF
set -eu
if [ ! -d "$VM_REPO_ABI_DIR/All" ]; then
    echo "ERROR: $VM_REPO_ABI_DIR/All missing after seed." >&2
    exit 1
fi
echo "Seeded contents in $VM_REPO_ABI_DIR:"
ls -la "$VM_REPO_ABI_DIR"
EOF

    echo "===> --seed completed successfully. Staging directory ready."
    exit 0
fi

# -------------------------------------------------------------
# 4. 常规发布模式：包检查与元数据验证
# -------------------------------------------------------------
if [ ! -f "$PKG_PATH" ]; then
    echo "ERROR: Package file not found: $PKG_PATH" >&2
    exit 1
fi

PKG_FILENAME="$(basename "$PKG_PATH")"
PKG_SIZE_BYTES="$(wc -c < "$PKG_PATH" | tr -d ' ')"
PKG_SIZE_MB=$(( PKG_SIZE_BYTES / 1048576 + 1 ))
PKG_SHA256="$(sha256sum "$PKG_PATH" | awk '{print $1}')"

echo "===> Preparing to publish $PKG_FILENAME..."
echo "  Path:   $PKG_PATH"
echo "  Size:   ${PKG_SIZE_MB}MB (${PKG_SIZE_BYTES} bytes)"
echo "  SHA256: $PKG_SHA256"

# 提取 +MANIFEST 并校验包名是否为 os-mihomo
echo "--> Verifying package metadata (+MANIFEST)..."
MANIFEST_NAME="$(tar -xOf "$PKG_PATH" +MANIFEST 2>/dev/null | awk -F': ' '/^name:[[:space:]]*/ { gsub(/["'\'' ]/, "", $2); print $2; exit }' || true)"
MANIFEST_VERSION="$(tar -xOf "$PKG_PATH" +MANIFEST 2>/dev/null | awk -F': ' '/^version:[[:space:]]*/ { gsub(/["'\'' ]/, "", $2); print $2; exit }' || true)"

if [ "$MANIFEST_NAME" != "os-mihomo" ]; then
    echo "ERROR: Invalid package name in +MANIFEST: '$MANIFEST_NAME' (expected: 'os-mihomo')." >&2
    exit 1
fi
if [ -z "$MANIFEST_VERSION" ]; then
    echo "ERROR: Missing version in package +MANIFEST." >&2
    exit 1
fi
echo "  [PASS] Valid os-mihomo package (version: $MANIFEST_VERSION)."

# -------------------------------------------------------------
# 5. VM 预检：暂存目录与磁盘余量
# -------------------------------------------------------------
echo "--> Inspecting VM staging directory and disk space..."
REQUIRED_PKG_MB=$(( PKG_SIZE_MB * 2 ))

VM_CHECK_OUTPUT=$(ssh $SSH_OPTS "$SSH_TARGET" 'sh -s' <<EOF
set -eu
if [ ! -d "$VM_REPO_ABI_DIR/All" ]; then
    echo "ERR_NO_SEED"
    exit 0
fi
FREE_MB=\$(df -m /usr | tail -1 | awk '{print \$4}')
echo "OK \$FREE_MB"
EOF
)

case "$VM_CHECK_OUTPUT" in
    ERR_NO_SEED*)
        echo "ERROR: VM staging directory $VM_REPO_ABI_DIR/All does not exist." >&2
        echo "Please seed the repository tree first by running:" >&2
        echo "  $0 --seed" >&2
        exit 1
        ;;
    OK*)
        VM_FREE_MB=$(echo "$VM_CHECK_OUTPUT" | awk '{print $2}')
        echo "--> VM /usr available: ${VM_FREE_MB}MB (Required: >= ${REQUIRED_PKG_MB}MB)"
        if [ "$VM_FREE_MB" -lt "$REQUIRED_PKG_MB" ]; then
            echo "ERROR: Insufficient disk space on VM /usr (${VM_FREE_MB}MB free, required ${REQUIRED_PKG_MB}MB)." >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: Unexpected response from VM: $VM_CHECK_OUTPUT" >&2
        exit 1
        ;;
esac

# -------------------------------------------------------------
# 6. 上传包文件、校验并原子替换旧版本
# -------------------------------------------------------------
REMOTE_TMP_PKG="$VM_REPO_ABI_DIR/All/${PKG_FILENAME}.tmp.$$"
REMOTE_DEST_PKG="$VM_REPO_ABI_DIR/All/$PKG_FILENAME"
REMOTE_TMP_CLEANUP="$REMOTE_TMP_PKG"

echo "--> Uploading $PKG_FILENAME to VM ($REMOTE_TMP_PKG)..."
# 同理：数据流传输用直接远端命令 + 本地输入重定向，避免 heredoc 抢占 stdin
ssh $SSH_OPTS "$SSH_TARGET" "cat > '$REMOTE_TMP_PKG'" < "$PKG_PATH"

echo "--> Verifying SHA256 checksum and replacing package on VM..."
ssh $SSH_OPTS "$SSH_TARGET" "sh -s" <<EOF
set -eu
REMOTE_HASH=\$(sha256 -q "$REMOTE_TMP_PKG" 2>/dev/null || sha256sum "$REMOTE_TMP_PKG" | awk '{print \$1}')
if [ "\$REMOTE_HASH" != "$PKG_SHA256" ]; then
    echo "ERROR: SHA256 mismatch on VM! Local: $PKG_SHA256, Remote: \$REMOTE_HASH" >&2
    rm -f "$REMOTE_TMP_PKG"
    exit 1
fi

# 移除旧版 os-mihomo 包（保留其他可能存在的依赖包，但只留这一个新版 os-mihomo）
for old_pkg in "$VM_REPO_ABI_DIR/All"/os-mihomo-*.pkg; do
    if [ -f "\$old_pkg" ]; then
        rm -f "\$old_pkg"
    fi
done

# 原子 mv 到正式文件名
mv "$REMOTE_TMP_PKG" "$REMOTE_DEST_PKG"
echo "VM package installed: $REMOTE_DEST_PKG"
EOF

# 上传并校验成功后，清空半成品清理变量
REMOTE_TMP_CLEANUP=""

# -------------------------------------------------------------
# 7. 远端 pkg repo 重建元数据
# -------------------------------------------------------------
echo "--> Rebuilding pkg repo metadata on VM..."
ssh $SSH_OPTS "$SSH_TARGET" "sh -s" <<EOF
set -eu
if ! command -v pkg >/dev/null 2>&1; then
    echo "ERROR: 'pkg' command not found on VM." >&2
    exit 1
fi

# 重建元数据
pkg repo "$VM_REPO_ABI_DIR"
echo "pkg repo successfully finished on VM."
EOF

# -------------------------------------------------------------
# 8. 回传元数据文件并进行本地原子替换
# -------------------------------------------------------------
echo "--> Downloading generated repository metadata to local temporary staging..."
# 元数据文件清单：meta, meta.conf, packagesite.pkg, data.pkg
# 注意：符号链接 packagesite.tzst -> packagesite.pkg, data.tzst -> data.pkg 本地保留
for meta_file in meta meta.conf packagesite.pkg data.pkg; do
    ssh $SSH_OPTS "$SSH_TARGET" "sh -s" <<EOF > "$LOCAL_TMP_DIR/$meta_file"
set -eu
if [ ! -f "$VM_REPO_ABI_DIR/$meta_file" ]; then
    echo "ERROR: $meta_file missing on VM!" >&2
    exit 1
fi
cat "$VM_REPO_ABI_DIR/$meta_file"
EOF

    if [ ! -s "$LOCAL_TMP_DIR/$meta_file" ]; then
        echo "ERROR: Downloaded $meta_file is empty or missing!" >&2
        exit 1
    fi
    echo "  [OK] Downloaded $meta_file ($(wc -c < "$LOCAL_TMP_DIR/$meta_file" | tr -d ' ') bytes)"
done

# 同时更新本地 repo/$REPO_ABI/All 下的 pkg 文件，与 VM 保持完全一致
echo "--> Updating local package in $LOCAL_REPO_ABI_DIR/All/..."
mkdir -p "$LOCAL_REPO_ABI_DIR/All"
for old_local in "$LOCAL_REPO_ABI_DIR/All"/os-mihomo-*.pkg; do
    if [ -f "$old_local" ]; then
        rm -f "$old_local"
    fi
done
cp -f "$PKG_PATH" "$LOCAL_REPO_ABI_DIR/All/$PKG_FILENAME"

# 本地原子替换元数据
echo "--> Atomically replacing local repository metadata files in $LOCAL_REPO_ABI_DIR..."
for meta_file in meta meta.conf packagesite.pkg data.pkg; do
    mv -f "$LOCAL_TMP_DIR/$meta_file" "$LOCAL_REPO_ABI_DIR/$meta_file"
done

# 确保符号链接存在
(
    cd "$LOCAL_REPO_ABI_DIR"
    [ -L packagesite.tzst ] || ln -sf packagesite.pkg packagesite.tzst
    [ -L data.tzst ] || ln -sf data.pkg data.tzst
)

echo "===> Repository update completed successfully!"
echo ""
echo "--------------------------------------------------------"
echo "待 git 提交的文件清单提示（本脚本不执行 git 提交）："
echo "  - repo/$REPO_ABI/All/$PKG_FILENAME"
echo "  - repo/$REPO_ABI/meta"
echo "  - repo/$REPO_ABI/meta.conf"
echo "  - repo/$REPO_ABI/packagesite.pkg"
echo "  - repo/$REPO_ABI/data.pkg"
echo "--------------------------------------------------------"
echo "请主控按既定发布流程核对上述文件并提交。"
exit 0
