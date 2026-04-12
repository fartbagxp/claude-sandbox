# Claude Sandbox - Networking Caveats & Fixes

## 1. Kernel/Initramfs Must Come From Guest Rootfs

cloud-hypervisor boots with an external kernel and initramfs (not from the disk image). If these don't match the guest's `/lib/modules`, the kernel won't have drivers for virtio devices (no network interface, no disk).

**Fix**: `build-rootfs.sh` extracts `vmlinuz` and `initrd.img` from the built rootfs using `virt-cat`, so they always match.

## 2. Guest /etc/resolv.conf Gets Overwritten (Two Layers)

### Layer 1: systemd-networkd doesn't write resolv.conf

systemd-networkd's `DNS=172.16.0.1` setting in the `.network` file does NOT automatically populate `/etc/resolv.conf`. That requires `systemd-resolved` to be active and `/etc/resolv.conf` symlinked to its stub. Without it, the guest ends up with stale DNS config.

### Layer 2: libguestfs hijacks /etc/resolv.conf during --run-command

libguestfs's `daemon/sh.c` (`set_up_etc_resolv_conf`) **renames** the guest's `/etc/resolv.conf` to a random backup before each `--run-command`, **copies** the appliance's resolv.conf (containing the host's DHCP DNS, e.g. `192.168.110.1`) into its place, runs the command, then **deletes** the copy and **restores** the backup. This means:

- Any `--run-command` that writes to `/etc/resolv.conf` is silently discarded
- `chattr +i` fails because the file is a temporary copy, not the real guest file
- dhcpcd (pulled in by `apt-get install` as a dependency) writes the host's DNS during the build, and that content persists as the "backup" that gets restored

**Symptom**: Guest resolv.conf contains `nameserver 192.168.110.1` (host's home router) despite explicit `echo 'nameserver 172.16.0.1' > /etc/resolv.conf` in `--run-command`.

**Fix**: Use `--write` (guestfs API, bypasses the rename/restore cycle) instead of `--run-command` for resolv.conf. Also purge `dhcpcd-base` during the build so its stale resolv.conf content is gone before `--write` runs.

## 3. Docker's iptables FORWARD Chain Drops VM Traffic

Docker uses legacy iptables (not nftables) and sets a **DROP policy** on the FORWARD chain. Both iptables and nftables FORWARD chains are evaluated for forwarded packets. An `accept` in our nftables chain does NOT prevent Docker's iptables chain from dropping the packet.

**Symptom**: nftables counters show packets matching `allowed_ips`, but tcpdump on the outbound interface shows nothing. `conntrack -E` shows no TCP entries. SYN packets silently vanish.

**Fix**: Insert iptables rules before Docker's:
```bash
sudo iptables -I FORWARD -i claude-tap0 -j ACCEPT
sudo iptables -I FORWARD -o claude-tap0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

## 4. firewalld Runtime vs Permanent Rules

`firewall-cmd` without `--permanent` creates runtime-only rules. A `firewall-cmd --reload` wipes them. This broke DNS connectivity after we added claude-tap0 to the trusted zone at runtime.

**Fix**: Always use `--permanent` when adding firewalld rules, then `--reload`:
```bash
sudo firewall-cmd --zone=trusted --add-interface=claude-tap0 --permanent
sudo firewall-cmd --reload
```

## 5. nftables Chain Priority and Multi-Chain Evaluation

nftables processes ALL chains registered at a hook point, not just the first match. An `accept` verdict in one chain (e.g., our `claude_filter forward` at priority 0) does NOT skip other chains (e.g., firewalld at priority filter+10). Only `drop` is terminal across chains.

This means even if our chain accepts a packet, firewalld or other chains can still drop it.

## 6. DNS Rules Belong in INPUT, Not FORWARD

Guest-to-host DNS traffic (guest → 172.16.0.1:53) is **locally delivered**, not forwarded. These rules must be in the INPUT chain. Putting them in FORWARD has no effect since the packet never enters the forwarding path.

## Outstanding Issues

- **firewalld interaction**: The trusted zone + forwarding policy setup for claude-tap0 should be scripted in `claude-sandbox.sh` rather than done manually.
