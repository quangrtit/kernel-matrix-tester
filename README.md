# Falco Kernel Matrix Tester

> Automated testing of Falco kernel module (`.ko`) and eBPF probe (`.o`) across hundreds of kernel versions and distros using direct QEMU boot — no disk image or bootloader required.

---

## Problem

Falco must work across many kernel versions (2.x → 6.x) and many distros (CentOS, Ubuntu, Debian, AlmaLinux, Rocky, Oracle, RHEL). Manually verifying each kernel is not feasible. This framework automates the entire pipeline: download kernel → download driver → boot VM → record results.

---

## System Overview

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │  STEP 1 — Collect kernels                                           │
 │                                                                     │
 │  sync_kernels.sh                                                    │
 │  ┌──────────┐   crawl   ┌──────────────────┐  extract   ┌────────┐ │
 │  │  distro  │ ────────► │  package repo    │ ─────────► │vmlinuz │ │
 │  │  crawler │           │  (vault/archive) │            │  disk  │ │
 │  └──────────┘           └──────────────────┘            └────────┘ │
 │  centos / ubuntu / debian / almalinux / rocky / oracle / redhat     │
 └─────────────────────────────────────────────────────────────────────┘
                                │
                                │  kernels/{distro}-{release}-{ver}/vmlinuz
                                │  config/kernels.list
                                ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │  STEP 2 — Run tests (run_tests.sh)                   per kernel    │
 │                                                                     │
 │  kernels.list                                                       │
 │      │                                                              │
 │      ▼ [1] Discover uname -r                                        │
 │      │     (read from vmlinuz binary or quick boot)                 │
 │      │                                                              │
 │      ▼ [2] Download Falco drivers                                   │
 │      │     ┌─────────────────────┐   ┌──────────────────────────┐  │
 │      │     │  Custom server      │ ► │  Falco CDN (fallback)    │  │
 │      │     │  test_server/ :8080 │   │  CloudFront / S3         │  │
 │      │     └─────────────────────┘   └──────────────────────────┘  │
 │      │     → modules/falco_{distro}_{kver}_x86_64.{ko|o}           │
 │      │                                                              │
 │      ▼ [3] Build initramfs                                          │
 │      │     base initramfs + Falco binary + driver → initramfs/     │
 │      │                                                              │
 │      ▼ [4] QEMU boot                                                │
 │      │     -kernel vmlinuz  -initrd initramfs  -nographic           │
 │      │                                                              │
 │      ▼ [5] Collect results                                          │
 │            results/{kname}.log  ·  results/cache.json              │
 └─────────────────────────────────────────────────────────────────────┘
```

**Sample output for one kernel:**
```
[BOOT]       kernel booted OK
[KO]  PASS   falco_probe.ko loaded
[BPF] PASS   falco_probe.o  loaded  (kernel ≥ 4.14)
[FALCO_KO]   PASS  engine=kmod  events=3
RESULT: KO_PASS=1 KO_FAIL=0 BPF_PASS=1 BPF_FAIL=0
ALL_DONE
```

---

## Quick Start

```bash
apt-get install qemu-system-x86 curl cpio gzip busybox-static rpm2cpio python3-yaml binutils

./setup.sh        # full pipeline: prereqs → Falco binary → base initramfs → sync → test
```

---

## Step-by-Step Guide

### 1. Sync kernel vmlinuz

```bash
# All distros
./sync_kernels.sh

# Specific distros
./sync_kernels.sh centos ubuntu almalinux

# Dry run (no downloads)
./sync_kernels.sh --dry-run
```

Limit the number of kernels downloaded (for quick testing):

```bash
# At most 20 kernels per (distro × major version)
TEST_MODE=1 ./sync_kernels.sh

TEST_MODE=1 MAX_PER_MAJOR=5 ./sync_kernels.sh centos

# Skip kernels 6.x and above (default MAX_KERNEL_MAJOR=5)
MAX_KERNEL_MAJOR=6 ./sync_kernels.sh ubuntu
```

---

### 2. Prepare Falco drivers

Drivers are resolved in order:

```
1. Custom server   →  {server_url}/falco_{distro}_{kver}_x86_64.{ko|o}
2. Falco CDN       →  CloudFront / S3 listing (automatic fallback)
```

**Using a local server for testing:**

```bash
# Terminal 1 — start the server
./test_server/serve.sh          # port 8080

# config/driver_server.yaml
server_url: http://localhost:8080
```

Place driver files in `test_server/` using the correct naming format:
```
falco_{distro}_{kernel_version}_x86_64.ko
falco_{distro}_{kernel_version}_x86_64.o

# Examples:
falco_centos_3.10.0-1160.108.1.el7_x86_64.ko
falco_ubuntu_5.4.0-52-generic_x86_64.o
```

If you downloaded drivers manually from the Falco CDN (which includes `_revision` and `_tag`), rename them as follows:
```bash
# CDN:  falco_centos_3.10.0-1160.el7.x86_64_1.ko
# Ours: falco_centos_3.10.0-1160.el7_x86_64.ko
#       (drop .x86_64 from version, drop _1 revision)

# CDN:  falco_ubuntu-generic_5.4.0-52-generic_57.ko
# Ours: falco_ubuntu_5.4.0-52-generic_x86_64.ko
#       (ubuntu-generic → ubuntu, drop _57 revision)
```

---

### 3. Run tests

```bash
# All kernels in kernels.list
./run_tests.sh

# Filter by distro
DISTRO=centos ./run_tests.sh
DISTRO=ubuntu ./run_tests.sh

