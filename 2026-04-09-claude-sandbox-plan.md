# Claude Code Sandbox Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a launch script that runs Claude Code inside a cloud-hypervisor microVM with hostname-based egress filtering, so Claude can operate with full autonomous permissions while being safely sandboxed.

**Architecture:** A bash orchestration script (`claude-sandbox`) manages the lifecycle of: (1) a TAP network device with nftables egress rules, (2) a dnsmasq instance that populates an nftables IP set from a hostname allowlist, (3) two virtiofsd daemons (rw + ro), and (4) a cloud-hypervisor VM. A separate rootfs build script produces the guest disk image.

**Tech Stack:** Bash, cloud-hypervisor, virtiofsd, dnsmasq, nftables, jq, cloud-init (for guest provisioning)

---

## Prerequisites

Before starting, install these on the Fedora 43 host:

```bash
# cloud-hypervisor static binary
wget https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/cloud-hypervisor-static -O /usr/local/bin/cloud-hypervisor
chmod +x /usr/local/bin/cloud-hypervisor
sudo setcap cap_net_admin+ep /usr/local/bin/cloud-hypervisor

# virtiofsd (Rust version)
cargo install virtiofsd
# Or from distro: sudo dnf install virtiofsd (if available)

# dnsmasq (v2.87+ required for nftset, Fedora 43 has v2.92)
sudo dnf install dnsmasq

# Other tools
sudo dnf install jq nftables qemu-img cloud-utils
```

Also ensure KVM is available: `ls /dev/kvm` should exist.

---

## Task 1: Project Scaffolding

**Files:**
- Create: `claude-sandbox/claude-sandbox.sh`
- Create: `claude-sandbox/config.sh`
- Create: `claude-sandbox/README.md`

**Step 1: Create the directory structure**

```bash
mkdir -p claude-sandbox
```

**Step 2: Create the config file**

`claude-sandbox/config.sh` — all tunable parameters in one place:

```bash
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

# --- Paths ---
SANDBOX_DIR="${SANDBOX_DIR:-$HOME/.claude-sandbox}"
RUNTIME_DIR="${SANDBOX_DIR}/run"
CH_BINARY="${CH_BINARY:-/usr/local/bin/cloud-hypervisor}"
VIRTIOFSD_BINARY="${VIRTIOFSD_BINARY:-$(command -v virtiofsd)}"

# --- VM Resources ---
VM_CPUS="boot=4"
VM_MEMORY="size=8G,shared=on"

# --- VM Image ---
KERNEL_PATH="${SANDBOX_DIR}/vmlinux"
ROOTFS_PATH="${SANDBOX_DIR}/rootfs.raw"

# --- Filesystem Sharing ---
# Format: "tag:host_path:mode" where mode is "rw" or "ro"
VIRTIOFS_MOUNTS=(
    "workspace:$HOME/work:rw"
    "claude-config:$HOME/.claude:ro"
)

# --- Claude Settings (source of hostname allowlist) ---
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

# --- Sockets (derived, do not edit) ---
CH_API_SOCKET="${RUNTIME_DIR}/ch-api.sock"
DNSMASQ_PIDFILE="${RUNTIME_DIR}/dnsmasq.pid"
DNSMASQ_CONF="${RUNTIME_DIR}/dnsmasq.conf"
DNSMASQ_NFTSET_CONF="${RUNTIME_DIR}/dnsmasq-nftset.conf"
```

**Step 3: Create the main script skeleton**

