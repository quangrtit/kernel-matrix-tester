#!/bin/bash
# Download Rocky Linux kernel vmlinuz from Rocky vault repositories
set -e

KERNEL_VER=$1
OUTPUT_DIR=$2

if [[ -z "$KERNEL_VER" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <kernel_version> <output_dir>"
    echo "Example: $0 5.14.0-362 ./kernels/rocky-9-5.14.0-362"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

REPO_URL="https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/k/"
echo "Fetching index from $REPO_URL"

INDEX=$(wget -q --timeout=15 -O- "$REPO_URL" 2>/dev/null || true)
if [[ -z "$INDEX" ]]; then
    echo "✗ Cannot reach $REPO_URL"
    exit 1
fi

RPM_NAME=$(echo "$INDEX" | \
    grep -oP "kernel-core-${KERNEL_VER}\.x86_64\.rpm" | \
    head -1)
if [[ -z "$RPM_NAME" ]]; then
    echo "✗ Cannot find RPM for kernel $KERNEL_VER"
    echo "Available:"
    echo "$INDEX" | grep -oP 'kernel-[^"<]*\.rpm' | \
        grep -v "devel\|headers\|doc\|debuginfo" | head -20 || true
    exit 1
fi

echo "Downloading $RPM_NAME ..."
wget -q --show-progress "${REPO_URL}${RPM_NAME}" -O "$TEMP_DIR/kernel.rpm"

cd "$TEMP_DIR"
rpm2cpio kernel.rpm | cpio -idm --quiet 2>/dev/null || true

VMLINUZ=$(find "$TEMP_DIR" -name "vmlinuz*" -type f 2>/dev/null | head -1)
if [[ -z "$VMLINUZ" ]]; then
    echo "✗ vmlinuz not found inside RPM"
    exit 1
fi

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ Downloaded vmlinuz → $OUTPUT_DIR/vmlinuz"