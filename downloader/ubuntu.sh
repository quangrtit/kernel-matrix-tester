#!/bin/bash
# Standalone: download Ubuntu kernel vmlinuz from archive.ubuntu.com
#
# NOTE: The main pipeline uses sync_kernels.sh + crawl.py instead.
# This script is a manual utility for downloading a single kernel.
#
# Usage: $0 <version> <output_dir>
# Example: $0 5.4.0-195-generic ./kernels/ubuntu-focal-5.4.0-195-generic
#
# kernels.list format: ubuntu:focal:5.4.0-195-generic
set -uo pipefail

VERSION="${1:-}"
OUTPUT_DIR="${2:-}"

if [[ -z "$VERSION" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <version> <output_dir>"
    echo ""
    echo "Examples:"
    echo "  $0 5.4.0-195-generic  ./kernels/ubuntu-focal-5.4.0-195-generic"
    echo "  $0 5.15.0-119-generic ./kernels/ubuntu-jammy-5.15.0-119-generic"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

BASE_URL="https://archive.ubuntu.com/ubuntu/pool/main/l/linux/"
echo "Fetching index from $BASE_URL"

INDEX=$(curl -sf --max-time 20 "$BASE_URL" 2>/dev/null || true)
if [[ -z "$INDEX" ]]; then
    echo "✗ Cannot reach $BASE_URL"
    exit 1
fi

# Match: linux-image-{VERSION}_..._amd64.deb or linux-image-unsigned-{VERSION}_..._amd64.deb
DEB=$(printf '%s\n' "$INDEX" \
    | grep -oE 'linux-image-(unsigned-)?'"${VERSION//./\\.}"'[^"]*_amd64\.deb' \
    | head -1)

if [[ -z "$DEB" ]]; then
    echo "✗ Cannot find linux-image deb for version $VERSION"
    echo "  Try: curl -s '$BASE_URL' | grep -o 'linux-image[^\"]*amd64.deb' | grep '$VERSION'"
    exit 1
fi

echo "Downloading $DEB ..."
curl -L --progress-bar --max-time 300 --retry 3 \
     -o "$TEMP_DIR/kernel.deb" "${BASE_URL}${DEB}"

if [[ ! -s "$TEMP_DIR/kernel.deb" ]]; then
    echo "✗ Download failed or file empty"
    exit 1
fi

cd "$TEMP_DIR"
ar x kernel.deb 2>/dev/null || { echo "✗ ar x failed"; exit 1; }

DATA_TAR=$(ls data.tar* 2>/dev/null | head -1)
[[ -z "$DATA_TAR" ]] && { echo "✗ data.tar not found in .deb"; exit 1; }

tar -xf "$DATA_TAR" --wildcards "*/boot/vmlinuz*" 2>/dev/null || true

VMLINUZ=$(find "$TEMP_DIR" -name "vmlinuz*" -type f 2>/dev/null | head -1)
[[ -z "$VMLINUZ" ]] && { echo "✗ vmlinuz not found inside .deb"; exit 1; }

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ vmlinuz → $OUTPUT_DIR/vmlinuz  ($(du -sh "$OUTPUT_DIR/vmlinuz" | cut -f1))"