`claude-sandbox/claude-sandbox.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

usage() {
    echo "Usage: claude-sandbox {start|stop|status|ssh}"
    exit 1
}

cmd_start() {
    echo "Starting Claude sandbox..."
    setup_runtime_dir
    setup_networking
    setup_nftables
    setup_dnsmasq
    start_virtiofsd
    start_vm
    wait_for_ssh
    echo "Claude sandbox ready. Run: claude-sandbox ssh"
}

cmd_stop() {
    echo "Stopping Claude sandbox..."
    stop_vm
    stop_virtiofsd
    stop_dnsmasq
    teardown_nftables
    teardown_networking
    echo "Claude sandbox stopped."
}

cmd_status() {
    echo "=== Claude Sandbox Status ==="
    echo -n "VM: "; vm_is_running && echo "running" || echo "stopped"
    echo -n "TAP: "; ip link show "$TAP_DEV" &>/dev/null && echo "up" || echo "down"
    echo -n "dnsmasq: "; [ -f "$DNSMASQ_PIDFILE" ] && kill -0 "$(cat "$DNSMASQ_PIDFILE")" 2>/dev/null && echo "running" || echo "stopped"
    echo -n "virtiofsd: "; pgrep -f "virtiofsd.*${RUNTIME_DIR}" &>/dev/null && echo "running" || echo "stopped"
    echo -n "Allowed IPs: "; nft list set inet claude_filter allowed_ips 2>/dev/null | grep -c "elements" || echo "0"
}

cmd_ssh() {
    exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "claude@${GUEST_IP}"
}

# --- Stub functions (implemented in subsequent tasks) ---
setup_runtime_dir() { mkdir -p "$RUNTIME_DIR"; }
setup_networking() { :; }
teardown_networking() { :; }
setup_nftables() { :; }
teardown_nftables() { :; }
setup_dnsmasq() { :; }
stop_dnsmasq() { :; }
start_virtiofsd() { :; }
stop_virtiofsd() { :; }
start_vm() { :; }
stop_vm() { :; }
wait_for_ssh() { :; }
vm_is_running() { return 1; }

case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    ssh)    cmd_ssh ;;
    *)      usage ;;
esac
```

**Step 4: Make executable and commit**

```bash
chmod +x claude-sandbox/claude-sandbox.sh
git add claude-sandbox/
git commit -m "feat(claude-sandbox): scaffold project with config and main script skeleton"
```

---

## Task 2: TAP Networking Setup and Teardown

**Files:**
- Modify: `claude-sandbox/claude-sandbox.sh` — replace `setup_networking` and `teardown_networking` stubs

**Step 1: Implement setup_networking**

Replace the `setup_networking` stub:

```bash
setup_networking() {
    echo "  Creating TAP device ${TAP_DEV}..."
    if ip link show "$TAP_DEV" &>/dev/null; then
        echo "  TAP device ${TAP_DEV} already exists, reusing."
    else
        sudo ip tuntap add dev "$TAP_DEV" mode tap
    fi
    sudo ip addr replace "${HOST_IP}/24" dev "$TAP_DEV"
    sudo ip link set "$TAP_DEV" up

    # Enable IP forwarding (required for NAT)
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
}
```

**Step 2: Implement teardown_networking**

Replace the `teardown_networking` stub:

```bash
teardown_networking() {
    echo "  Removing TAP device ${TAP_DEV}..."
    if ip link show "$TAP_DEV" &>/dev/null; then
        sudo ip link set "$TAP_DEV" down
        sudo ip tuntap del dev "$TAP_DEV" mode tap
    fi
}
```

**Step 3: Manual test**

```bash
# Test setup
sudo bash -c 'source claude-sandbox/config.sh && source claude-sandbox/claude-sandbox.sh'
# Or test directly:
sudo ip tuntap add dev claude-tap0 mode tap
sudo ip addr replace 172.16.0.1/24 dev claude-tap0
sudo ip link show claude-tap0    # Expected: device exists, UP
sudo ip tuntap del dev claude-tap0 mode tap
ip link show claude-tap0 2>&1    # Expected: "Device does not exist"
```

**Step 4: Commit**

```bash
git add claude-sandbox/claude-sandbox.sh
git commit -m "feat(claude-sandbox): implement TAP networking setup and teardown"
```

---

## Task 3: nftables Egress Rules

**Files:**
- Modify: `claude-sandbox/claude-sandbox.sh` — replace `setup_nftables` and `teardown_nftables` stubs

**Step 1: Implement setup_nftables**

Replace the `setup_nftables` stub. Uses a dedicated table `claude_filter` to avoid conflicting with system firewall rules:

```bash
setup_nftables() {
    echo "  Setting up nftables egress rules..."

    # Use a dedicated table so we don't touch the system firewall
    sudo nft add table inet claude_filter

    # Dynamic IP set populated by dnsmasq
    sudo nft add set inet claude_filter allowed_ips '{ type ipv4_addr ; flags timeout ; }'

    # FORWARD chain: default drop
    sudo nft add chain inet claude_filter forward '{ type filter hook forward priority 0 ; policy drop ; }'

    # Rule 1: Allow DNS from guest to host dnsmasq
    sudo nft add rule inet claude_filter forward iifname "$TAP_DEV" ip daddr "$HOST_IP" udp dport 53 accept

    # Rule 2: Allow traffic to resolved allowlisted IPs
    sudo nft add rule inet claude_filter forward iifname "$TAP_DEV" ip daddr @allowed_ips accept

    # Rule 3: Allow return traffic for established connections
    sudo nft add rule inet claude_filter forward oifname "$TAP_DEV" ct state established,related accept

    # Rule 4: Reject everything else (fast failure, no agent stalls)
    sudo nft add rule inet claude_filter forward iifname "$TAP_DEV" counter reject

    # NAT: masquerade outbound traffic from the VM
    sudo nft add chain inet claude_filter postrouting '{ type nat hook postrouting priority 100 ; }'
    sudo nft add rule inet claude_filter postrouting ip saddr "$SUBNET_CIDR" oifname != "$TAP_DEV" masquerade
}
```

