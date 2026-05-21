# Falco Kernel Matrix Tester

Automated framework for testing Falco kernel modules (`.ko`) and eBPF probes (`.o`) across many kernel versions and Linux distributions. Uses QEMU direct kernel boot — no full disk image or bootloader required.

---

## How It Works

```
sync_kernels.sh  ──►  kernels/{kname}/vmlinuz
                       config/kernels.list

run_tests.sh  (per kernel in kernels.list):
  1. Discover uname -r  (from vmlinuz binary or quick boot)
  2. Download Falco drivers  ──►  modules/{kname}/falco_probe.ko/.o
  3. Build per-kernel initramfs  ──►  initramfs/{kname}.img
  4. Boot QEMU  (-kernel vmlinuz -initrd initramfs)
  5. Run tests inside VM, collect results  ──►  results/{kname}.log
                                                 results/cache.json
```

---

## Prerequisites

```bash
apt-get install qemu-system-x86 curl cpio gzip busybox-static rpm2cpio python3-yaml binutils
```

| Tool | Purpose |
|------|---------|
| `qemu-system-x86_64` | VM boot |
| `curl` | Downloads |
| `cpio`, `gzip` | initramfs packing |
| `busybox` | initramfs userland |
| `rpm2cpio` | extract vmlinuz from RPM |
| `ar` | extract vmlinuz from .deb |
| `python3-yaml` | crawler config parsing |
| `strings` (binutils) | fast uname -r discovery |
| `/dev/kvm` | 2× faster boot (optional) |

---

## Quick Start

```bash
# Full pipeline (prereqs check → Falco binary → base initramfs → sync kernels → boot tests)
./setup.sh

# Or step by step:
./sync_kernels.sh          # 1. download vmlinuz for all distros
./run_tests.sh             # 2. build initramfs + boot test each kernel
```

---

## Syncing Kernels (`sync_kernels.sh`)

Downloads vmlinuz from each distro's package repo, extracts it, and registers the entry in `config/kernels.list`. Kernels already on disk are skipped (cached).

```bash
# All distros
./sync_kernels.sh

# Specific distros only
./sync_kernels.sh centos almalinux rocky

# Preview what would be downloaded (no actual download)
./sync_kernels.sh --dry-run
./sync_kernels.sh centos --dry-run
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_KERNEL_MAJOR` | `5` | Skip kernels with major version > this (e.g. skip 6.x) |
| `TEST_MODE` | `0` | Set `1` to limit downloads to `MAX_PER_MAJOR` per group |
| `MAX_PER_MAJOR` | `20` | Max kernels per (distro × major_version) in test mode |

```bash
# Test mode: download at most 20 kernels per major version per distro
TEST_MODE=1 ./sync_kernels.sh

# Test mode, custom limit
TEST_MODE=1 MAX_PER_MAJOR=10 ./sync_kernels.sh centos

# Allow kernel 6.x as well
MAX_KERNEL_MAJOR=6 ./sync_kernels.sh ubuntu
```

---

## Running Tests (`run_tests.sh`)

For each kernel in `config/kernels.list`, builds a per-kernel initramfs with Falco drivers injected, boots it under QEMU, and records PASS/FAIL.

```bash
# All kernels
./run_tests.sh

# Filter by distro
DISTRO=centos ./run_tests.sh
DISTRO=ubuntu ./run_tests.sh

# Filter by kernel version substring
KERNEL_FILTER=4.18.0 ./run_tests.sh
KERNEL_FILTER=3.10.0-1160.59.1.el7 ./run_tests.sh

# Combine filters
DISTRO=centos KERNEL_FILTER=4.18.0 ./run_tests.sh

# Re-run even if previously cached
USE_CACHE=0 ./run_tests.sh
USE_CACHE=0 KERNEL_FILTER=4.18.0-305 ./run_tests.sh

# No delay between kernels
KERNEL_DELAY=0 ./run_tests.sh
```

### Result cache

Results are cached in `results/cache.json`. A kernel is only re-tested if it previously timed out or panicked (incomplete runs are never cached). Force re-run with `USE_CACHE=0`.

