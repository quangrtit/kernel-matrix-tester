#!/bin/bash
# Download CentOS/RHEL kernel vmlinuz from vault repositories
# Supports el6 (2.6.x), el7 (3.10.x), el8 (4.18.x)
# el8 vmlinuz lives in kernel-core, NOT kernel (meta-package)
set -uo pipefail

KERNEL_VER="${1:-}"
OUTPUT_DIR="${2:-}"

if [[ -z "$KERNEL_VER" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <kernel_version> <output_dir>"
    echo "Example: $0 3.10.0-1160 ./kernels/centos-7-3.10.0-1160"
    echo "Example: $0 4.18.0-348.el8 ./kernels/centos-8-4.18.0-348.el8"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# ── Detect EL version ─────────────────────────────────────────────────────────
MAJOR=$(echo "$KERNEL_VER" | cut -d. -f1)
MINOR=$(echo "$KERNEL_VER" | cut -d. -f2)

if echo "$KERNEL_VER" | grep -q '\.el8'; then
    EL="el8"
elif echo "$KERNEL_VER" | grep -q '\.el7'; then
    EL="el7"
elif echo "$KERNEL_VER" | grep -q '\.el6'; then
    EL="el6"
elif [[ "$MAJOR" -eq 4 ]] && [[ "$MINOR" -eq 18 ]]; then
    EL="el8"
elif [[ "$MAJOR" -eq 3 ]] && [[ "$MINOR" -eq 10 ]]; then
    EL="el7"
elif [[ "$MAJOR" -eq 2 ]]; then
    EL="el6"
else
    echo "✗ Cannot detect EL version from kernel $KERNEL_VER"
    exit 1# Falco 0.43.1 — driver 9.1.0+driver — kernels < 5.4 only
# Format: distro:version:kernel_version

# =========================
# CentOS 7 (3.10 series)
# kernel <4.14 => kmod only
# =========================

centos:7:3.10.0-957
centos:7:3.10.0-1062
centos:7:3.10.0-1127
centos:7:3.10.0-1160

# =========================
# CentOS 8 (4.18 series)
# eBPF + kmod
# =========================

centos:8:4.18.0-240.el8
centos:8:4.18.0-348.el8
centos:8:4.18.0-425.el8
centos:8:4.18.0-477.el8
centos:8:4.18.0-553.el8

# =========================
# AlmaLinux 8
# EL8 clone nhưng có khác build
# =========================

almalinux:8:4.18.0-348.el8
almalinux:8:4.18.0-425.el8
almalinux:8:4.18.0-513.el8
almalinux:8:4.18.0-553.el8_10

# =========================
# AlmaLinux 9
# kernel 5.14 -> vượt phạm vi
# chỉ thêm nếu muốn test tương thích
# =========================

# almalinux:9:5.14.0-70.el9
# almalinux:9:5.14.0-362.el9
fi

echo "CentOS $EL — kernel: $KERNEL_VER"

# ── Build RPM name and candidate URLs ─────────────────────────────────────────
DOWNLOAD_URL=""

case "$EL" in
    el7)
        # el7 packages don't include .el7 in the version string we get from kernels.list,
        # but the RPM on disk is named kernel-3.10.0-1160.el7.x86_64.rpm
        RPM_BASE="kernel-${KERNEL_VER}.el7.x86_64.rpm"
        echo "Searching for: $RPM_BASE"

        # Try direct URLs first (versioned vault — faster than index parsing)
        for ver in "7.9.2009" "7.8.2003" "7.7.1908" "7.6.1810"; do
            for repo in "updates" "os"; do
                direct="https://vault.centos.org/${ver}/${repo}/x86_64/Packages/${RPM_BASE}"
                echo "  Trying: $direct"
                if curl -sf --head --max-time 10 "$direct" > /dev/null 2>&1; then
                    DOWNLOAD_URL="$direct"
                    echo "  ✓ Found"
                    break 2
                fi
            done
        done

        # Fallback: index search on vault/centos symlinks
        if [[ -z "$DOWNLOAD_URL" ]]; then
            for base_url in \
                "http://vault.centos.org/centos/7/updates/x86_64/Packages/" \
                "http://vault.centos.org/centos/7/os/x86_64/Packages/"; do
                echo "  Searching index: $base_url"
                INDEX=$(curl -sf --max-time 30 "$base_url" 2>/dev/null) || INDEX=""
                [[ -z "$INDEX" ]] && continue
                MATCH=$(printf '%s' "$INDEX" \
                    | grep -oE "kernel-${KERNEL_VER//./\\.}[^\"< ]*\.x86_64\.rpm" \
                    | grep -v "devel\|headers\|doc\|debuginfo\|modules" \
                    | head -1 || true)
                if [[ -n "$MATCH" ]]; then
                    DOWNLOAD_URL="${base_url}${MATCH}"
                    echo "  ✓ Found: $MATCH"
                    break
                fi
            done
        fi
        ;;

    el8)
        # el8: vmlinuz is in kernel-core, not kernel
        RPM_BASE="kernel-core-${KERNEL_VER}.x86_64.rpm"
        echo "Searching for: $RPM_BASE"

        # Try specific versioned vault paths
        EL8_VERS=("8.5.2111" "8.4.2105" "8.3.2011" "8.6.0")
        for ver in "${EL8_VERS[@]}"; do
            direct="https://vault.centos.org/${ver}/BaseOS/x86_64/os/Packages/${RPM_BASE}"
            echo "  Trying: $direct"
            if curl -sf --head --max-time 10 "$direct" > /dev/null 2>&1; then
                DOWNLOAD_URL="$direct"
                echo "  ✓ Found"
                break
            fi
        done

        # Fallback: index search
        if [[ -z "$DOWNLOAD_URL" ]]; then
            for base_url in \
                "http://vault.centos.org/centos/8/BaseOS/x86_64/os/Packages/" \
                "https://vault.centos.org/8.5.2111/BaseOS/x86_64/os/Packages/" \
                "https://vault.centos.org/8.4.2105/BaseOS/x86_64/os/Packages/"; do
                echo "  Searching index: $base_url"
                INDEX=$(curl -sf --max-time 30 "$base_url" 2>/dev/null) || INDEX=""
                [[ -z "$INDEX" ]] && continue
                MATCH=$(printf '%s' "$INDEX" \
                    | grep -oE "kernel-core-${KERNEL_VER//./\\.}[^\"< ]*\.x86_64\.rpm" \
                    | grep -v "devel\|headers\|doc\|debuginfo" \
                    | head -1 || true)
                if [[ -n "$MATCH" ]]; then
                    DOWNLOAD_URL="${base_url}${MATCH}"
                    echo "  ✓ Found: $MATCH"
                    break
                fi
            done
        fi
        ;;

    el6)
        RPM_BASE="kernel-${KERNEL_VER}.el6.x86_64.rpm"
        echo "Searching for: $RPM_BASE"
        for base_url in \
            "http://vault.centos.org/centos/6/updates/x86_64/Packages/" \
            "http://vault.centos.org/centos/6/os/x86_64/Packages/"; do
            echo "  Searching index: $base_url"
            INDEX=$(curl -sf --max-time 30 "$base_url" 2>/dev/null) || INDEX=""
            [[ -z "$INDEX" ]] && continue
            MATCH=$(printf '%s' "$INDEX" \
                | grep -oE "kernel-${KERNEL_VER//./\\.}[^\"< ]*\.x86_64\.rpm" \
                | grep -v "devel\|headers\|doc\|debuginfo" \
                | head -1 || true)
            if [[ -n "$MATCH" ]]; then
                DOWNLOAD_URL="${base_url}${MATCH}"
                echo "  ✓ Found: $MATCH"
                break
            fi
        done
        ;;