**Step 2: Implement teardown_nftables**

Replace the `teardown_nftables` stub:

```bash
teardown_nftables() {
    echo "  Removing nftables rules..."
    sudo nft delete table inet claude_filter 2>/dev/null || true
}
```

**Step 3: Manual test**

```bash
# Set up (requires TAP from Task 2 to exist for iifname to be valid)
sudo nft list table inet claude_filter  # Expected: table with chains and rules
sudo nft list set inet claude_filter allowed_ips  # Expected: empty set

# Teardown
sudo nft delete table inet claude_filter
sudo nft list table inet claude_filter 2>&1  # Expected: error, table doesn't exist
```

**Step 4: Commit**

```bash
git add claude-sandbox/claude-sandbox.sh
git commit -m "feat(claude-sandbox): implement nftables egress filtering with dedicated table"
```

---

## Task 4: dnsmasq Allowlist Configuration

**Files:**
- Modify: `claude-sandbox/claude-sandbox.sh` — replace `setup_dnsmasq` and `stop_dnsmasq` stubs

**Step 1: Implement the allowlist generator function**

Add this helper function above `setup_dnsmasq`:

```bash
generate_dnsmasq_nftset_conf() {
    echo "  Generating dnsmasq nftset config from ${CLAUDE_SETTINGS}..."
    if [ ! -f "$CLAUDE_SETTINGS" ]; then
        echo "ERROR: Claude settings not found at ${CLAUDE_SETTINGS}" >&2
        exit 1
    fi

    jq -r '.sandbox.network.allowedHosts[]
        | select(startswith("_comment") | not)' "$CLAUDE_SETTINGS" \
        | while read -r host; do
            echo "nftset=/${host}/4#inet#claude_filter#allowed_ips"
        done > "$DNSMASQ_NFTSET_CONF"

    local count
    count=$(wc -l < "$DNSMASQ_NFTSET_CONF")
    echo "  Generated ${count} nftset entries."
}
```

**Step 2: Implement setup_dnsmasq**

Replace the `setup_dnsmasq` stub:

```bash
setup_dnsmasq() {
    generate_dnsmasq_nftset_conf

    echo "  Writing dnsmasq config..."
    cat > "$DNSMASQ_CONF" <<EOF
# claude-sandbox dnsmasq config (auto-generated)
listen-address=${HOST_IP}
bind-interfaces
no-resolv
server=${DNS_UPSTREAM}
conf-file=${DNSMASQ_NFTSET_CONF}

# Don't read /etc/hosts or system resolv.conf
no-hosts

# Logging (optional, disable for production)
log-queries
log-facility=${RUNTIME_DIR}/dnsmasq.log
EOF

    echo "  Starting dnsmasq..."
    sudo dnsmasq \
        --conf-file="$DNSMASQ_CONF" \
        --pid-file="$DNSMASQ_PIDFILE" \
        --keep-in-foreground &
    DNSMASQ_PID=$!
    echo "  dnsmasq started (PID: ${DNSMASQ_PID})."
}
```

**Step 3: Implement stop_dnsmasq**

Replace the `stop_dnsmasq` stub:

```bash
stop_dnsmasq() {
    echo "  Stopping dnsmasq..."
    if [ -f "$DNSMASQ_PIDFILE" ]; then
        sudo kill "$(cat "$DNSMASQ_PIDFILE")" 2>/dev/null || true
        rm -f "$DNSMASQ_PIDFILE"
    fi
    # Also kill any backgrounded dnsmasq from this session
    kill "$DNSMASQ_PID" 2>/dev/null || true
}
```

**Step 4: Manual test**

