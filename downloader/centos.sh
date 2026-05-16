#!/bin/bash
# Download CentOS/RHEL kernel vmlinuz from vault repositories
# Auto-detects EL version (el6/el7/el8) from kernel version
set -e

KERNEL_VER=$1
OUTPUT_DIR=$2

if [[ -z "$KERNEL_VER" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <kernel_version> <output_dir>"
    echo "Example: $0 3.10.0-1160 ./kernels/centos7-3.10.0"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Auto-detect CentOS/RHEL version and EL tag from kernel version
MAJOR=$(echo "$KERNEL_VER" | cut -d. -f1)
MINOR=$(echo "$KERNEL_VER" | cut -d. -f2)

if [[ "$MAJOR" -eq 2 ]]; then
    EL="el6"
    REPO_URL="http://vault.centos.org/centos/6/updates/x86_64/Packages/"
elif [[ "$MAJOR" -eq 3 ]] && [[ "$MINOR" -eq 10 ]]; then
    EL="el7"
    REPO_URL="http://vault.centos.org/centos/7/updates/x86_64/Packages/"
elif [[ "$MAJOR" -eq 4 ]] && [[ "$MINOR" -eq 18 ]]; then
    EL="el8"
    REPO_URL="http://vault.centos.org/centos/8/BaseOS/x86_64/os/Packages/"
else
    echo "✗ Cannot auto-detect CentOS version from kernel $KERNEL_VER"
    echo "Supported: 2.6.x (el6), 3.10.x (el7), 4.18.x (el8)"
    exit 1
fi

echo "Detected: $EL → $REPO_URL"
echo "Fetching index..."

INDEX=$(wget -q -O- "$REPO_URL" 2>/dev/null || true)
if [[ -z "$INDEX" ]]; then
    echo "✗ Cannot reach $REPO_URL"
    exit 1
fi

# Tìm RPM đúng tên, không lấy devel/headers/debuginfo
RPM_NAME=$(echo "$INDEX" | \
    grep -oP "kernel-${KERNEL_VER}\.[^\"<]*\.rpm" | \
    grep -v "devel\|headers\|doc\|debuginfo" | head -1)

if [[ -z "$RPM_NAME" ]]; then
    echo "✗ Cannot find RPM for kernel $KERNEL_VER"
    echo "Available kernel packages:"
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