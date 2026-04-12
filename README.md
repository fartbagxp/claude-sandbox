# Claude Code Sandbox

Run Claude Code inside a cloud-hypervisor microVM with hostname-based egress filtering.

## Prerequisites

- Linux with KVM support (`/dev/kvm` accessible)
- Install dependencies:

```bash
# cloud-hypervisor
wget https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/cloud-hypervisor-static \
    -O /usr/local/bin/cloud-hypervisor
chmod +x /usr/local/bin/cloud-hypervisor
sudo setcap cap_net_admin+ep /usr/local/bin/cloud-hypervisor

# virtiofsd (installed to /usr/libexec on Fedora — symlink it)
sudo dnf install virtiofsd
sudo ln -s /usr/libexec/virtiofsd /usr/local/bin/virtiofsd

# System packages
sudo dnf install dnsmasq nftables libguestfs-tools-c
```

## Setup

1. Copy and customize the allowlist:

```bash
cp config/allowlist.txt.example config/allowlist.txt
# Edit config/allowlist.txt to add/remove allowed hosts
```

2. Build the guest rootfs (Debian 13 Trixie):

```bash
./build-rootfs.sh
```

The kernel and initramfs are extracted automatically from the guest rootfs by
`build-rootfs.sh` into `build/vmlinux` and `build/initrd.img`.

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

The hostname allowlist is read from `config/allowlist.txt` (one hostname per line, `#` comments supported). To update:

1. Edit `config/allowlist.txt` and add/remove hosts
2. Restart the sandbox (`stop` then `start`)

## Architecture

See [design doc](../docs/plans/2026-04-09-claude-sandbox-design.md) for full details.

- **Egress filtering**: nftables FORWARD chain with dnsmasq `nftset` directive
- **Filesystem**: virtiofs (rw for workspace, ro for claude config)
- **VM**: cloud-hypervisor with seccomp enabled
- **Guest OS**: Debian 13 (Trixie)
