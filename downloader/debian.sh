#!/bin/bash
# Download Debian kernel vmlinuz from official Debian repositories
set -e

VERSION=$1
OUTPUT_DIR=$2

if [[ -z "$VERSION" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <version> <output_dir>"
    echo "Example: $0 5.10.0-30-amd64 ./kernels/debian11-5.10.0"
    echo "         $0 6.1.0-39-amd64  ./kernels/debian12-6.1.0"
    exit 1
fi

# Create output directory and temporary workspace
mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Fetch index from Debian package repository
DEBIAN_URL="http://deb.debian.org/debian/pool/main/l/linux/"
echo "Fetching index from $DEBIAN_URL"

INDEX=$(wget -q -O- "$DEBIAN_URL" 2>/dev/null || true)
if [[ -z "$INDEX" ]]; then
    echo "✗ Cannot reach $DEBIAN_URL"
    exit 1
fi

# Find linux-image package matching kernel version (unsigned or signed, excluding debug/cloud/rt variants)
DEB=$(echo "$INDEX" | \
    grep -oP "linux-image-${VERSION}(-unsigned)?_[^\"]+_amd64\.deb" | \
    grep -v "dbg\|cloud\|rt" | head -1)

if [[ -z "$DEB" ]]; then
    echo "✗ Cannot find package for $VERSION"
    echo "Available versions (pick one for kernels.list):"
    echo "$INDEX" | grep -oP 'linux-image-\d+\.\d+\.\d+-\d+-amd64[^"]*_amd64\.deb' | \
        grep -v "dbg\|cloud\|rt" | grep -oP 'linux-image-[^_]+' | \
        sort -u | head -20 || true
    exit 1
fi

echo "Downloading $DEB ..."
wget -q --show-progress "${DEBIAN_URL}${DEB}" -O "$TEMP_DIR/kernel.deb"

cd "$TEMP_DIR"
ar x kernel.deb
DATA_TAR=$(ls data.tar.* 2>/dev/null | head -1)
if [[ -z "$DATA_TAR" ]]; then
    echo "✗ Cannot find data.tar inside .deb"
    exit 1
fi

tar -xf "$DATA_TAR" --wildcards "*/boot/vmlinuz*" 2>/dev/null || true
VMLINUZ=$(find "$TEMP_DIR/boot" -name "vmlinuz*" -type f 2>/dev/null | head -1)
if [[ -z "$VMLINUZ" ]]; then
    echo "✗ vmlinuz not found inside .deb"
    exit 1
fi

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ Downloaded vmlinuz → $OUTPUT_DIR/vmlinuz"