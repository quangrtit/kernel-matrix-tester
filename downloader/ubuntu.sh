#!/bin/bash
# Download Ubuntu kernel vmlinuz from mainline PPA
set -e

VERSION=$1
OUTPUT_DIR=$2

if [[ -z "$VERSION" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <version> <output_dir>"
    echo "Example: $0 5.15.45 ./kernels/ubuntu-20.04-5.15.45"
    exit 1
fi

# Create output directory and temporary workspace
mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Fetch index from Ubuntu mainline PPA
UBUNTU_URL="https://kernel.ubuntu.com/mainline/v${VERSION}/"
echo "Fetching index from $UBUNTU_URL"

INDEX=$(wget -q --timeout=15 -O- "$UBUNTU_URL" 2>/dev/null || true)
if [[ -z "$INDEX" ]]; then
    echo "✗ Cannot reach $UBUNTU_URL"
    echo "Available 5.15.x versions:"
    curl -sL "https://kernel.ubuntu.com/mainline/" | \
        grep -oP "v${VERSION%%.*}\.[^\"/<]+" | sort -V | tail -20 || true
    exit 1
fi

# Find unsigned linux-image deb for generic kernel (amd64 architecture)
# Ubuntu mainline PPA stores files in amd64/ subdirectory
DEB=$(echo "$INDEX" | grep -oP '(?:amd64/)?linux-image-unsigned[^"]*generic[^"]*amd64\.deb' | grep -v "dbg\|lowlatency" | head -1)
if [[ -z "$DEB" ]]; then
    DEB=$(echo "$INDEX" | grep -oP '(?:amd64/)?linux-image-[^"]*generic[^"]*amd64\.deb' | grep -v "dbg\|lowlatency" | head -1)
fi
if [[ -z "$DEB" ]]; then
    echo "✗ Cannot find .deb for version $VERSION"
    echo "Available files:"
    echo "$INDEX" | grep -oP '[a-zA-Z0-9._/-]*linux-image[^"]*\.deb' | head -20 || true
    exit 1
fi

# Prepend amd64/ path if not already present
[[ "$DEB" != amd64/* ]] && DEB="amd64/$DEB"

echo "Downloading $DEB ..."
echo "(This may take 1-2 minutes...)"

# Download using curl (more reliable) or wget as fallback
if command -v curl &>/dev/null; then
    curl -L --max-time 300 --retry 3 -o "$TEMP_DIR/kernel.deb" "${UBUNTU_URL}${DEB}" 2>&1 | tail -5
elif command -v wget &>/dev/null; then
    wget --timeout=300 --tries=3 -O "$TEMP_DIR/kernel.deb" "${UBUNTU_URL}${DEB}" 2>&1 | tail -5
else
    echo "✗ Neither curl nor wget found"
    exit 1
fi

# Verify download succeeded
if [[ ! -s "$TEMP_DIR/kernel.deb" ]]; then
    echo "✗ Download failed or file empty"
    echo "URL: ${UBUNTU_URL}${DEB}"
    exit 1
fi

# Extract vmlinuz from deb package
cd "$TEMP_DIR"
if ! ar x kernel.deb 2>/dev/null; then
    echo "✗ Failed to extract .deb (ar command failed)"
    exit 1
fi

# Find and extract data.tar (may be .gz or .xz compressed)
DATA_TAR=$(ls data.tar* 2>/dev/null | head -1)
if [[ -z "$DATA_TAR" ]]; then
    echo "✗ Cannot find data.tar inside .deb"
    ls -la "$TEMP_DIR" 2>/dev/null | head -10
    exit 1
fi

# Extract vmlinuz from data tarball
if ! tar -xf "$DATA_TAR" --wildcards "*/boot/vmlinuz*" 2>/dev/null; then
    echo "⚠ tar extract failed, trying alternative method..."
    tar -tf "$DATA_TAR" | grep "boot/vmlinuz" | head -1 | xargs -I {} tar -xf "$DATA_TAR" {} 2>/dev/null || true
fi

# Find extracted vmlinuz and copy to output directory
VMLINUZ=$(find "$TEMP_DIR" -name "vmlinuz*" -type f 2>/dev/null | head -1)
if [[ -z "$VMLINUZ" ]]; then
    echo "✗ vmlinuz not found inside .deb"
    exit 1
fi

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ Downloaded vmlinuz → $OUTPUT_DIR/vmlinuz"
VMLINUZ=$(find "$TEMP_DIR" -name "vmlinuz*" -type f 2>/dev/null | head -1)
if [[ -z "$VMLINUZ" ]]; then
    echo "✗ vmlinuz not found inside .deb"
    exit 1
fi

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ Downloaded vmlinuz → $OUTPUT_DIR/vmlinuz"