### Reading logs

Each kernel writes one log file: `results/{kname}.log`

```bash
# See results summary
grep "RESULT:" results/centos-7-3.10.0-1160.59.1.el7.log

# Watch live output of a running test
tail -f results/centos-7-3.10.0-1160.59.1.el7.log

# Find all failures
grep -l "FAIL" results/*.log

# See last 20 lines of each failed kernel
for f in results/*.log; do grep -q "status=FAIL" "$f" && echo "=== $f ===" && tail -5 "$f"; done
```

---

## Pruning Kernels (`prune_kernels.py`)

Reduces the kernel set to N per `(distro, major_version)` group. Groups kernels by their leading version digit: 2.x, 3.x, 4.x, 5.x. Deletes all three artifacts for pruned kernels: vmlinuz, initramfs, and modules.

```bash
# Preview what would be deleted (safe, no changes)
python3 prune_kernels.py --dry-run

# Keep 20 newest per group across all distros
python3 prune_kernels.py --keep 20

# Prune only specific distros
python3 prune_kernels.py --keep 20 centos almalinux

# Custom keep count
python3 prune_kernels.py --keep 5 ubuntu
```

Artifacts removed per pruned kernel:
- `kernels/{kname}/` — vmlinuz
- `initramfs/{kname}.img` — per-kernel initramfs
- `modules/{kname}/` — Falco driver modules

`config/kernels.list` is updated automatically.

---

## Typical Workflows

### Test mode (limited set)

```bash
# Step 1: prune existing kernels down to 20/group
python3 prune_kernels.py --dry-run    # preview first
python3 prune_kernels.py --keep 20

# Step 2: run tests on the pruned set
./run_tests.sh
```

### Run one specific kernel

```bash
KERNEL_FILTER=3.10.0-1160.59.1.el7 ./run_tests.sh

# Force re-run ignoring cache
USE_CACHE=0 KERNEL_FILTER=3.10.0-1160.59.1.el7 ./run_tests.sh
```

### Full pipeline on a fresh machine

```bash
./setup.sh                         # everything (full set)
TEST_MODE=1 ./setup.sh             # everything (limited set, 20/major)
```

### Sync only, no tests

```bash
./setup.sh --sync-only
# or
./sync_kernels.sh
```

### Re-sync after pruning (restore deleted kernels)

```bash
./sync_kernels.sh centos           # re-downloads missing centos kernels
```

---

## Project Structure

```
kernel-matrix-tester/
├── setup.sh                   # Full pipeline: prereqs → Falco → base initramfs → sync → test
├── sync_kernels.sh            # Download vmlinuz per distro, register in kernels.list
├── run_tests.sh               # Boot test runner (reads kernels.list)
├── prune_kernels.py           # Trim to N kernels per (distro × major_version)
│
├── config/
│   ├── kernels.list           # Test matrix: distro:release:kernel_version
│   ├── driver_server.yaml     # Falco driver server URL
│   ├── falco.yaml             # Falco runtime config
│   └── falco_rules_minimal.yaml
│
├── downloader/
│   ├── lib.py                 # Shared HTTP/HTML fetch utilities
│   ├── filter_urls.py         # URL limiter for TEST_MODE
│   ├── falco_binary.sh        # Download Falco binary
│   ├── falco_drivers.sh       # Download Falco .ko/.o for a kernel
│   ├── ubuntu/
│   │   ├── config.yaml        # archive.ubuntu.com config
│   │   └── crawler.py
│   ├── centos/
│   │   ├── config.yaml        # vault.centos.org config (el6/7/8)
│   │   └── crawler.py
│   ├── almalinux/
│   │   ├── config.yaml        # vault.almalinux.org config (al8/9)
│   │   └── crawler.py
│   ├── rocky/
│   │   ├── config.yaml        # dl.rockylinux.org config (r8/9)
│   │   └── crawler.py
│   ├── debian/
│   │   ├── config.yaml        # snapshot.debian.org config
│   │   └── crawler.py
│   ├── oracle/
│   │   ├── config.yaml        # yum.oracle.com config (OL6–OL9)
│   │   └── crawler.py
│   └── redhat/
│       ├── config.yaml        # RHSM API config — requires offline_token
│       └── crawler.py
│
├── builder/
│   ├── build_base.sh          # Build shared base initramfs (Falco + busybox)
│   └── build_per_kernel.sh    # Inject per-kernel Falco modules into base
│
├── kernels/                   # Downloaded vmlinuz files
│   └── centos-8-4.18.0-305.el8/
│       └── vmlinuz
├── initramfs-base.img         # Shared base initramfs (built once)
├── initramfs/                 # Per-kernel initramfs images
│   └── centos-8-4.18.0-305.el8.img
├── modules/                   # Falco drivers per kernel
│   └── centos-8-4.18.0-305.el8/
│       ├── falco_probe.ko
│       └── falco_probe.o
└── results/                   # Test outputs
    ├── cache.json             # Persistent result cache (PASS/FAIL per kernel)
    └── centos-8-4.18.0-305.el8.log   # Full log per kernel
```

