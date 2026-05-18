#!/bin/bash
# Download AlmaLinux kernel vmlinuz from AlmaLinux vault or mirror
# Handles el8_x and el9_x versions
set -euo pipefail

KERNEL_VER="${1:-}"
OUTPUT_DIR="${2:-}"

if [[ -z "$KERNEL_VER" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <kernel_version> <output_dir>"
    echo "Example: $0 4.18.0-553.el8_10 ./kernels/almalinux-8-4.18.0-553.el8_10"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# ── Parse AlmaLinux release from kernel version string ────────────────────────
# e.g. "4.18.0-553.el8_10" → EL_MAJOR=8, EL_MINOR=10, ALMA_VER=8.10
EL_MAJOR=$(echo "$KERNEL_VER" | grep -oP '\.el\K\d+' | head -1)
EL_MINOR=$(echo "$KERNEL_VER" | grep -oP '\.el\d+_\K\d+' | head -1)

if [[ -z "$EL_MAJOR" ]]; then
    echo "✗ Cannot parse AlmaLinux version from kernel: $KERNEL_VER"
    echo "  Expected format: 4.18.0-553.el8_10 or 5.14.0-362.el9"
    exit 1
fi

if [[ -n "$EL_MINOR" ]]; then
    ALMA_VER="${EL_MAJOR}.${EL_MINOR}"
else
    # Fallback: use major.latest for el8 or el9
    case "$EL_MAJOR" in
        8) ALMA_VER="8.10" ;;
        9) ALMA_VER="9.5"  ;;
        *) ALMA_VER="$EL_MAJOR" ;;
    esac
fi

# AlmaLinux 8+ splits the kernel: vmlinuz is in kernel-core, not kernel
RPM_NAME="kernel-core-${KERNEL_VER}.x86_64.rpm"

echo "AlmaLinux $ALMA_VER — kernel: $KERNEL_VER"
echo "Searching for: $RPM_NAME"

# ── Try known repo URLs in priority order ─────────────────────────────────────
# 1. vault (archived stable releases)
# 2. Current repo (active maintenance updates)
# 3. kistrepo (Koji/SIG repos for very recent builds)
REPO_URLS=(
    "https://repo.almalinux.org/almalinux/${ALMA_VER}/BaseOS/x86_64/os/Packages/"
    "https://repo.almalinux.org/almalinux/${EL_MAJOR}/BaseOS/x86_64/os/Packages/"
    "https://repo.almalinux.org/vault/${ALMA_VER}/BaseOS/x86_64/os/Packages/"
)

DOWNLOAD_URL=""
for repo_url in "${REPO_URLS[@]}"; do
    candidate="${repo_url}${RPM_NAME}"
    echo "  Checking: $candidate"
    if curl -sf --head --max-time 10 "$candidate" > /dev/null 2>&1; then
        DOWNLOAD_URL="$candidate"
        echo "  ✓ Found at: $repo_url"
        break
    fi
done

if [[ -z "$DOWNLOAD_URL" ]]; then
    # Fall back to index search on vault
    echo "  Direct URL not found — searching vault index..."
    for base_url in \
        "https://repo.almalinux.org/almalinux/${ALMA_VER}/BaseOS/x86_64/os/Packages/" \
        "https://repo.almalinux.org/almalinux/${EL_MAJOR}/BaseOS/x86_64/os/Packages/" \
        "https://repo.almalinux.org/vault/${ALMA_VER}/BaseOS/x86_64/os/Packages/"; do
        INDEX=$(curl -sf --max-time 20 "$base_url" 2>/dev/null || true)
        MATCH=$(echo "$INDEX" | grep -oP "kernel-core-${KERNEL_VER//./\\.}[^\"<]*\.rpm" \
                | grep -v "devel\|headers\|doc\|debuginfo\|modules\b" | head -1)
        if [[ -n "$MATCH" ]]; then
            DOWNLOAD_URL="${base_url}${MATCH}"
            echo "  ✓ Found via index: $MATCH"
            break
        fi
    done
fi

if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "✗ Cannot find RPM for kernel $KERNEL_VER in AlmaLinux repositories"
    echo ""
    echo "  Checked:"
    for u in "${REPO_URLS[@]}"; do echo "    $u"; done
    echo ""
    echo "  Available AlmaLinux kernels at vault:"
    curl -sf --max-time 15 "https://repo.almalinux.org/almalinux/${ALMA_VER}/BaseOS/x86_64/os/Packages/" 2>/dev/null \
        | grep -oP 'kernel-core-[0-9][^"<]*\.x86_64\.rpm' | head -10 || true
    exit 1
fi

# ── Download RPM ──────────────────────────────────────────────────────────────
echo "Downloading $(basename "$DOWNLOAD_URL") ..."
echo "(This may take 1-2 minutes...)"

if command -v curl &>/dev/null; then
    curl -L --progress-bar --max-time 300 --retry 3 \
         -o "$TEMP_DIR/kernel.rpm" "$DOWNLOAD_URL"
elif command -v wget &>/dev/null; then
    wget --timeout=300 --tries=3 -O "$TEMP_DIR/kernel.rpm" "$DOWNLOAD_URL"
else
    echo "✗ Neither curl nor wget found"
    exit 1
fi

if [[ ! -s "$TEMP_DIR/kernel.rpm" ]]; then
    echo "✗ Download failed or file empty"
    exit 1
fi

# ── Extract vmlinuz from RPM ──────────────────────────────────────────────────
cd "$TEMP_DIR"
if ! rpm2cpio kernel.rpm | cpio -id --quiet 2>/dev/null; then
    echo "⚠ cpio extraction had warnings (usually OK)"
fi

VMLINUZ=$(find "$TEMP_DIR" -name "vmlinuz*" -type f 2>/dev/null \
          | grep -v "rescue\|debug" | head -1)

if [[ -z "$VMLINUZ" ]]; then
    echo "✗ vmlinuz not found in RPM"
    find "$TEMP_DIR" -name "vmlinuz*" | head -5 || true
    exit 1
fi

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ Downloaded vmlinuz → $OUTPUT_DIR/vmlinuz  ($(du -sh "$OUTPUT_DIR/vmlinuz" | cut -f1))"