```bash
# Generate the nftset config and inspect it
source claude-sandbox/config.sh
mkdir -p "$RUNTIME_DIR"
# Run the jq command manually:
jq -r '.sandbox.network.allowedHosts[] | select(startswith("_comment") | not)' ~/.claude/settings.json | head -5
# Expected: hostnames like "claude.ai", "github.com", etc.
```

**Step 5: Commit**

```bash
git add claude-sandbox/claude-sandbox.sh
git commit -m "feat(claude-sandbox): implement dnsmasq allowlist config generation and lifecycle"
```

---

## Task 5: virtiofsd Lifecycle

**Files:**
- Modify: `claude-sandbox/claude-sandbox.sh` — replace `start_virtiofsd` and `stop_virtiofsd` stubs

**Step 1: Implement start_virtiofsd**

Replace the `start_virtiofsd` stub. Iterates over the `VIRTIOFS_MOUNTS` array from config:

```bash
start_virtiofsd() {
    echo "  Starting virtiofsd instances..."
    VIRTIOFSD_PIDS=()

    for mount_spec in "${VIRTIOFS_MOUNTS[@]}"; do
        IFS=':' read -r tag host_path mode <<< "$mount_spec"
        local socket_path="${RUNTIME_DIR}/virtiofs-${tag}.sock"

        # Build virtiofsd args
        local args=(
            --socket-path="$socket_path"
            --shared-dir="$host_path"
            --cache=auto
        )
        if [ "$mode" = "ro" ]; then
            args+=(--readonly)
        fi

        echo "    ${tag}: ${host_path} (${mode}) → ${socket_path}"
        "$VIRTIOFSD_BINARY" "${args[@]}" &
        VIRTIOFSD_PIDS+=($!)

        # Wait for socket to appear (virtiofsd creates it on startup)
        local retries=0
        while [ ! -S "$socket_path" ] && [ $retries -lt 30 ]; do
            sleep 0.1
            retries=$((retries + 1))
        done
        if [ ! -S "$socket_path" ]; then
            echo "ERROR: virtiofsd socket ${socket_path} not created after 3s" >&2
            exit 1
        fi
    done
}
```

**Step 2: Implement stop_virtiofsd**

Replace the `stop_virtiofsd` stub:

```bash
stop_virtiofsd() {
    echo "  Stopping virtiofsd instances..."
    for pid in "${VIRTIOFSD_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    # Clean up sockets
    rm -f "${RUNTIME_DIR}"/virtiofs-*.sock
}
```

**Step 3: Manual test**

```bash
# Test that virtiofsd starts and creates its socket
virtiofsd --socket-path=/tmp/test-virtiofs.sock --shared-dir=/tmp --cache=auto &
ls -la /tmp/test-virtiofs.sock  # Expected: socket file exists
kill %1
rm /tmp/test-virtiofs.sock
```

**Step 4: Commit**

```bash
git add claude-sandbox/claude-sandbox.sh
git commit -m "feat(claude-sandbox): implement virtiofsd lifecycle with configurable mounts"
```

---

## Task 6: cloud-hypervisor VM Lifecycle

**Files:**
- Modify: `claude-sandbox/claude-sandbox.sh` — replace `start_vm`, `stop_vm`, `wait_for_ssh`, and `vm_is_running` stubs

**Step 1: Implement start_vm**

Replace the `start_vm` stub. Builds the `--fs` flags dynamically from config:

```bash
start_vm() {
    echo "  Starting cloud-hypervisor VM..."

    # Build --fs flags from VIRTIOFS_MOUNTS
    local fs_args=()
    for mount_spec in "${VIRTIOFS_MOUNTS[@]}"; do
        IFS=':' read -r tag host_path mode <<< "$mount_spec"
        local socket_path="${RUNTIME_DIR}/virtiofs-${tag}.sock"
        fs_args+=(--fs "tag=${tag},socket=${socket_path},num_queues=1,queue_size=512")
    done

    sudo "$CH_BINARY" \
        --kernel "$KERNEL_PATH" \
        --disk "path=${ROOTFS_PATH}" \
        --cmdline "console=hvc0 root=/dev/vda1 rw" \
        --cpus "$VM_CPUS" \
        --memory "$VM_MEMORY" \
        --net "tap=${TAP_DEV},ip=${GUEST_IP},mask=${SUBNET_MASK}" \
        "${fs_args[@]}" \
        --api-socket "$CH_API_SOCKET" \
        --seccomp true &
    CH_PID=$!

    echo "  cloud-hypervisor started (PID: ${CH_PID})."
}
```

