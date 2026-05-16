# Falco Kernel Matrix Tester

Automated testing framework for Falco kernel modules (.ko) and eBPF probes (.o) across multiple kernel versions and Linux distributions using QEMU direct kernel boot without requiring full rootfs or login.

## Quick Start

```bash
# Configure kernels to test
vim config/kernels.list

# Place kernel modules in modules/<distro>-<version>-<kernel>/
mkdir -p modules/ubuntu-20.04-5.4.0-42
cp falco_probe.ko modules/ubuntu-20.04-5.4.0-42/

# Run tests
./run_tests.sh
```

## Project Structure

```
kernel-matrix-tester/
├── downloader/              # Kernel download scripts
│   ├── ubuntu.sh
│   ├── centos.sh
│   ├── debian.sh
│   └── rocky.sh
├── builder/
│   ├── build_base.sh        # Build base initramfs (one-time)
│   └── build_per_kernel.sh  # Build per-kernel initramfs
├── config/
│   ├── kernels.list         # Kernel test matrix
│   ├── falco.yaml
│   └── falco_rules.yaml
├── kernels/                 # Downloaded vmlinuz
├── initramfs/               # Generated initramfs per kernel
├── modules/                 # Kernel modules per version
├── results/                 # Test logs
└── run_tests.sh             # Main orchestrator
```

## How It Works

### Architecture

- **Direct Kernel Boot**: QEMU loads kernel via `-kernel`, no BIOS/bootloader needed
- **Minimal initramfs**: Contains busybox + kernel modules only
- **Per-kernel build**: Each kernel gets its own initramfs with pre-injected modules
- **Version detection**: Init script detects kernel version and loads appropriate probes

### Workflow

1. **build_base.sh** - Create base initramfs with busybox
2. **downloader/\*.sh** - Download vmlinuz from distro repos
3. **build_per_kernel.sh** - Unpack base → inject modules → repack
4. **run_tests.sh** - Orchestrate: download → build → run QEMU → collect results

## Configuration

### kernels.list Format

```
# Format: distro:version:kernel_version
ubuntu:20.04:5.4.0-42
ubuntu:22.04:5.15.0-58
centos:7:3.10.0-1160
debian:11:5.10.0-8
rocky:8:4.18.0-305
```

### Supported Distributions

- **Ubuntu** - Mainline PPA or archive repos
- **Debian** - Official Debian repos
- **CentOS** - Vault repos
- **Rocky** - Vault repos

## Module Preparation

```bash
# Create directory for each kernel variant
mkdir -p modules/distro-version-kernel/

# Place kernel modules
cp falco_probe.ko modules/distro-version-kernel/
cp falco_probe.o modules/distro-version-kernel/

# Auto-detection: kernel < 4.14 loads .ko only, >= 4.14 loads both
```

## Requirements

- QEMU: `apt-get install qemu-system-x86`
- Tools: `wget`, `curl`, `cpio`
- Optional: `rpm2cpio` for CentOS/Rocky, `ar` for Debian/Ubuntu (pre-installed)

## Running Tests

```bash
# Make scripts executable
chmod +x *.sh builder/*.sh downloader/*.sh

# Run full test matrix
./run_tests.sh

# View results
cat results/<kernel_name>.log
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| QEMU not found | `apt-get install qemu-system-x86` |
| Download fails | Check connectivity and kernel availability |
| Module load fails | Verify kernel compatibility |
| Slow boot | Enable KVM (requires `/dev/kvm`) |

## Performance

- First run: ~5-10 minutes per kernel (download + build)
- Subsequent: ~30 seconds per kernel (cached)
- Enable KVM for speedup
- QEMU boot timeout: 30 seconds