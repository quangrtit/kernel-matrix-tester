#!/bin/bash
# Download Rocky Linux kernel vmlinuz from dl.rockylinux.org
#
# Accepts the EXACT kernel version string as found in the RPM filename.
# Use fetch_kernel_list.sh to populate config/kernels.list with valid names.
#
# Supports Rocky 8 (el8_N) and Rocky 9 (el9_N).
# Version format: 4.18.0-348.20.1.el8_5  or  5.14.0-362.8.1.el9_3
set -uo pipefail

KERNEL_VER="${1:-}"
OUTPUT_DIR="${2:-}"

if [[ -z "$KERNEL_VER" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <kernel_version> <output_dir>"
    echo ""
    echo "Examples (use exact strings from vault RPM filenames):"
    echo "  $0 4.18.0-348.20.1.el8_5  ./kernels/rocky-8-4.18.0-348.20.1.el8_5"
    echo "  $0 5.14.0-362.8.1.el9_3   ./kernels/rocky-9-5.14.0-362.8.1.el9_3"
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
    exit 1
fi

ROCKY_MAJOR="$EL_MAJOR"
ROCKY_VER="${ROCKY_MAJOR}${EL_MINOR:+.${EL_MINOR}}"

RPM_NAME="kernel-core-${KERNEL_VER}.x86_64.rpm"
echo "Rocky ${ROCKY_MAJOR}${EL_MINOR:+ (${ROCKY_VER})} — kernel: $KERNEL_VER"
echo "Searching for: $RPM_NAME"

# ── Build candidate URL list ──────────────────────────────────────────────────
# Rocky vault path: dl.rockylinux.org/vault/rocky/{ROCKY_VER}/BaseOS/x86_64/os/Packages/k/
# Rocky pub path:   dl.rockylinux.org/pub/rocky/{ROCKY_MAJOR}/BaseOS/x86_64/os/Packages/k/
CANDIDATE_URLS=()

# Vault (deterministic when minor is known)
if [[ -n "$EL_MINOR" ]]; then
    CANDIDATE_URLS+=(
        "https://dl.rockylinux.org/vault/rocky/${ROCKY_VER}/BaseOS/x86_64/os/Packages/k/${RPM_NAME}"
        "https://dl.rockylinux.org/vault/rocky/${ROCKY_VER}/BaseOS/x86_64/os/Packages/${RPM_NAME}"
    )
fi

# Current pub repo (may have latest kernel for this major)
CANDIDATE_URLS+=(
    "https://dl.rockylinux.org/pub/rocky/${ROCKY_MAJOR}/BaseOS/x86_64/os/Packages/k/${RPM_NAME}"
    "https://dl.rockylinux.org/pub/rocky/${ROCKY_MAJOR}/BaseOS/x86_64/os/Packages/${RPM_NAME}"
)

# Fallback: sweep all vault minor releases (newest-first)
if [[ "$ROCKY_MAJOR" == "8" ]]; then
    for v in 8.10 8.9 8.8 8.7 8.6 8.5 8.4 8.3; do
        CANDIDATE_URLS+=(
            "https://dl.rockylinux.org/vault/rocky/${v}/BaseOS/x86_64/os/Packages/k/${RPM_NAME}"
        )
    done
elif [[ "$ROCKY_MAJOR" == "9" ]]; then
    for v in 9.5 9.4 9.3 9.2 9.1 9.0; do
        CANDIDATE_URLS+=(
            "https://dl.rockylinux.org/vault/rocky/${v}/BaseOS/x86_64/os/Packages/k/${RPM_NAME}"
        )
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
    echo "✗ Cannot find RPM for kernel $KERNEL_VER in Rocky ${ROCKY_MAJOR} repositories"
    echo ""
    echo "  Available Rocky ${ROCKY_MAJOR} kernels (pub):"
    curl -sf --max-time 15 \
        "https://dl.rockylinux.org/pub/rocky/${ROCKY_MAJOR}/BaseOS/x86_64/os/Packages/k/" \
        2>/dev/null | grep -oE 'kernel-core-[0-9][^"<]+\.x86_64\.rpm' | head -10 || true
    echo ""
    echo "  Tip: run ./fetch_kernel_list.sh --distro rocky --dry-run to list valid names"
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
rpm2cpio kernel.rpm | cpio -idm --quiet 2>/dev/null || true

VMLINUZ=$(find "$TEMP_DIR" -name "vmlinuz*" -type f 2>/dev/null \
          | grep -v "rescue\|debug" | head -1 || true)

if [[ -z "$VMLINUZ" ]]; then
    echo "✗ vmlinuz not found inside RPM"
    find "$TEMP_DIR" -name "vmlinuz*" 2>/dev/null | head -5 || true
    exit 1
fi

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ vmlinuz → $OUTPUT_DIR/vmlinuz  ($(du -sh "$OUTPUT_DIR/vmlinuz" | cut -f1))"
