#!/bin/bash
# Download AlmaLinux kernel vmlinuz from repo.almalinux.org
#
# Accepts the EXACT kernel version string as found in the RPM filename.
# Use fetch_kernel_list.sh to populate config/kernels.list with valid names.
#
# Version format: 4.18.0-553.el8_10  or  5.14.0-503.el9_5
# el8_N → AlmaLinux 8.N   el9_N → AlmaLinux 9.N
set -uo pipefail

KERNEL_VER="${1:-}"
OUTPUT_DIR="${2:-}"

if [[ -z "$KERNEL_VER" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <kernel_version> <output_dir>"
    echo ""
    echo "Examples (use exact strings from vault RPM filenames):"
    echo "  $0 4.18.0-553.el8_10     ./kernels/almalinux-8-4.18.0-553.el8_10"
    echo "  $0 4.18.0-348.12.2.el8_5 ./kernels/almalinux-8-4.18.0-348.12.2.el8_5"
    echo "  $0 5.14.0-503.el9_5      ./kernels/almalinux-9-5.14.0-503.el9_5"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# ── Parse EL major and minor ──────────────────────────────────────────────────
EL_MAJOR=$(echo "$KERNEL_VER" | grep -oP '\.el\K\d+' | head -1)
EL_MINOR=$(echo "$KERNEL_VER" | grep -oP '\.el\d+_\K\d+' | head -1 || true)

if [[ -z "$EL_MAJOR" ]]; then
    echo "✗ Cannot parse EL version from: $KERNEL_VER"
    echo "  Expected: 4.18.0-553.el8_10 or 5.14.0-362.el9"
    exit 1
fi

if [[ -n "$EL_MINOR" ]]; then
    ALMA_VER="${EL_MAJOR}.${EL_MINOR}"
else
    # Latest known release as fallback
    case "$EL_MAJOR" in
        8) ALMA_VER="8.10" ;;
        9) ALMA_VER="9.5"  ;;
        *) ALMA_VER="$EL_MAJOR" ;;
    esac
fi

RPM_NAME="kernel-core-${KERNEL_VER}.x86_64.rpm"
echo "AlmaLinux ${ALMA_VER} — kernel: $KERNEL_VER"
echo "Searching for: $RPM_NAME"

# ── Build candidate URL list ──────────────────────────────────────────────────
# When el minor is known the vault path is deterministic → try vault first.
CANDIDATE_URLS=()

if [[ -n "$EL_MINOR" ]]; then
    CANDIDATE_URLS+=(
        "https://repo.almalinux.org/vault/${ALMA_VER}/BaseOS/x86_64/os/Packages/${RPM_NAME}"
        "https://repo.almalinux.org/almalinux/${ALMA_VER}/BaseOS/x86_64/os/Packages/${RPM_NAME}"
        "https://repo.almalinux.org/almalinux/${EL_MAJOR}/BaseOS/x86_64/os/Packages/${RPM_NAME}"
    )
else
    # No minor → might be current release in live repo
    CANDIDATE_URLS+=(
        "https://repo.almalinux.org/almalinux/${ALMA_VER}/BaseOS/x86_64/os/Packages/${RPM_NAME}"
        "https://repo.almalinux.org/almalinux/${EL_MAJOR}/BaseOS/x86_64/os/Packages/${RPM_NAME}"
        "https://repo.almalinux.org/vault/${ALMA_VER}/BaseOS/x86_64/os/Packages/${RPM_NAME}"
    )
fi

# Fallback: sweep all vault versions for this major (newest-first)
if [[ "$EL_MAJOR" == "8" ]]; then
    for v in 8.10 8.9 8.8 8.7 8.6 8.5 8.4; do
        CANDIDATE_URLS+=("https://repo.almalinux.org/vault/${v}/BaseOS/x86_64/os/Packages/${RPM_NAME}")
    done
elif [[ "$EL_MAJOR" == "9" ]]; then
    for v in 9.5 9.4 9.3 9.2 9.1 9.0; do
        CANDIDATE_URLS+=("https://repo.almalinux.org/vault/${v}/BaseOS/x86_64/os/Packages/${RPM_NAME}")
    done
fi

# ── Try each candidate ────────────────────────────────────────────────────────
DOWNLOAD_URL=""
for url in "${CANDIDATE_URLS[@]}"; do
    echo "  Checking: $url"
    if curl -sf --head --max-time 10 "$url" > /dev/null 2>&1; then
        DOWNLOAD_URL="$url"
        echo "  ✓ Found"
        break
    fi
done

if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "✗ Cannot find RPM for kernel $KERNEL_VER"
    echo ""
    echo "  Available AlmaLinux ${EL_MAJOR} kernels at vault/${ALMA_VER}:"
    curl -sf --max-time 15 \
        "https://repo.almalinux.org/vault/${ALMA_VER}/BaseOS/x86_64/os/Packages/" 2>/dev/null \
        | grep -oE 'kernel-core-[0-9][^"<]+\.x86_64\.rpm' | head -10 || true
    echo ""
    echo "  Tip: run ./fetch_kernel_list.sh --distro almalinux --dry-run to list valid names"
    exit 1
fi

# ── Download & extract ────────────────────────────────────────────────────────
echo "Downloading $(basename "$DOWNLOAD_URL") ..."
curl -L --progress-bar --max-time 300 --retry 3 \
     -o "$TEMP_DIR/kernel.rpm" "$DOWNLOAD_URL"

if [[ ! -s "$TEMP_DIR/kernel.rpm" ]]; then
    echo "✗ Download failed or file empty"
    exit 1
fi

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
