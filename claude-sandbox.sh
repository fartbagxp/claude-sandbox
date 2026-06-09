#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config/config.sh"

usage() {
    echo "Usage: claude-sandbox {start|stop|status|ssh|reload-allowlist}"
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

SSH_KEY_ARGS=()
for _key in "${REAL_HOME}/.ssh/id_ed25519" "${REAL_HOME}/.ssh/id_rsa" "${BUILD_DIR}/sandbox_id_ed25519"; do
    [[ -f "$_key" ]] && SSH_KEY_ARGS+=(-i "$_key")
done

cmd_ssh() {
    exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${SSH_KEY_ARGS[@]}" "${REAL_USER}@${GUEST_IP}"
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

    # firewalld (if active) drops packets on interfaces not assigned to a zone,
    # which blocks VM→host DNS before our nftables INPUT rules can accept it.
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "  firewalld detected: adding ${TAP_DEV} to trusted zone..."
        sudo firewall-cmd --zone=trusted --add-interface="$TAP_DEV"
    fi
}

teardown_networking() {
    echo "  Removing TAP device ${TAP_DEV}..."
    if ip link show "$TAP_DEV" &>/dev/null; then
        sudo ip link set "$TAP_DEV" down
        sudo ip tuntap del dev "$TAP_DEV" mode tap
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        sudo firewall-cmd --zone=trusted --remove-interface="$TAP_DEV" 2>/dev/null || true
    fi
}

# --- nftables ---
setup_nftables() {
    echo "  Setting up nftables egress rules..."

    # Clean slate — idempotent on re-run
    teardown_nftables

    # Atomic ruleset load. policy accept ensures non-sandbox forwarding
    # (Docker, libvirt, VPNs) is unaffected. Only TAP traffic is filtered.
    sudo nft -f - <<EOF
table inet claude_filter {
    set allowed_ips {
        type ipv4_addr
        flags timeout
    }

    chain input {
        type filter hook input priority 0; policy accept;
        iifname "$TAP_DEV" ip daddr "$HOST_IP" udp dport 53 accept
        iifname "$TAP_DEV" ip daddr "$HOST_IP" tcp dport 53 accept
    }

    chain forward {
        type filter hook forward priority 0; policy accept;

        # Allow traffic to DNS-resolved allowlisted IPs
        iifname "$TAP_DEV" ip daddr @allowed_ips accept

        # Allow return traffic for established connections
        oifname "$TAP_DEV" ct state established,related accept

        # Reject all other sandbox traffic (fast failure, no agent stalls)
        iifname "$TAP_DEV" counter reject
    }

    chain postrouting {
        type nat hook postrouting priority 100;
        ip saddr $SUBNET_CIDR oifname != "$TAP_DEV" masquerade
    }
}
EOF

    # Docker uses legacy iptables with a DROP policy on FORWARD.
    # These rules ensure sandbox traffic isn't killed by Docker's iptables
    # before reaching our nftables rules. They are safe because our nftables
    # chain above is the actual security boundary — these just pass traffic
    # through to it.
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
    echo "  Generating dnsmasq nftset config from ${ALLOWLIST_FILE}..."
    if [ ! -f "$ALLOWLIST_FILE" ]; then
        echo "ERROR: Allowlist not found at ${ALLOWLIST_FILE}" >&2
        echo "  Copy the example: cp config/allowlist.txt.example config/allowlist.txt" >&2
        exit 1
    fi

    # Strip comments and blank lines, generate dnsmasq nftset directives
    grep -v '^\s*#' "$ALLOWLIST_FILE" | grep -v '^\s*$' \
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

# Reduce CDN IP rotation issues (IPs stay in nftset for at least 5 min)
min-cache-ttl=300

# Logging (optional, disable for production)
log-queries
log-facility=${RUNTIME_DIR}/dnsmasq.log
EOF

    echo "  Starting dnsmasq..."
    sudo dnsmasq \
        --conf-file="$DNSMASQ_CONF" \
        --pid-file="$DNSMASQ_PIDFILE"
    echo "  dnsmasq started (PID: $(cat "$DNSMASQ_PIDFILE"))."
}

stop_dnsmasq() {
    echo "  Stopping dnsmasq..."
    if [ -f "$DNSMASQ_PIDFILE" ]; then
        sudo kill "$(cat "$DNSMASQ_PIDFILE")" 2>/dev/null || true
        rm -f "$DNSMASQ_PIDFILE"
    fi
}

# --- virtiofsd ---
start_virtiofsd() {
    echo "  Starting virtiofsd instances..."

    for mount_spec in "${VIRTIOFS_MOUNTS[@]}"; do
        IFS=':' read -r tag host_path _guest_path mode <<< "$mount_spec"
        local socket_path="${RUNTIME_DIR}/virtiofs-${tag}.sock"
        local pidfile="${RUNTIME_DIR}/virtiofs-${tag}.pid"

        local args=(
            --socket-path="$socket_path"
            --shared-dir="$host_path"
            --cache=auto
        )
        if [ "$mode" = "ro" ]; then
            args+=(--readonly)
        fi

        echo "    ${tag}: ${host_path} (${mode}) -> ${socket_path}"
        "$VIRTIOFSD_BINARY" "${args[@]}" &
        echo "$!" > "$pidfile"

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
    for pidfile in "${RUNTIME_DIR}"/virtiofs-*.pid; do
        [ -f "$pidfile" ] || continue
        kill "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile"
    done
    rm -f "${RUNTIME_DIR}"/virtiofs-*.sock
}

# --- cloud-hypervisor ---
start_vm() {
    echo "  Starting cloud-hypervisor VM..."

    # --fs takes multiple space-separated values after a single flag
    local fs_args=(--fs)
    for mount_spec in "${VIRTIOFS_MOUNTS[@]}"; do
        IFS=':' read -r tag host_path _guest_path mode <<< "$mount_spec"
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
    echo "$!" > "$CH_PIDFILE"

    echo "  cloud-hypervisor started (PID: $(cat "$CH_PIDFILE"))."
}

stop_vm() {
    echo "  Shutting down VM..."

    local ch_pid=""
    if [ -f "$CH_PIDFILE" ]; then
        ch_pid=$(cat "$CH_PIDFILE")
    fi

    # Try graceful shutdown via API socket first
    if [ -S "$CH_API_SOCKET" ]; then
        sudo curl --unix-socket "$CH_API_SOCKET" -s \
            -X PUT "http://localhost/api/v1/vm.shutdown" 2>/dev/null || true
        local retries=0
        while [ -n "$ch_pid" ] && kill -0 "$ch_pid" 2>/dev/null && [ $retries -lt 50 ]; do
            sleep 0.1
            retries=$((retries + 1))
        done
    fi

    # Force kill if still running
    if [ -n "$ch_pid" ] && kill -0 "$ch_pid" 2>/dev/null; then
        echo "  Force killing VM..."
        sudo kill "$ch_pid" 2>/dev/null || true
    fi

    rm -f "$CH_API_SOCKET" "$CH_PIDFILE"
}

wait_for_ssh() {
    echo "  Waiting for SSH to become available..."
    local retries=0
    while ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=1 "${SSH_KEY_ARGS[@]}" "${REAL_USER}@${GUEST_IP}" true 2>/dev/null; do
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
    [ -f "$CH_PIDFILE" ] && kill -0 "$(cat "$CH_PIDFILE")" 2>/dev/null
}

cmd_reload_allowlist() {
    if [ ! -f "$DNSMASQ_PIDFILE" ] || ! sudo kill -0 "$(cat "$DNSMASQ_PIDFILE")" 2>/dev/null; then
        echo "ERROR: dnsmasq is not running. Start the sandbox first." >&2
        exit 1
    fi

    echo "Reloading allowlist..."

    # Regenerate nftset config from the (possibly updated) allowlist
    generate_dnsmasq_nftset_conf

    # Flush cached IPs so removed hostnames lose access immediately
    echo "  Flushing nftables allowed_ips set..."
    sudo nft flush set inet claude_filter allowed_ips

    # SIGHUP tells dnsmasq to re-read its config files (including nftset conf)
    # and clear its DNS cache, which forces fresh lookups that re-populate
    # the nftset for hostnames still on the allowlist.
    echo "  Sending SIGHUP to dnsmasq (PID: $(cat "$DNSMASQ_PIDFILE"))..."
    sudo kill -HUP "$(cat "$DNSMASQ_PIDFILE")"

    echo "Allowlist reloaded. New DNS queries will repopulate the firewall rules."
}

case "${1:-}" in
    start)            cmd_start ;;
    stop)             cmd_stop ;;
    status)           cmd_status ;;
    ssh)              cmd_ssh ;;
    reload-allowlist) cmd_reload_allowlist ;;
    *)                usage ;;
esac
