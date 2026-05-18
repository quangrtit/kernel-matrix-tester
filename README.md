# Falco Kernel Matrix Tester

Production-grade automated testing framework for Falco kernel modules (.ko) and eBPF probes (.o) across multiple kernel versions and Linux distributions. Uses QEMU direct kernel boot for fast, isolated testing without full filesystem or login requirements.

## Quick Start

```bash
# 1. Run setup (downloads Falco, builds base initramfs)
./setup.sh

# 2. Configure test matrix
vim config/kernels.list

# 3. Run full test suite
./run_tests.sh
```

## Test Output Example

```
[BOOT] kernel=3.10.0-1160.el7.x86_64 arch=x86_64

--- Module Tests (.ko) ---
[KO] falco_probe.ko PASS module=falco

--- Falco Tests ---
[FALCO_STEP] [FALCO_KO] loading probe (engine=kmod)
[FALCO_STEP] [FALCO_KO] kmod loaded: falco
[FALCO_STEP] [FALCO_KO] running at 8s (process alive)
[FALCO_OUT] Syscall event drop monitoring: 0 occurrences
[FALCO_OUT] Events detected: 2
[FALCO_OUT] Rule counts by severity:
[FALCO_OUT]    CRITICAL: 1
[FALCO_OUT]    WARNING: 1
[FALCO_OUT] Triggered rules:
[FALCO_OUT]    Test - Read process environ: 1
[FALCO_OUT]    Test - Execute from /tmp: 1
[FALCO_KO] PASS engine=kmod events=2

RESULT: KO_PASS=1 KO_FAIL=0 FALCO_KO=PASS
```

## Features

✅ **Multi-Distribution Testing**: Ubuntu, Debian, CentOS, Rocky, AlmaLinux  
✅ **Kernel Version Matrix**: Test 2.6+ to 6.x kernels  
✅ **Module Auto-Detection**: Kernel < 4.14 (.ko only) | >= 4.14 (.ko + .o eBPF)  
✅ **Direct Kernel Boot**: QEMU boots kernel directly, no BIOS/bootloader  
✅ **Event Verification**: Real Falco event detection testing  
✅ **Caching**: Reuse downloaded kernels and built initramfs  
✅ **Parallel Testing**: Run multiple kernels efficiently  

## Project Structure

```
kernel-matrix-tester/
├── setup.sh                 # Full setup: Falco + base initramfs + test
├── run_tests.sh             # Main test orchestrator
├── cleanup.sh               # Clean build artifacts
├── downloader/
│   ├── falco_binary.sh      # Download Falco binary
│   ├── falco_drivers.sh     # Download .ko/.o modules
│   ├── ubuntu.sh            # Ubuntu kernel downloader
│   ├── debian.sh
│   ├── centos.sh
│   ├── rocky.sh
│   └── almalinux.sh
├── builder/
│   ├── build_base.sh        # Build base initramfs (one-time)
│   └── build_per_kernel.sh  # Build per-kernel initramfs
├── config/
│   ├── kernels.list         # Kernel test matrix
│   ├── falco.yaml           # Falco configuration
│   └── falco_rules.yaml     # Test rules
├── kernels/                 # Downloaded vmlinuz
├── initramfs/               # Generated per-kernel initramfs
├── modules/                 # Falco kernel drivers
└── results/                 # Test logs
```

## Configuration

### kernels.list Format

Each line: `distro:version:kernel_version`

```bash
# Supported distros: ubuntu, debian, centos, rocky, almalinux
ubuntu:20.04:5.4.0-42
ubuntu:22.04:5.15.0-58
centos:7:3.10.0-1160
debian:11:5.10.0-30-amd64
rocky:9:5.14.0-362
almalinux:9:5.14.0-362
```

**How to find available kernel versions:**

```bash
# Ubuntu mainline
curl -s https://kernel.ubuntu.com/mainline/ | grep -oP 'v\d+\.\d+\.\d+' | sort -V | tail -10

# Debian
apt-cache search linux-image | grep 'amd64'

# CentOS
curl -s http://vault.centos.org/centos/7/updates/x86_64/Packages/ | grep kernel-

# Rocky
curl -s https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/k/ | grep kernel-core-
```

## Setup Workflow

### First Run: `./setup.sh`

```
1. Check prerequisites (qemu, wget, curl, busybox, etc.)
2. Download Falco binary (0.43.1)
3. Build base initramfs with Falco + busybox
4. For each kernel in kernels.list:
   a. Download vmlinuz from distro repo
   b. Boot with QEMU to discover actual kernel version (uname -r)
   c. Download Falco kernel drivers (.ko/.o) for that exact version
   d. Build per-kernel initramfs (base + modules)
   e. Run Falco test with event generation
   f. Collect and log results
```