**Step 2: Implement stop_vm**

Replace the `stop_vm` stub:

```bash
stop_vm() {
    echo "  Shutting down VM..."
    # Try graceful shutdown via API first
    if [ -S "$CH_API_SOCKET" ]; then
        sudo curl --unix-socket "$CH_API_SOCKET" -s \
            -X PUT "http://localhost/api/v1/vm.shutdown" 2>/dev/null || true
        # Wait up to 5s for graceful shutdown
        local retries=0
        while kill -0 "$CH_PID" 2>/dev/null && [ $retries -lt 50 ]; do
            sleep 0.1
            retries=$((retries + 1))
        done
    fi
    # Force kill if still running
    if kill -0 "$CH_PID" 2>/dev/null; then
        echo "  Force killing VM..."
        sudo kill "$CH_PID" 2>/dev/null || true
    fi
    rm -f "$CH_API_SOCKET"
}
```

**Step 3: Implement wait_for_ssh and vm_is_running**

Replace the stubs:

```bash
wait_for_ssh() {
    echo "  Waiting for SSH to become available..."
    local retries=0
    while ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=1 "claude@${GUEST_IP}" true 2>/dev/null; do
        retries=$((retries + 1))
        if [ $retries -ge 60 ]; then
            echo "ERROR: SSH not available after 60s" >&2
            exit 1
        fi
        sleep 1
    done
    echo "  SSH is ready."
}

vm_is_running() {
    [ -n "${CH_PID:-}" ] && kill -0 "$CH_PID" 2>/dev/null
}
```

**Step 4: Add signal trap for clean teardown**

Add near the top of `cmd_start`, after the first echo:

```bash
trap 'echo "Caught signal, shutting down..."; cmd_stop; exit 1' INT TERM
```

**Step 5: Commit**

```bash
git add claude-sandbox/claude-sandbox.sh
git commit -m "feat(claude-sandbox): implement cloud-hypervisor VM lifecycle with graceful shutdown"
```

---

## Task 7: Guest Rootfs Build Script

**Files:**
- Create: `claude-sandbox/build-rootfs.sh`

This script creates the guest VM disk image. Uses `virt-builder` (from `libguestfs-tools`) to create a Fedora-based raw image with all required packages pre-installed.

**Step 1: Create the build script**

`claude-sandbox/build-rootfs.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Building Claude sandbox guest rootfs..."
mkdir -p "$SANDBOX_DIR"

# --- Option A: virt-builder (simplest, requires libguestfs-tools) ---
# sudo dnf install libguestfs-tools-c

ROOTFS_SIZE="20G"

virt-builder fedora-41 \
    --output "$ROOTFS_PATH" \
    --format raw \
    --size "$ROOTFS_SIZE" \
    --root-password password:sandbox \
    --run-command 'dnf install -y openssh-server nodejs npm python3 python3-pip git make gcc-c++ curl wget' \
    --run-command 'npm install -g @anthropic-ai/claude-code' \
    --run-command 'useradd -m -s /bin/bash claude' \
    --run-command 'echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude' \
    --ssh-inject claude:file:"$HOME/.ssh/id_ed25519.pub" \
    --run-command 'systemctl enable sshd' \
    --firstboot-command "hostnamectl set-hostname claude-sandbox" \
    --firstboot-command "ip addr add ${GUEST_IP}/24 dev eth0 || true" \
    --firstboot-command "ip route add default via ${HOST_IP} || true" \
    --firstboot-command "echo 'nameserver ${HOST_IP}' > /etc/resolv.conf" \
    --firstboot-command "mkdir -p /workspace /etc/claude" \
    --firstboot-command "mount -t virtiofs workspace /workspace || true" \
    --firstboot-command "mount -t virtiofs -o ro claude-config /etc/claude || true"

echo "Rootfs built at ${ROOTFS_PATH}"
echo ""
echo "Next: download a vmlinux kernel for cloud-hypervisor."
echo "  See: https://github.com/cloud-hypervisor/cloud-hypervisor/releases"
echo "  Download the hypervisor-fw or a vmlinux binary and place it at:"
echo "    ${KERNEL_PATH}"
```

**Step 2: Make executable**

```bash
chmod +x claude-sandbox/build-rootfs.sh
```

**Step 3: Commit**

```bash
git add claude-sandbox/build-rootfs.sh
git commit -m "feat(claude-sandbox): add guest rootfs build script using virt-builder"
```

