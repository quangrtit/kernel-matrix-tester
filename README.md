# Falco Kernel Matrix Tester

Automated framework for testing Falco kernel modules (`.ko`) and eBPF probes (`.o`) across many kernel versions and Linux distributions. Uses QEMU direct kernel boot — no full disk image or bootloader required.

## How It Works

For each kernel in `config/kernels.list`:

1. **Download vmlinuz** — fetches the kernel image from the distro vault
2. **Download Falco drivers** — `.ko` and `.o` from the Falco driver server
3. **Build initramfs** — packs busybox + Falco binary + drivers into a minimal initramfs
4. **Boot QEMU** — boots the kernel directly (`-kernel vmlinuz -initrd initramfs`)
5. **Run tests inside VM** — init script loads drivers, runs Falco, reports results
6. **Collect results** — structured logs per kernel in `results/<kernel>/`

## Quick Start

```bash
# Install prerequisites
apt-get install qemu-system-x86 curl cpio gzip busybox-static rpm2cpio python3-yaml ar

# 1. Generate the kernel test list (crawls distro repos — takes a few minutes)
./update_kernel_list.sh centos almalinux   # specific distros
# OR: ./update_kernel_list.sh              # all distros (slow)

# 2. Run setup + tests
./setup.sh

# OR: setup only (no boot tests), then test separately
./setup.sh --setup-only
./run_tests.sh
```

## Project Structure

```
kernel-matrix-tester/
├── setup.sh                   # Setup pipeline: download + drivers + initramfs → run_tests.sh
├── run_tests.sh               # Boot test runner (requires setup.sh to have run first)
├── update_kernel_list.sh      # Generate config/kernels.list from distro repos
│
├── config/
│   ├── kernels.list           # Test matrix: distro:release:kernel_version
│   ├── driver_server.yaml     # Falco driver server URL (default: CloudFront)
│   ├── falco.yaml             # Falco configuration
│   └── falco_rules_minimal.yaml
│
├── downloader/
│   ├── crawl.py               # Generic repo crawler (reads YAML configs)
│   ├── crawl_all.sh           # Bulk-download vmlinuz for all distros
│   ├── configs/
│   │   ├── centos.yaml        # CentOS 6/7/8 vmlinuz crawler config
│   │   ├── almalinux.yaml     # AlmaLinux 8/9
│   │   ├── rocky.yaml         # Rocky 8/9
│   │   ├── ubuntu.yaml        # Ubuntu mainline
│   │   └── debian.yaml        # Debian stable
│   ├── centos.sh              # On-demand vmlinuz downloader for CentOS
│   ├── almalinux.sh
│   ├── rocky.sh
│   ├── ubuntu.sh
│   ├── debian.sh
│   ├── falco_binary.sh        # Download Falco binary
│   └── falco_drivers.sh       # Download Falco .ko/.o drivers
│
├── builder/
│   ├── build_base.sh          # Build base initramfs (Falco + busybox) — once per session
│   └── build_per_kernel.sh    # Inject drivers into base initramfs per kernel
│
├── kernels/                   # Downloaded vmlinuz files
│   └── centos-8-4.18.0-147/
│       └── vmlinuz
├── initramfs/                 # Per-kernel initramfs images
├── modules/                   # Falco drivers per kernel
│   └── centos-8-4.18.0-147/
│       ├── falco_probe.ko
│       └── falco_probe.o
└── results/                   # Per-kernel logs and results
    └── centos-8-4.18.0-147/
        ├── 00-vmlinuz.log     # vmlinuz download log
        ├── 01-uname.log       # uname -r discovery log
        ├── 02-drivers.log     # driver download log
        ├── 03-build.log       # initramfs build log
        ├── 04-boot.log        # full QEMU console output
        └── result.txt         # PASS/FAIL + reason
```

## kernels.list Format

```
# distro:release:kernel_version
centos:8:4.18.0-553.el8_10
centos:7:3.10.0-1160.108.1.el7
almalinux:9:5.14.0-503.el9_5
rocky:8:4.18.0-348.20.1.el8_5
ubuntu:mainline:5.15.45
debian:stable:5.10.209-2-amd64
```

`kernel_version` is the **exact** string from the RPM/deb filename. The per-distro downloader scripts use it to construct direct download URLs.

### Generating kernels.list

```bash
# All distros (slow — crawls all distro vaults)
./update_kernel_list.sh

# Specific distros only
./update_kernel_list.sh centos almalinux

# Preview without writing
./update_kernel_list.sh centos --dry-run
```

### Manual / Bulk Download

To pre-download all vmlinuz packages in bulk:

```bash
./downloader/crawl_all.sh                    # all distros
./downloader/crawl_all.sh centos             # centos only
./downloader/crawl_all.sh --dry-run          # preview URLs
```