### Subsequent Runs: `./run_tests.sh`

Uses cached kernels/modules/initramfs for faster testing (~30s per kernel).

## Requirements

**Packages:**
```bash
apt-get install qemu-system-x86 wget curl cpio busybox-static rpm2cpio
```

**System:**
- x86_64 architecture
- ~2GB RAM available
- KVM optional but recommended (`/dev/kvm`)

## How It Works

### Architecture

1. **Direct Kernel Boot**: QEMU `-kernel` flag loads vmlinuz directly to RAM
2. **Minimal Initramfs**: Contains only busybox + Falco + kernel modules
3. **Per-Kernel Variant**: Each kernel gets own initramfs with matching modules pre-injected
4. **Auto-Detection**: Init script discovers kernel version and module compatibility
5. **Event Testing**: Runs Falco with syscall generation to verify detection

### Why Per-Kernel Initramfs?

Most distro kernels compile drivers as modules (CONFIG_VIRTIO_9P=m). Modules must be loaded at boot time. Since we're using QEMU direct kernel boot without virtfs, we pre-inject modules into initramfs before boot.

## Running Tests

### Full Setup + Test
```bash
chmod +x *.sh builder/*.sh downloader/*.sh
./setup.sh              # First run: downloads Falco + kernels + builds everything
```

### Quick Test (cached)
```bash
./run_tests.sh          # Uses cached kernels/modules/initramfs
```

### Clean Up
```bash
./cleanup.sh soft       # Remove initramfs + logs (keep kernels)
./cleanup.sh all        # Remove everything
```

## Test Results

Logs saved to `results/<distro>-<version>-<kernel>.log`

**Test Sections:**
- `[BOOT]` - Kernel boot info
- `[KO]` - Kernel module (.ko) tests
- `[BPF]` - eBPF probe (.o) tests (kernel >= 4.14)
- `[FALCO_STEP]` - Falco startup and event generation
- `[FALCO_OUT]` - Event detection results
- `[RESULT]` - Summary (PASS/FAIL/SKIP counts)

**Example:**
```
[BOOT] kernel=3.10.0-1160.el7.x86_64 arch=x86_64
[KO] falco_probe.ko PASS module=falco
[FALCO_STEP] running at 8s (process alive)
[FALCO_OUT] Events detected: 2
[FALCO_OUT] CRITICAL: 1, WARNING: 1
[FALCO_KO] PASS engine=kmod events=2
RESULT: KO_PASS=1 KO_FAIL=0 FALCO_KO=PASS
```

## Troubleshooting

| Issue | Check |
|-------|-------|
| QEMU timeout | Check `results/<kernel>.log` - may need more time |
| Module load fails | Kernel version mismatch - verify in results |
| Download fails | Internet/URL check - run `./test_download.sh <distro> <version> <kernel>` |
| Slow boot | Enable KVM: `ls -la /dev/kvm` should exist and be readable |
| Falco not starting | Check `falco` binary exists: `ls -la kernels/<name>/falco` |

## Advanced Usage

### Run Single Kernel
```bash
echo "centos:7:3.10.0-1160" > config/kernels.list
./run_tests.sh
```

### Parallel Testing
```bash
KERNEL_DELAY=0 ./run_tests.sh  # No delay between kernels
```

### Keep Verbose Logs
```bash
./run_tests.sh 2>&1 | tee full_test.log
```

### Debug Mode
```bash
bash -x ./setup.sh              # Print all commands
```

## Performance Notes

- **First run**: 10-15 minutes (download Falco 100MB + multiple kernels)
- **Subsequent runs**: 30-60 seconds per kernel (from cache)
- **Per-kernel time**: 
  - Download: 1-3 min
  - Build initramfs: 5-10s
  - QEMU boot + test: 15-30s
- **KVM enabled**: ~2x faster boot times

## Extending

### Add New Distribution

Create `downloader/<distro>.sh`:

```bash
#!/bin/bash
KERNEL_VER=$1
OUTPUT_DIR=$2
# Download and extract vmlinuz to $OUTPUT_DIR/vmlinuz
```

Use the existing distro scripts as templates.

### Customize Test Logic

Edit init script section in `builder/build_base.sh` or Falco test section in `setup.sh`.

## Known Limitations

- CentOS/RHEL 6 deprecated (kernel 2.6, low demand)
- eBPF probes (.o) require kernel 4.14+ 
- No virtfs/9p due to module limitations
- Maximum test time 30s per kernel (configurable in scripts)