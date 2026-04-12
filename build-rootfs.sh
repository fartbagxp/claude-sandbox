#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config/config.sh"

echo "Building Claude sandbox guest rootfs..."
mkdir -p "$BUILD_DIR"

ROOTFS_SIZE="20G"

virt-builder debian-13 \
    --output "$ROOTFS_PATH" \
    --format raw \
    --size "$ROOTFS_SIZE" \
    --root-password password:sandbox \
    --run-command 'apt-get update && apt-get install -y openssh-server sudo nodejs npm python3 python3-pip git make g++ curl wget' \
    --run-command 'npm install -g @anthropic-ai/claude-code' \
    --run-command 'useradd -m -s /bin/bash claude' \
    --run-command 'echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude' \
    --ssh-inject claude:file:"$(ls "$REAL_HOME/.ssh/id_ed25519.pub" "$REAL_HOME/.ssh/id_rsa.pub" 2>/dev/null | head -1)" \
    --run-command 'systemctl enable ssh' \
    --hostname claude-sandbox \
    --run-command 'apt-get purge -y dhcpcd-base dhcpcd-common || true' \
    --run-command 'systemctl enable systemd-networkd' \
    --write "/etc/systemd/network/10-eth0.network:[Match]
Name=eth0

[Network]
Address=${GUEST_IP}/24
Gateway=${HOST_IP}
DNS=${HOST_IP}
" \
    --run-command 'mkdir -p /workspace /etc/claude' \
    --write "/etc/fstab:workspace /workspace virtiofs defaults,nofail 0 0
claude-config /etc/claude virtiofs ro,nofail 0 0
" \
    # IMPORTANT: resolv.conf MUST be set via --write, not --run-command.
    # libguestfs's daemon/sh.c (set_up_etc_resolv_conf) renames the guest's
    # /etc/resolv.conf to a backup, copies in the appliance's resolv.conf
    # (with the host's DHCP DNS), runs the command, then restores the backup.
    # Any writes to /etc/resolv.conf during --run-command are silently discarded.
    # --write uses the guestfs API directly, bypassing this rename/restore cycle.
    --write "/etc/resolv.conf:nameserver ${HOST_IP}
"

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