---

## Task 8: README and Final Integration

**Files:**
- Create: `claude-sandbox/README.md`

**Step 1: Write the README**

`claude-sandbox/README.md`:

```markdown
# Claude Code Sandbox

Run Claude Code inside a cloud-hypervisor microVM with hostname-based egress filtering.

## Prerequisites

- Fedora 43 (or any Linux with KVM support)
- `/dev/kvm` accessible
- Install dependencies:

```bash
# cloud-hypervisor
wget https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/cloud-hypervisor-static \
    -O /usr/local/bin/cloud-hypervisor
chmod +x /usr/local/bin/cloud-hypervisor
sudo setcap cap_net_admin+ep /usr/local/bin/cloud-hypervisor

# virtiofsd
cargo install virtiofsd

# System packages
sudo dnf install dnsmasq jq nftables libguestfs-tools-c
```

## Setup

1. Build the guest rootfs:

```bash
./build-rootfs.sh
```

2. Download a kernel binary from the cloud-hypervisor releases and place it at
   `~/.claude-sandbox/vmlinux`.

## Usage

```bash
# Start the sandbox
sudo ./claude-sandbox.sh start

# SSH into the VM
./claude-sandbox.sh ssh

# Check status
sudo ./claude-sandbox.sh status

# Stop the sandbox
sudo ./claude-sandbox.sh stop
```

## Egress Allowlist

The hostname allowlist is read from `~/.claude/settings.json` (the `sandbox.network.allowedHosts` array). To update:

1. Edit `~/.claude/settings.json` and add/remove hosts
2. Restart the sandbox (`stop` then `start`)

## Architecture

See [design doc](../docs/plans/2026-04-09-claude-sandbox-design.md) for full details.

- **Egress filtering**: nftables FORWARD chain with dnsmasq `nftset` directive
- **Filesystem**: virtiofs (rw for workspace, ro for claude config)
- **VM**: cloud-hypervisor with seccomp + Landlock enabled
```

**Step 2: Commit**

```bash
git add claude-sandbox/README.md
git commit -m "docs(claude-sandbox): add README with setup and usage instructions"
```

---

## Task 9: End-to-End Smoke Test

**No new files — this is a manual integration test.**

**Step 1: Build the rootfs**

```bash
sudo ./claude-sandbox/build-rootfs.sh
```

**Step 2: Download kernel**

```bash
wget https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/hypervisor-fw \
    -O ~/.claude-sandbox/vmlinux
```

**Step 3: Start the sandbox**

```bash
sudo ./claude-sandbox/claude-sandbox.sh start
```

Expected output:
```
Starting Claude sandbox...
  Creating TAP device claude-tap0...
  Setting up nftables egress rules...
  Generating dnsmasq nftset config from /home/askldjd/.claude/settings.json...
  Generated ~100 nftset entries.
  Writing dnsmasq config...
  Starting dnsmasq...
  Starting virtiofsd instances...
    workspace: /home/askldjd/work (rw) → ...
    claude-config: /home/askldjd/.claude (ro) → ...
  Starting cloud-hypervisor VM...
  Waiting for SSH to become available...
  SSH is ready.
Claude sandbox ready. Run: claude-sandbox ssh
```

**Step 4: Verify egress filtering**

```bash
# SSH in
./claude-sandbox/claude-sandbox.sh ssh

# Inside the guest:
# Allowed host should work
curl -s https://github.com -o /dev/null -w "%{http_code}"  # Expected: 200 or 301

# Blocked host should fail fast (reject, not timeout)
curl -s --connect-timeout 3 https://evil.example.com 2>&1  # Expected: connection refused, fast
```

**Step 5: Verify virtiofs mounts**

```bash
# Inside the guest:
ls /workspace       # Expected: your work directory contents
touch /workspace/test-rw  # Expected: succeeds (rw mount)
touch /etc/claude/test-ro 2>&1  # Expected: "Read-only file system" error
```

**Step 6: Stop and verify cleanup**

```bash
sudo ./claude-sandbox/claude-sandbox.sh stop
sudo nft list table inet claude_filter 2>&1  # Expected: error (table removed)
ip link show claude-tap0 2>&1               # Expected: device not found
```

**Step 7: Commit any fixes found during smoke test**

```bash
git add -A
git commit -m "fix(claude-sandbox): fixes from end-to-end smoke test"
```