---

## kernels.list Format

```
# distro:release:kernel_version
centos:7:3.10.0-1160.108.1.el7
centos:8:4.18.0-553.el8_10
almalinux:9:5.14.0-503.el9_5
rocky:8:4.18.0-348.20.1.el8_5
ubuntu:focal:5.4.0-195-generic
ubuntu:jammy:5.15.0-139-generic
debian:bullseye:5.10.0-25-amd64
oracle:OL8:5.4.17-2136.340.7.4.el8uek
```

`kernel_version` is the exact string from the RPM/deb filename, used to construct the directory name `{distro}-{release}-{kernel_version}`.

---

## Supported Distributions

| Distro | Versions | Source |
|--------|----------|--------|
| CentOS | 6, 7, 8 | `vault.centos.org` |
| AlmaLinux | 8, 9 | `vault.almalinux.org` |
| Rocky | 8, 9 | `dl.rockylinux.org/vault/rocky` |
| Ubuntu | trusty → noble | `archive.ubuntu.com` |
| Debian | squeeze → bookworm | `snapshot.debian.org` |
| Oracle | OL6–OL9 (incl. UEK) | `yum.oracle.com` |
| Red Hat | RHEL6–RHEL9 | RHSM API (requires subscription + `offline_token` in `downloader/redhat/config.yaml`) |

RedHat is disabled by default in `downloader/config.yaml`. Enable by uncommenting the `redhat` line and setting a valid `offline_token`.

---

## Crawlers

Each distro has its own crawler in `downloader/{distro}/`:

```bash
# List package URLs (no download)
python3 downloader/centos/crawler.py --list
python3 downloader/ubuntu/crawler.py --list --verbose

# RedHat only: full download pipeline (handles CDN auth internally)
python3 downloader/redhat/crawler.py --download \
    --kernels-dir kernels \
    --kernels-list config/kernels.list \
    --max-major 5
```

---

## VM Test Output Format

The init script inside the VM emits structured `[TAG]` lines to serial:

```
[BOOT] kernel=4.18.0-305.el8.x86_64 arch=x86_64     ← kernel booted successfully

[KO] falco_probe.ko PASS module=falco                 ← .ko loaded OK
[KO] falco_probe.ko FAIL Operation not permitted      ← .ko load failed

[BPF] falco_probe.o PASS                              ← eBPF probe loaded OK
[BPF] falco_probe.o SKIP kernel<4.14                  ← kernel too old for eBPF

[FALCO_KO]   PASS engine=kmod events=3                ← Falco ran OK with .ko
[FALCO_EBPF] FAIL ...                                 ← Falco failed with eBPF
[FALCO_EBPF] SKIP no-probe                            ← no .o available

RESULT: KO_PASS=1 KO_FAIL=0 BPF_PASS=0 BPF_FAIL=0 BPF_SKIP=1 FALCO_KO=PASS FALCO_EBPF=SKIP
ALL_DONE
```

`ALL_DONE` signals a complete test cycle. Kernels that panic or time out before `ALL_DONE` are marked FAILED and not cached.
