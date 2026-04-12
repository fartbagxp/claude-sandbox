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
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
RUNTIME_DIR="${REPO_ROOT}/run"
CH_BINARY="${CH_BINARY:-/usr/local/bin/cloud-hypervisor}"
VIRTIOFSD_BINARY="${VIRTIOFSD_BINARY:-$(command -v virtiofsd)}"

# --- VM Resources ---
VM_CPUS="boot=4"
VM_MEMORY="size=8G,shared=on"

# --- VM Image ---
KERNEL_PATH="${BUILD_DIR}/vmlinux"
INITRD_PATH="${BUILD_DIR}/initrd.img"
ROOTFS_PATH="${BUILD_DIR}/rootfs.raw"

# --- Filesystem Sharing ---
# Format: "tag:host_path:mode" where mode is "rw" or "ro"
VIRTIOFS_MOUNTS=(
    "workspace:$REAL_HOME/work:rw"
    "claude-config:$REAL_HOME/.claude:ro"
)

# --- Allowlist ---
ALLOWLIST_FILE="${REPO_ROOT}/config/allowlist.txt"

# --- Sockets (derived, do not edit) ---
CH_API_SOCKET="${RUNTIME_DIR}/ch-api.sock"
DNSMASQ_PIDFILE="${RUNTIME_DIR}/dnsmasq.pid"
DNSMASQ_CONF="${RUNTIME_DIR}/dnsmasq.conf"
DNSMASQ_NFTSET_CONF="${RUNTIME_DIR}/dnsmasq-nftset.conf"
