#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config/config.sh"

echo "Building Claude sandbox guest rootfs..."
mkdir -p "$BUILD_DIR"

ROOTFS_SIZE="20G"

# --- Read package lists from config/packages.txt ---
if [ ! -f "$PACKAGES_FILE" ]; then
    echo "ERROR: Packages file not found at ${PACKAGES_FILE}" >&2
    echo "  Copy the example: cp config/packages.txt.example config/packages.txt" >&2
    exit 1
fi

# Parse sections: [apt], [npm], [pip]
current_section=""
apt_packages=()
npm_packages=()
pip_packages=()
while IFS= read -r line; do
    # Strip comments and whitespace
    line="${line%%#*}"
    line="${line// /}"
    [[ -z "$line" ]] && continue
    case "$line" in
        "[apt]") current_section="apt"; continue ;;
        "[npm]") current_section="npm"; continue ;;
        "[pip]") current_section="pip"; continue ;;
    esac
    case "$current_section" in
        apt) apt_packages+=("$line") ;;
        npm) npm_packages+=("$line") ;;
        pip) pip_packages+=("$line") ;;
    esac
done < "$PACKAGES_FILE"

echo "  apt packages: ${apt_packages[*]}"
echo "  npm packages: ${npm_packages[*]}"
echo "  pip packages: ${pip_packages[*]}"

# --- Resolve host user identity for guest user creation ---
GUEST_USER="$REAL_USER"
GUEST_UID="$(id -u "$REAL_USER")"
GUEST_GID="$(id -g "$REAL_USER")"
echo "  Guest user: ${GUEST_USER} (uid=${GUEST_UID}, gid=${GUEST_GID})"

# --- Build virt-builder command ---
VB_ARGS=(
    debian-13
    --output "$ROOTFS_PATH"
    --format raw
    --size "$ROOTFS_SIZE"
    --root-password password:sandbox
)

# Install apt packages
if [ ${#apt_packages[@]} -gt 0 ]; then
    VB_ARGS+=(--run-command "apt-get update && apt-get install -y ${apt_packages[*]}")
fi

# Install npm packages
for pkg in "${npm_packages[@]}"; do
    VB_ARGS+=(--run-command "npm install -g ${pkg}")
done

# Install pip packages
if [ ${#pip_packages[@]} -gt 0 ]; then
    VB_ARGS+=(--run-command "pip3 install --break-system-packages ${pip_packages[*]}")
fi

# Create guest user matching host UID/GID
VB_ARGS+=(
    --run-command "groupadd -g ${GUEST_GID} ${GUEST_USER} 2>/dev/null || true"
    --run-command "useradd -m -s /bin/bash -u ${GUEST_UID} -g ${GUEST_GID} ${GUEST_USER}"
    --run-command "echo '${GUEST_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${GUEST_USER}"
)

# SSH key injection
SSH_PUBKEY=""
for key in "$REAL_HOME/.ssh/id_ed25519.pub" "$REAL_HOME/.ssh/id_rsa.pub"; do
    [[ -f "$key" ]] && SSH_PUBKEY="$key" && break
done
if [ -n "$SSH_PUBKEY" ]; then
    VB_ARGS+=(--ssh-inject "${GUEST_USER}:file:${SSH_PUBKEY}")
fi

# Network and system config
VB_ARGS+=(
    --run-command 'systemctl enable ssh'
    --hostname claude-sandbox
    --run-command 'apt-get purge -y dhcpcd-base dhcpcd-common || true'
    --run-command 'systemctl enable systemd-networkd'
    --run-command 'mkdir -p /workspace /etc/claude'
)

# --write args with embedded newlines must be appended individually
NETWORK_CFG="[Match]
Name=eth0

[Network]
Address=${GUEST_IP}/24
Gateway=${HOST_IP}
DNS=${HOST_IP}
"
VB_ARGS+=(--write "/etc/systemd/network/10-eth0.network:${NETWORK_CFG}")

FSTAB_CFG="workspace /workspace virtiofs defaults,nofail 0 0
claude-config /etc/claude virtiofs ro,nofail 0 0
"
VB_ARGS+=(--write "/etc/fstab:${FSTAB_CFG}")

# resolv.conf MUST be set via --write, not --run-command.
# libguestfs's daemon/sh.c renames /etc/resolv.conf during --run-command,
# so any writes to it are silently discarded. --write bypasses this.
VB_ARGS+=(--write "/etc/resolv.conf:nameserver ${HOST_IP}
")

virt-builder "${VB_ARGS[@]}"

echo "Rootfs built at ${ROOTFS_PATH}"

# Extract the guest kernel and initramfs from the rootfs so cloud-hypervisor
# can boot them. This ensures the kernel and /lib/modules always match.
echo "Extracting guest kernel and initramfs..."
GUEST_KERNEL=$(virt-ls -a "$ROOTFS_PATH" /boot/ | grep '^vmlinuz-' | sort -V | tail -1)
GUEST_INITRD=$(virt-ls -a "$ROOTFS_PATH" /boot/ | grep '^initrd.img-' | sort -V | tail -1)
if [ -z "$GUEST_KERNEL" ] || [ -z "$GUEST_INITRD" ]; then
    echo "ERROR: Could not find vmlinuz or initrd.img in guest /boot/" >&2
    exit 1
fi
virt-cat -a "$ROOTFS_PATH" "/boot/${GUEST_KERNEL}" > "$KERNEL_PATH"
virt-cat -a "$ROOTFS_PATH" "/boot/${GUEST_INITRD}" > "$INITRD_PATH"
echo "  Kernel:  ${GUEST_KERNEL} → ${KERNEL_PATH}"
echo "  Initrd:  ${GUEST_INITRD} → ${INITRD_PATH}"
echo "Done."
