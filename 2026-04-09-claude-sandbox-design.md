# Claude Code Sandbox: cloud-hypervisor + Egress Filtering

## Problem

Claude Code's built-in sandbox (seccomp + filesystem allowlists) provides weak isolation. We want VM-level isolation so Claude Code can run with more autonomous permissions safely. The two core requirements:

1. **VM isolation** — run Claude Code inside a microVM so destructive actions are contained
2. **Egress filtering** — hostname-based allowlisting prevents accidental data exfiltration

### Threat Model

- **Accidental exfiltration** (highest priority) — Claude Code sends data to unauthorized hosts
- **Destructive local actions** — `rm -rf /`, broken system configs, etc.
- **Supply chain risk** — malicious packages phoning home

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  Host (Fedora 43 workstation)                   │
│                                                 │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐ │
│  │virtiofsd │  │virtiofsd │  │  dnsmasq      │ │
│  │(rw)      │  │(readonly)│  │  172.16.0.1   │ │
│  │/work     │  │/.claude  │  │  nftset→      │ │
│  └────┬─────┘  └────┬─────┘  └───────┬───────┘ │
│       │socket        │socket          │         │
│  ┌────┴──────────────┴────────────────┴───────┐ │
│  │         cloud-hypervisor                   │ │
│  │  --fs (rw)  --fs (ro)  --net tap=tap0      │ │
│  │  --landlock  --seccomp  --api-socket        │ │
│  └────────────────────┬───────────────────────┘ │
│                       │ tap0                     │
│              ┌────────┴────────┐                │
│              │  nftables       │                │
│              │  FORWARD chain  │                │
│              │  @allowed_ips   │                │
│              └────────┬────────┘                │
│                       │ NAT/MASQUERADE          │
│                       ▼                         │
│                   Internet                      │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  Guest VM (172.16.0.2)                          │
│                                                 │
│  /workspace    ← virtiofs mount (rw)            │
│  /etc/claude   ← virtiofs mount (ro)            │
│  DNS server    → 172.16.0.1 (host dnsmasq)      │
│                                                 │
│  Claude Code runs here with full permissions    │
└─────────────────────────────────────────────────┘
```

## Component 1: Egress Filtering (nftables + dnsmasq)

### How It Works

1. Guest DNS queries go to dnsmasq on the host (172.16.0.1)
2. dnsmasq resolves the query and, for allowlisted hostnames, adds resolved IPs to an nftables set (`@allowed_ips`) via the `nftset` directive
3. Guest traffic hits the nftables FORWARD chain — only IPs in `@allowed_ips` are accepted
4. Non-allowlisted traffic is rejected (TCP RST for TCP, ICMP port-unreachable for UDP)

### nftables Rules

```bash
# Create the dynamic IP set
nft add table inet filter
nft add set inet filter allowed_ips { type ipv4_addr \; flags timeout \; }

# FORWARD chain: default deny
nft add chain inet filter forward { type filter hook forward priority 0 \; policy drop \; }

# Allow DNS to host dnsmasq
nft add rule inet filter forward iifname "tap0" ip daddr 172.16.0.1 udp dport 53 accept

# Allow traffic to resolved allowlisted IPs
nft add rule inet filter forward iifname "tap0" ip daddr @allowed_ips accept

# Allow return traffic for established connections
nft add rule inet filter forward oifname "tap0" ct state established,related accept

# Reject (not drop) everything else — fast failure, no agent stalls
nft add rule inet filter forward iifname "tap0" counter reject
```

### dnsmasq Configuration

Generated from `~/.claude/settings.json`:

```bash
# Generate dnsmasq nftset config from Claude's allowlist
jq -r '.sandbox.network.allowedHosts[]
  | select(startswith("_comment") | not)' ~/.claude/settings.json \
  | while read -r host; do
      echo "nftset=/${host}/4#inet#filter#allowed_ips"
    done > /etc/claude-sandbox/dnsmasq-nftset.conf
```

dnsmasq config:
```ini
listen-address=172.16.0.1
bind-interfaces
server=8.8.8.8
conf-file=/etc/claude-sandbox/dnsmasq-nftset.conf
```

### Known Limitations

- **IP accumulation**: dnsmasq `nftset` entries never expire (dnsmasq does not pass DNS TTL to nftables). The set grows over time. Mitigation: nftables handles millions of entries; periodic flush + re-population is optional.
- **All DNS resolves**: dnsmasq resolves all queries (not just allowlisted ones). Security is enforced at the nftables layer, not DNS. This is by design — DNS resolution without network access is harmless and gives better error messages.

## Component 2: Filesystem Sharing (virtiofs)

### Two virtiofsd Instances

```bash
# Read-write: project workspace
virtiofsd \
    --socket-path=/tmp/virtiofs-rw.sock \
    --shared-dir=/home/askldjd/work \
    --cache=auto

