# Directory Restructure Design

## Problem

The current layout splits state across two locations: the repo directory (scripts) and `~/.claude-sandbox/` (build artifacts, runtime state). This makes it hard for someone else to clone the repo and get started. Build artifacts and runtime files are mixed together in `~/.claude-sandbox/`. The hostname allowlist is coupled to `~/.claude/settings.json`, which is a per-user Claude Code config file unrelated to this project.

## Design

Move everything into the repo directory with clear separation between source, build output, and runtime state.

### Directory Layout

```
claude-sandbox/
├── config/
│   ├── config.sh                 # tunables (networking, VM resources, paths)
│   ├── allowlist.txt.example     # sample hostnames, committed
│   └── allowlist.txt             # actual allowlist, gitignored
├── build/                        # all build artifacts, gitignored
│   ├── vmlinux
│   ├── initrd.img
│   └── rootfs.raw
├── run/                          # runtime state, gitignored
│   ├── ch-api.sock
│   ├── dnsmasq.pid
│   ├── dnsmasq.conf
│   ├── dnsmasq-nftset.conf
│   ├── dnsmasq.log
│   ├── serial.log
│   └── virtiofs-*.sock
├── claude-sandbox.sh
├── build-rootfs.sh
├── build-rootfs-debug.sh
├── .gitignore
├── notes.md
└── README.md
```

### Changes

1. **Eliminate `~/.claude-sandbox/`**. All paths in `config.sh` become repo-relative using `SCRIPT_DIR`.

2. **`build/` directory** (gitignored). `build-rootfs.sh` writes `rootfs.raw` here and extracts `vmlinux` and `initrd.img` from the guest image into this directory.

3. **`run/` directory** (gitignored). `claude-sandbox.sh` creates this at startup for sockets, pidfiles, generated dnsmasq configs, and logs.

4. **`config/` directory**. `config.sh` moves here. The hostname allowlist becomes `config/allowlist.txt` (plain text, one hostname per line, `#` comments). A sample `config/allowlist.txt.example` is committed; `config/allowlist.txt` is gitignored.

5. **Allowlist decoupled from `~/.claude/settings.json`**. The `generate_dnsmasq_nftset_conf` function reads from `config/allowlist.txt` instead of parsing JSON with `jq`. This removes the `jq` dependency for allowlist parsing.

### Allowlist Format

```
# config/allowlist.txt
# One hostname per line. Lines starting with # are comments.

# Anthropic
api.anthropic.com
claude.ai
statsig.anthropic.com

# GitHub
github.com
api.github.com

# npm
registry.npmjs.org
```

### Path Resolution

`config.sh` derives all paths from `SCRIPT_DIR` (the repo root):

- `BUILD_DIR="${REPO_ROOT}/build"`
- `RUNTIME_DIR="${REPO_ROOT}/run"`
- `ALLOWLIST_FILE="${REPO_ROOT}/config/allowlist.txt"`
- `KERNEL_PATH="${BUILD_DIR}/vmlinux"`
- `INITRD_PATH="${BUILD_DIR}/initrd.img"`
- `ROOTFS_PATH="${BUILD_DIR}/rootfs.raw"`

### What Stays the Same

- `VIRTIOFS_MOUNTS` still references `$REAL_HOME/work` (rw) and `$REAL_HOME/.claude` (ro) -- these are host paths the VM mounts, inherently user-specific.
- SSH key injection in `build-rootfs.sh` still reads from `$REAL_HOME/.ssh/`.
- All networking config (TAP device, IPs, subnets) unchanged.
