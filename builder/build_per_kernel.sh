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

MODULES_DIR="$PROJECT_ROOT/modules/$KERNEL_NAME"
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
if [[ -d "$MODULES_DIR" ]]; then
    echo "Injecting modules from $MODULES_DIR..."
    for module in "$MODULES_DIR"/*.ko "$MODULES_DIR"/*.o; do
        if [[ -f "$module" ]]; then
            cp "$module" lib/modules/
            echo "  Added: $(basename "$module")"
        fi
    done
else
    echo "WARN: No modules dir found at $MODULES_DIR — boot test only"
fi

# Repack into new initramfs (must cd into rootfs for relative paths)
cd "$WORK_DIR/rootfs"
find . | cpio -o -H newc | gzip -1 > "$OUTPUT_IMG"

echo "✓ Per-kernel initramfs: $OUTPUT_IMG"
ls -lh "$OUTPUT_IMG"