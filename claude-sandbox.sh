#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config/config.sh"

usage() {
    echo "Usage: claude-sandbox {start|stop|status|ssh}"
    exit 1
}

cmd_start() {
    echo "Starting Claude sandbox..."
    trap 'echo "Caught signal, shutting down..."; cmd_stop; exit 1' INT TERM
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

# --- Infrastructure ---
setup_runtime_dir() { mkdir -p "$RUNTIME_DIR" "$BUILD_DIR"; }

# --- Networking ---
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

teardown_networking() {
    echo "  Removing TAP device ${TAP_DEV}..."
    if ip link show "$TAP_DEV" &>/dev/null; then
        sudo ip link set "$TAP_DEV" down
        sudo ip tuntap del dev "$TAP_DEV" mode tap
    fi
}

# --- nftables ---
setup_nftables() {
    echo "  Setting up nftables egress rules..."

    # Use a dedicated table so we don't touch the system firewall
    sudo nft add table inet claude_filter

    # Dynamic IP set populated by dnsmasq
    sudo nft add set inet claude_filter allowed_ips '{ type ipv4_addr ; flags timeout ; }'

    # INPUT chain: allow guest → host DNS (locally-delivered, not forwarded)
    sudo nft add chain inet claude_filter input '{ type filter hook input priority 0 ; policy accept ; }'
    sudo nft add rule inet claude_filter input iifname "$TAP_DEV" ip daddr "$HOST_IP" udp dport 53 accept
    sudo nft add rule inet claude_filter input iifname "$TAP_DEV" ip daddr "$HOST_IP" tcp dport 53 accept

    # FORWARD chain: default drop
    sudo nft add chain inet claude_filter forward '{ type filter hook forward priority 0 ; policy drop ; }'

    # Rule 2: Allow traffic to resolved allowlisted IPs
    sudo nft add rule inet claude_filter forward iifname "$TAP_DEV" ip daddr @allowed_ips accept

    # Rule 3: Allow return traffic for established connections
    sudo nft add rule inet claude_filter forward oifname "$TAP_DEV" ct state established,related accept

    # Rule 4: Reject everything else (fast failure, no agent stalls)
    sudo nft add rule inet claude_filter forward iifname "$TAP_DEV" counter reject

    # NAT: masquerade outbound traffic from the VM
    sudo nft add chain inet claude_filter postrouting '{ type nat hook postrouting priority 100 ; }'
    sudo nft add rule inet claude_filter postrouting ip saddr "$SUBNET_CIDR" oifname != "$TAP_DEV" masquerade

    # Docker uses legacy iptables with a DROP policy on FORWARD.
    # Insert rules so traffic from/to the TAP device isn't killed.
    echo "  Adding iptables rules for Docker coexistence..."
    sudo iptables -I FORWARD -i "$TAP_DEV" -j ACCEPT
    sudo iptables -I FORWARD -o "$TAP_DEV" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

teardown_nftables() {
    echo "  Removing nftables rules..."
    sudo nft delete table inet claude_filter 2>/dev/null || true

    # Remove iptables rules added for Docker coexistence
    sudo iptables -D FORWARD -i "$TAP_DEV" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -o "$TAP_DEV" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
}

# --- dnsmasq ---
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

stop_dnsmasq() {
    echo "  Stopping dnsmasq..."
    if [ -f "$DNSMASQ_PIDFILE" ]; then
        sudo kill "$(cat "$DNSMASQ_PIDFILE")" 2>/dev/null || true
        rm -f "$DNSMASQ_PIDFILE"
    fi
    # Also kill any backgrounded dnsmasq from this session
    kill "${DNSMASQ_PID:-0}" 2>/dev/null || true
}

# --- virtiofsd ---
start_virtiofsd() {
    echo "  Starting virtiofsd instances..."
    VIRTIOFSD_PIDS=()

    for mount_spec in "${VIRTIOFS_MOUNTS[@]}"; do
        IFS=':' read -r tag host_path mode <<< "$mount_spec"
        local socket_path="${RUNTIME_DIR}/virtiofs-${tag}.sock"

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

stop_virtiofsd() {
    echo "  Stopping virtiofsd instances..."
    for pid in "${VIRTIOFSD_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -f "${RUNTIME_DIR}"/virtiofs-*.sock
}

# --- cloud-hypervisor ---
start_vm() {
    echo "  Starting cloud-hypervisor VM..."

    # --fs takes multiple space-separated values after a single flag
    local fs_args=(--fs)
    for mount_spec in "${VIRTIOFS_MOUNTS[@]}"; do
        IFS=':' read -r tag host_path mode <<< "$mount_spec"
        local socket_path="${RUNTIME_DIR}/virtiofs-${tag}.sock"
        fs_args+=("tag=${tag},socket=${socket_path},num_queues=1,queue_size=512")
    done

    sudo "$CH_BINARY" \
        --kernel "$KERNEL_PATH" \
        --initramfs "$INITRD_PATH" \
        --disk "path=${ROOTFS_PATH}" \
        --cmdline "console=ttyS0 root=/dev/vda1 rw net.ifnames=0 biosdevname=0" \
        --cpus "$VM_CPUS" \
        --memory "$VM_MEMORY" \
        --serial "file=${RUNTIME_DIR}/serial.log" \
        --console off \
        --net "tap=${TAP_DEV},ip=${GUEST_IP},mask=${SUBNET_MASK}" \
        "${fs_args[@]}" \
        --api-socket "$CH_API_SOCKET" \
        --seccomp true &
    CH_PID=$!

    echo "  cloud-hypervisor started (PID: ${CH_PID})."
}

stop_vm() {
    echo "  Shutting down VM..."
    if [ -S "$CH_API_SOCKET" ]; then
        sudo curl --unix-socket "$CH_API_SOCKET" -s \
            -X PUT "http://localhost/api/v1/vm.shutdown" 2>/dev/null || true
        local retries=0
        while kill -0 "${CH_PID:-0}" 2>/dev/null && [ $retries -lt 50 ]; do
            sleep 0.1
            retries=$((retries + 1))
        done
    fi
    if kill -0 "${CH_PID:-0}" 2>/dev/null; then
        echo "  Force killing VM..."
        sudo kill "$CH_PID" 2>/dev/null || true
    fi
    rm -f "$CH_API_SOCKET"
}

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

case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    ssh)    cmd_ssh ;;
    *)      usage ;;
esac
