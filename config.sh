#!/usr/bin/env bash
# claude-sandbox configuration
# All paths and parameters used by the sandbox scripts.

# --- Networking ---
TAP_DEV="claude-tap0"
HOST_IP="172.16.0.1"
GUEST_IP="172.16.0.2"
SUBNET_MASK="255.255.255.0"
SUBNET_CIDR="172.16.0.0/24"
DNS_UPSTREAM="8.8.8.8"

# --- Resolve real user home (works whether invoked with sudo or not) ---
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# --- Paths ---
SANDBOX_DIR="${SANDBOX_DIR:-$REAL_HOME/.claude-sandbox}"
RUNTIME_DIR="${SANDBOX_DIR}/run"
CH_BINARY="${CH_BINARY:-/usr/local/bin/cloud-hypervisor}"
VIRTIOFSD_BINARY="${VIRTIOFSD_BINARY:-$(command -v virtiofsd)}"

# --- VM Resources ---
VM_CPUS="boot=4"
VM_MEMORY="size=8G,shared=on"

# --- VM Image ---
KERNEL_PATH="${SANDBOX_DIR}/vmlinux"
INITRD_PATH="${SANDBOX_DIR}/initrd.img"
ROOTFS_PATH="${SANDBOX_DIR}/rootfs.raw"

# --- Filesystem Sharing ---
# Format: "tag:host_path:mode" where mode is "rw" or "ro"
VIRTIOFS_MOUNTS=(
    "workspace:$REAL_HOME/work:rw"
    "claude-config:$REAL_HOME/.claude:ro"
)

# --- Claude Settings (source of hostname allowlist) ---
CLAUDE_SETTINGS="${REAL_HOME}/.claude/settings.json"

# --- Sockets (derived, do not edit) ---
CH_API_SOCKET="${RUNTIME_DIR}/ch-api.sock"
DNSMASQ_PIDFILE="${RUNTIME_DIR}/dnsmasq.pid"
DNSMASQ_CONF="${RUNTIME_DIR}/dnsmasq.conf"
DNSMASQ_NFTSET_CONF="${RUNTIME_DIR}/dnsmasq-nftset.conf"
