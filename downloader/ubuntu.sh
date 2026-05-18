#!/bin/bash
# Download Ubuntu mainline kernel vmlinuz from kernel.ubuntu.com/mainline
#
# Accepts kernel version as listed by fetch_kernel_list.sh (e.g. 5.15.45).
# kernels.list format: ubuntu:mainline:5.15.45
# Fetches: kernel.ubuntu.com/mainline/v<VERSION>/amd64/linux-image-*-generic*.deb
set -uo pipefail

VERSION="${1:-}"
OUTPUT_DIR="${2:-}"

if [[ -z "$VERSION" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <version> <output_dir>"
    echo ""
    echo "Examples:"
    echo "  $0 5.15.45  ./kernels/ubuntu-mainline-5.15.45"
    echo "  $0 4.19.316 ./kernels/ubuntu-mainline-4.19.316"
    echo ""
    echo "  Run ./fetch_kernel_list.sh --distro ubuntu --dry-run to list available versions."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

UBUNTU_URL="https://kernel.ubuntu.com/mainline/v${VERSION}/"
echo "Fetching index from $UBUNTU_URL"

INDEX=$(curl -sf --max-time 20 "$UBUNTU_URL" 2>/dev/null || true)
if [[ -z "$INDEX" ]]; then
    echo "✗ Cannot reach $UBUNTU_URL"
    echo ""
    echo "  Available nearby versions:"
    curl -sf --max-time 15 "https://kernel.ubuntu.com/mainline/" 2>/dev/null \
        | grep -oE '"v[0-9]+\.[0-9]+\.[0-9]+/"' | tr -d '"' | sed 's|^v||; s|/$||' \
        | grep "^${VERSION%%.*}\." | sort -V | tail -10 || true
    exit 1
fi

# Find linux-image deb for generic amd64 (unsigned preferred, then signed)
DEB=$(printf '%s\n' "$INDEX" \
    | grep -oE '(amd64/)?linux-image-unsigned[^"]*generic[^"]*amd64\.deb' \
    | grep -v "dbg\|lowlatency" | head -1)

[[ -z "$DEB" ]] && DEB=$(printf '%s\n' "$INDEX" \
    | grep -oE '(amd64/)?linux-image-[^"]*generic[^"]*amd64\.deb' \
    | grep -v "dbg\|lowlatency" | head -1)

if [[ -z "$DEB" ]]; then
    echo "✗ Cannot find linux-image deb for version $VERSION"
    echo "  Available files:"
    printf '%s\n' "$INDEX" | grep -oE '[a-zA-Z0-9._/-]*linux-image[^"]*\.deb' | head -20 || true
    exit 1
fi

# Ensure amd64/ prefix
[[ "$DEB" != amd64/* ]] && DEB="amd64/$DEB"

echo "Downloading $DEB ..."
if command -v curl &>/dev/null; then
    curl -L --progress-bar --max-time 300 --retry 3 \
         -o "$TEMP_DIR/kernel.deb" "${UBUNTU_URL}${DEB}"
else
    wget --timeout=300 --tries=3 -O "$TEMP_DIR/kernel.deb" "${UBUNTU_URL}${DEB}"
fi

if [[ ! -s "$TEMP_DIR/kernel.deb" ]]; then
    echo "✗ Download failed or file empty"
    echo "  URL: ${UBUNTU_URL}${DEB}"
    exit 1
fi

# Extract vmlinuz from .deb
cd "$TEMP_DIR"
if ! ar x kernel.deb 2>/dev/null; then
    echo "✗ Failed to extract .deb (ar command failed)"
    exit 1
fi

DATA_TAR=$(ls data.tar* 2>/dev/null | head -1)
if [[ -z "$DATA_TAR" ]]; then
    echo "✗ Cannot find data.tar inside .deb"
    ls -la "$TEMP_DIR" | head -10
    exit 1
fi

if ! tar -xf "$DATA_TAR" --wildcards "*/boot/vmlinuz*" 2>/dev/null; then
    # Some older debs have a different layout
    tar -tf "$DATA_TAR" | grep "boot/vmlinuz" | head -1 \
        | xargs -I {} tar -xf "$DATA_TAR" {} 2>/dev/null || true
fi

VMLINUZ=$(find "$TEMP_DIR" -name "vmlinuz*" -type f 2>/dev/null | head -1)
if [[ -z "$VMLINUZ" ]]; then
    echo "✗ vmlinuz not found inside .deb"
    exit 1
fi

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ vmlinuz → $OUTPUT_DIR/vmlinuz  ($(du -sh "$OUTPUT_DIR/vmlinuz" | cut -f1))"