# Filter by version (substring match)
KERNEL_FILTER=4.18.0 ./run_tests.sh
DISTRO=redhat KERNEL_FILTER=5.14.0-570.24.1.el9_6 ./run_tests.sh

# Re-run even if cached
USE_CACHE=0 DISTRO=almalinux ./run_tests.sh
USE_CACHE=0 KERNEL_FILTER=4.18.0-553 ./run_tests.sh

# No delay between kernels
KERNEL_DELAY=0 ./run_tests.sh
```

---

### 4. Read results

```bash
# View result for one kernel
grep "RESULT:" results/centos-7-3.10.0-1160.108.1.el7.log

# Live follow
tail -f results/centos-7-3.10.0-1160.108.1.el7.log

# All FAIL kernels
grep -rl "status=FAIL" results/*.log

# Last 5 lines of each failed kernel
for f in results/*.log; do
    grep -q "status=FAIL" "$f" && echo "=== $f ===" && tail -5 "$f"
done

# Overview from cache
cat results/cache.json | python3 -m json.tool | grep -E '"status"|"result_line"'
```

---

## Kernel Management

### Prune — keep N kernels per group

Groups are by `(distro, major_version)`: 2.x, 3.x, 4.x, 5.x, 6.x.

```bash
python3 prune_kernels.py --dry-run          # preview
python3 prune_kernels.py --keep 20          # keep 20 per group
python3 prune_kernels.py --keep 10 centos   # centos only
```

Each pruned kernel removes: `kernels/{kname}/`, `initramfs/{kname}.img`, `modules/falco_{...}.ko/.o`

### Clean — remove artifacts

```bash
./clean.sh                # remove initramfs + results (keep kernels/modules)
./clean.sh --results      # remove logs only
./clean.sh --modules      # also remove Falco drivers
./clean.sh --kernels      # also remove vmlinuz
./clean.sh --all          # remove everything including Falco binary
```

---

## Common Workflows

### Quick test (limited set)

```bash
# Prune down to 5 kernels per group, then test
python3 prune_kernels.py --keep 5
./run_tests.sh
```

### Sync + test one distro

```bash
./sync_kernels.sh centos
DISTRO=centos ./run_tests.sh
```

### Re-test failed kernels

```bash
# Get list of FAILED kernels from cache
python3 -c "
import json
c = json.load(open('results/cache.json'))
for k,v in c.items():
    if v.get('status') == 'FAILED':
        print(k)
"

# Re-run with USE_CACHE=0 + filter
USE_CACHE=0 DISTRO=centos KERNEL_FILTER=4.18.0-305 ./run_tests.sh
```

### Full pipeline from scratch

```bash
./setup.sh                    # full
TEST_MODE=1 ./setup.sh        # limit to 20 per group
./setup.sh --sync-only        # sync only, no test
```

---

## Supported Distros

| Distro | Versions | Source |
|--------|----------|--------|
| CentOS | 6, 7, 8 | `vault.centos.org` |
| AlmaLinux | 8, 9 | `vault.almalinux.org` |
| Rocky | 8, 9 | `dl.rockylinux.org/vault/rocky` |
| Ubuntu | trusty → noble | `archive.ubuntu.com` |
| Debian | squeeze → bookworm | `snapshot.debian.org` |
| Oracle | OL6–OL9 (incl. UEK) | `yum.oracle.com` |
| Red Hat | RHEL6–RHEL9 | RHSM API — requires `offline_token` |

Red Hat requires a subscription. Set `offline_token` in `downloader/redhat/config.yaml`.

---

## Project Structure

```
kernel-matrix-tester/
│
├── sync_kernels.sh          # sync vmlinuz from repos
├── run_tests.sh             # run boot tests
├── setup.sh                 # full pipeline
├── prune_kernels.py         # reduce kernel count
├── clean.sh                 # remove artifacts
│
├── config/
│   ├── kernels.list         # distro:release:kernel_version
│   └── driver_server.yaml   # custom server URL + CDN fallback
│
├── downloader/
│   ├── falco_drivers.sh     # download .ko/.o (custom server → CDN)
│   └── {distro}/            # per-distro crawler
│       ├── config.yaml
│       └── crawler.py
│
├── builder/
│   ├── build_base.sh        # base initramfs (Falco + busybox)
│   └── build_per_kernel.sh  # inject driver into base
│
├── test_server/             # local server for testing
│   ├── serve.sh             # python3 -m http.server 8080
│   ├── generate.sh          # generate fake drivers from kernels.list
│   └── falco_*.ko / *.o     # driver files (real or fake)
│
├── kernels/                 # vmlinuz per distro-release-kver/
├── initramfs/               # per-kernel initramfs images
├── modules/                 # falco_{distro}_{kver}_x86_64.{ko|o}
└── results/                 # *.log + cache.json
```

---

## kernels.list Format

```
# distro:release:kernel_version
centos:7:3.10.0-1160.108.1.el7
centos:8:4.18.0-553.el8_10
almalinux:9:5.14.0-503.el9_5
ubuntu:focal:5.4.0-195-generic
ubuntu:jammy:5.15.0-139-generic
debian:bullseye:5.10.0-25-amd64
oracle:OL8:5.4.17-2136.340.7.4.el8uek
redhat:rhel9:5.14.0-570.24.1.el9_6
```

From these 3 fields, all artifact paths are derived:

| Artifact | Path |
|----------|------|
| Kernel | `kernels/{distro}-{release}-{kver}/vmlinuz` |
| Driver | `modules/falco_{distro}_{kver}_x86_64.{ko\|o}` |
| Initramfs | `initramfs/{distro}-{release}-{kver}.img` |
| Log | `results/{distro}-{release}-{kver}.log` |