esac

if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "✗ Cannot find RPM for kernel $KERNEL_VER ($EL)"
    echo "  The kernel version may not exist in CentOS vault, or the vault may be unreachable."
    exit 1
fi

# ── Download RPM ──────────────────────────────────────────────────────────────
echo "Downloading $(basename "$DOWNLOAD_URL") ..."
curl -L --progress-bar --max-time 300 --retry 3 \
     -o "$TEMP_DIR/kernel.rpm" "$DOWNLOAD_URL"

if [[ ! -s "$TEMP_DIR/kernel.rpm" ]]; then
    echo "✗ Download failed or file empty"
    exit 1
fi

# ── Extract vmlinuz ────────────────────────────────────────────────────────────
cd "$TEMP_DIR"
rpm2cpio kernel.rpm | cpio -id --quiet 2>/dev/null || true

VMLINUZ=$(find "$TEMP_DIR" -name "vmlinuz*" -type f 2>/dev/null \
          | grep -v "rescue\|debug" | head -1 || true)

if [[ -z "$VMLINUZ" ]]; then
    echo "✗ vmlinuz not found in RPM"
    find "$TEMP_DIR" -name "vmlinuz*" 2>/dev/null | head -5 || true
    exit 1
fi

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ vmlinuz → $OUTPUT_DIR/vmlinuz  ($(du -sh "$OUTPUT_DIR/vmlinuz" | cut -f1))"