Downloaded RPMs go to `vmlinuz-{distro}/` directories. `setup.sh` will extract vmlinuz from them automatically.

## Driver Server Configuration

Falco drivers (`.ko`/`.o`) are fetched from a configurable server. Edit `config/driver_server.yaml`:

```yaml
# Default: Falco's CloudFront distribution
base_url: https://d20hasrqv82i0q.cloudfront.net
driver_version: "9.1.0+driver"

# Switch to your own server:
# base_url: https://your-driver-server.example.com
# driver_version: "9.1.0+driver"
```

The URL layout mirrors Falco's CloudFront:
```
{base_url}/driver/{driver_version}/x86_64/falco_{distro}_{uname_r}_{rev}.ko
{base_url}/driver/{driver_version}/x86_64/falco_{distro}_{uname_r}_{rev}.o
```

You can also override via environment variable: `DRIVER_BASE_URL=https://... ./setup.sh`

## Logs and Debugging

Each kernel gets its own log directory in `results/<kernel_name>/`:

| File | Contents |
|------|----------|
| `00-vmlinuz.log` | vmlinuz download (URLs tried, curl output) |
| `01-uname.log` | uname -r discovery method and result |
| `02-drivers.log` | driver search and download output |
| `03-build.log` | initramfs build output |
| `04-boot.log` | full QEMU console (all serial output) |
| `result.txt` | final PASS/FAIL with reason |

**Finding failures:**
```bash
# See which kernels failed and why
grep -h "reason:" results/*/result.txt

# Check vmlinuz download failure
cat results/centos-8-4.18.0-147.8.1.el8_1/00-vmlinuz.log

# Check full QEMU output for a kernel panic
cat results/centos-8-4.18.0-147.8.1.el8_1/04-boot.log
```

## Supported Distributions

| Distro | Versions | Package | vmlinuz source |
|--------|----------|---------|----------------|
| CentOS | 6, 7, 8 | `kernel-{ver}.x86_64.rpm` / `kernel-core-*.rpm` | `vault.centos.org` |
| AlmaLinux | 8, 9 | `kernel-core-{ver}.x86_64.rpm` | `vault.almalinux.org` |
| Rocky | 8, 9 | `kernel-core-{ver}.x86_64.rpm` | `dl.rockylinux.org/vault/rocky` |
| Ubuntu | mainline | `linux-image-unsigned-*-generic_*.deb` | `kernel.ubuntu.com/mainline` |
| Debian | stable | `linux-image-*-amd64_*.deb` | `deb.debian.org` |

## Advanced Usage

### Test a Single Kernel
```bash
echo "centos:8:4.18.0-553.el8_10" > config/kernels.list
./setup.sh
```

### Filter by Distro or Kernel
```bash
DISTRO=centos ./run_tests.sh
KERNEL_FILTER=4.18.0 ./run_tests.sh
```

### Skip Driver Download
```bash
./setup.sh --skip-drivers    # useful when testing basic boot only
```

### Setup Without Running Tests
```bash
./setup.sh --setup-only
# ... later ...
./run_tests.sh
```

### Faster Repeated Runs
```bash
KERNEL_DELAY=0 ./run_tests.sh    # no inter-kernel delay
```

## Requirements

| Tool | Purpose |
|------|---------|
| `qemu-system-x86_64` | VM boot |
| `curl` | Downloads |
| `cpio`, `gzip` | initramfs packing |
| `busybox` | initramfs utilities |
| `rpm2cpio` | extracting vmlinuz from RPM |
| `ar` | extracting vmlinuz from .deb |
| `python3-yaml` | YAML config parsing in crawl.py |
| `strings` (binutils) | fast uname -r discovery (optional) |
| `/dev/kvm` | 2× faster boot (optional) |

## Test Output

The init script inside the VM emits structured `[TAG]` lines:

```
[BOOT] kernel=4.18.0-553.el8_10.x86_64 arch=x86_64    — kernel booted

[KO] falco_probe.ko PASS module=falco                   — .ko module loaded OK
[KO] falco_probe.ko FAIL Operation not permitted        — load failed

[BPF] falco_probe.o PASS                               — eBPF probe loaded OK
[BPF] falco_probe.o SKIP kernel<4.14                   — too old for eBPF

[FALCO_STEP] [FALCO_KO] starting falco                 — Falco startup progress
[FALCO_OUT]  Events detected: 3                        — Falco output
[FALCO_KO] PASS engine=kmod events=3                   — Falco test result
[FALCO_EBPF] SKIP no-probe                             — eBPF probe unavailable

RESULT: KO_PASS=1 KO_FAIL=0 BPF_PASS=0 BPF_FAIL=0 BPF_SKIP=0 FALCO_KO=PASS FALCO_EBPF=SKIP
ALL_DONE
```