# Read-only: Claude config, tools, etc.
virtiofsd \
    --socket-path=/tmp/virtiofs-ro.sock \
    --shared-dir=/home/askldjd/.claude \
    --readonly \
    --cache=auto
```

### Guest Mounts

```bash
mount -t virtiofs workspace /workspace
mount -t virtiofs -o ro claude-config /etc/claude
```

The `--readonly` flag on virtiofsd enforces read-only at the FUSE protocol level (confirmed in virtiofsd v1.13.x docs). Guest-side `-o ro` provides defense in depth.

### Key Requirement

`--memory shared=on` is **mandatory** for virtiofs in cloud-hypervisor (enables MAP_SHARED mmap).

## Component 3: cloud-hypervisor VM

### Launch Command

```bash
cloud-hypervisor \
    --kernel vmlinux \
    --disk path=rootfs.raw \
    --cmdline "console=hvc0 root=/dev/vda1 rw" \
    --cpus boot=4 \
    --memory size=8G,shared=on \
    --net "tap=tap0,ip=172.16.0.2,mask=255.255.255.0" \
    --fs tag=workspace,socket=/tmp/virtiofs-rw.sock,num_queues=1,queue_size=512 \
    --fs tag=claude-config,socket=/tmp/virtiofs-ro.sock,num_queues=1,queue_size=512 \
    --api-socket /tmp/ch-api.sock \
    --landlock \
    --seccomp true
```

### Security Layers (Defense in Depth)

| Layer | What It Protects | How |
|-------|-----------------|-----|
| VM boundary | Host from guest | Hardware virtualization (KVM) |
| Seccomp | Host from VMM exploit | Per-thread syscall filters (on by default) |
| Landlock | Host filesystem from VMM | Restricts VMM to declared paths only |
| nftables | Network egress | Hostname-based allowlist, default deny |
| virtiofsd --readonly | Host files from guest writes | FUSE-level write blocking |
| NAT/MASQUERADE | Guest IP hidden | Standard Linux NAT |

### Rootfs Image

A minimal Linux rootfs (raw format) containing:
- Base system (Alpine or Fedora minimal)
- Claude Code (`npm install -g @anthropic-ai/claude-code`)
- Node.js, Python, git, and development tools
- SSH server for interactive access
- Guest init script that mounts virtiofs and configures networking

Built via standard tooling (e.g., `virt-builder`, `debootstrap`, or a Dockerfile → raw image conversion).

### Installation (Fedora 43)

```bash
# cloud-hypervisor static binary
wget https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/cloud-hypervisor-static
chmod +x cloud-hypervisor-static
sudo setcap cap_net_admin+ep ./cloud-hypervisor-static

# virtiofsd
cargo install virtiofsd

# dnsmasq (already in Fedora repos, v2.92 supports nftset)
sudo dnf install dnsmasq
```

## Component 4: Launch Script Orchestration

The launch script handles startup and teardown in order:

### Startup Sequence

1. Create TAP device + configure IP (172.16.0.1/24)
2. Set up nftables rules + NAT/MASQUERADE
3. Generate dnsmasq config from `~/.claude/settings.json`
4. Start dnsmasq
5. Start virtiofsd instances (rw + ro)
6. Start cloud-hypervisor
7. Wait for SSH availability in guest

### Teardown (on exit/signal)

1. Shutdown VM via API socket (`curl --unix-socket /tmp/ch-api.sock -X PUT http://localhost/api/v1/vm.shutdown`)
2. Kill virtiofsd processes
3. Stop dnsmasq
4. Flush nftables rules
5. Remove TAP device

## Usage Flow

```bash
# One command to start
./claude-sandbox start

# SSH into the VM
ssh user@172.16.0.2

# Claude Code runs inside with full permissions
# All egress is filtered through the allowlist
# Workspace is live-synced via virtiofs

# When done
./claude-sandbox stop
```

## Decisions and Trade-offs

| Decision | Rationale |
|----------|-----------|
| cloud-hypervisor over Firecracker | Native virtiofs support; Firecracker rejected virtiofs in 2019 |
| Reject over drop for blocked traffic | Fast failure prevents agent stalls on timeouts |
| dnsmasq over custom DNS proxy | Zero custom code, config-only, battle-tested |
| Two virtiofsd instances over one | Clean separation of rw/ro policies per mount |
| Static binary over package manager | cloud-hypervisor not in Fedora repos; static binary is simplest |
