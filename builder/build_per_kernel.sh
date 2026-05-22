#!/bin/bash
# Build per-kernel initramfs by:
# 1. Unpacking base initramfs
# 2. Injecting kernel-specific modules
# 3. Repacking into new initramfs
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BASE_IMG="$PROJECT_ROOT/initramfs-base.img"
KERNEL_NAME=$1

if [[ -z "$KERNEL_NAME" ]]; then
    echo "Usage: $0 <kernel_name>"
    echo "Example: $0 ubuntu-20.04-5.15.0"
    exit 1
fi

if [[ ! -f "$BASE_IMG" ]]; then
    echo "✗ Base initramfs not found: $BASE_IMG"
    echo "Run: ./builder/build_base.sh"
    exit 1
fi

# Fall back to a project-local tmpdir if /tmp is missing or not writable
if [[ ! -d /tmp ]] || [[ ! -w /tmp ]]; then
    export TMPDIR="$PROJECT_ROOT/.tmp"
    mkdir -p "$TMPDIR"
fi

DISTRO=$(cut -d- -f1 <<< "$KERNEL_NAME")
KVER=$(cut -d- -f3- <<< "$KERNEL_NAME")
KO_FILE="$PROJECT_ROOT/modules/falco_${DISTRO}_${KVER}_x86_64.ko"
O_FILE="$PROJECT_ROOT/modules/falco_${DISTRO}_${KVER}_x86_64.o"
OUTPUT_IMG="$PROJECT_ROOT/initramfs/${KERNEL_NAME}.img"
mkdir -p "$(dirname "$OUTPUT_IMG")"

echo "Building per-kernel initramfs for $KERNEL_NAME..."

# Create temporary working directory
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# Unpack base initramfs (gzip compressed)
mkdir -p "$WORK_DIR/rootfs"
cd "$WORK_DIR/rootfs"
if ! zcat "$BASE_IMG" | cpio -id --quiet 2>&1; then
    echo "✗ Failed to unpack base initramfs: $BASE_IMG"
    exit 1
fi
if [[ ! -x "$WORK_DIR/rootfs/init" ]]; then
    echo "✗ Base initramfs is corrupt or incomplete — /init missing after extraction"
    echo "  Run: ./builder/build_base.sh"
    exit 1
fi

# Inject kernel-specific modules if available
mkdir -p lib/modules
injected=0
for module_file in "$KO_FILE" "$O_FILE"; do
    if [[ -f "$module_file" ]]; then
        cp "$module_file" lib/modules/
        echo "  Added: $(basename "$module_file")"
        injected=1
    fi
done
[[ $injected -eq 0 ]] && echo "WARN: No modules found for $KERNEL_NAME — boot test only"

# Repack into new initramfs (must cd into rootfs for relative paths)
cd "$WORK_DIR/rootfs"
find . | cpio -o -H newc | gzip -1 > "$OUTPUT_IMG"

echo "✓ Per-kernel initramfs: $OUTPUT_IMG"
ls -lh "$OUTPUT_IMG"