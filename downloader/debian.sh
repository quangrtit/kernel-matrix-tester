#!/bin/bash
# Download Debian kernel vmlinuz from deb.debian.org
#
# Accepts kernel version as listed by fetch_kernel_list.sh.
# kernels.list format: debian:stable:5.10.0-30-amd64
# Fetches: deb.debian.org/debian/pool/main/l/linux/linux-image-<version>_*_amd64.deb
set -uo pipefail

VERSION="${1:-}"
OUTPUT_DIR="${2:-}"

if [[ -z "$VERSION" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <version> <output_dir>"
    echo ""
    echo "Examples:"
    echo "  $0 5.10.0-30-amd64  ./kernels/debian-stable-5.10.0-30"
    echo "  $0 6.1.0-39-amd64   ./kernels/debian-stable-6.1.0-39"
    echo ""
    echo "  Run ./fetch_kernel_list.sh --distro debian --dry-run to list available versions."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

DEBIAN_URL="http://deb.debian.org/debian/pool/main/l/linux/"
echo "Fetching index from $DEBIAN_URL"

INDEX=$(curl -sf --max-time 30 "$DEBIAN_URL" 2>/dev/null || true)
if [[ -z "$INDEX" ]]; then
    echo "✗ Cannot reach $DEBIAN_URL"
    exit 1
fi

# Match: linux-image-<version>_<pkgver>_amd64.deb  or  linux-image-<version>-unsigned_..._amd64.deb
DEB=$(printf '%s\n' "$INDEX" \
    | grep -oE "linux-image-${VERSION}(-unsigned)?_[^\"]+_amd64\.deb" \
    | grep -v "dbg\|cloud\|rt" | head -1)

if [[ -z "$DEB" ]]; then
    echo "✗ Cannot find package for $VERSION"
    echo ""
    echo "  Available amd64 kernel versions:"
    printf '%s\n' "$INDEX" \
        | grep -oE 'linux-image-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-amd64[^"]*_amd64\.deb' \
        | grep -v "dbg\|cloud\|rt" \
        | grep -oE 'linux-image-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-amd64' \
        | sed 's/linux-image-//' | sort -uV | tail -20 || true
    exit 1
fi

echo "Downloading $DEB ..."
if command -v curl &>/dev/null; then
    curl -L --progress-bar --max-time 300 --retry 3 \
         -o "$TEMP_DIR/kernel.deb" "${DEBIAN_URL}${DEB}"
else
    wget --timeout=300 --tries=3 -O "$TEMP_DIR/kernel.deb" "${DEBIAN_URL}${DEB}"
fi

if [[ ! -s "$TEMP_DIR/kernel.deb" ]]; then
    echo "✗ Download failed or file empty"
    exit 1
fi

cd "$TEMP_DIR"
ar x kernel.deb 2>/dev/null || { echo "✗ ar extract failed"; exit 1; }

DATA_TAR=$(ls data.tar.* 2>/dev/null | head -1)
if [[ -z "$DATA_TAR" ]]; then
    echo "✗ Cannot find data.tar inside .deb"
    exit 1
fi

tar -xf "$DATA_TAR" --wildcards "*/boot/vmlinuz*" 2>/dev/null || true

VMLINUZ=$(find "$TEMP_DIR/boot" -name "vmlinuz*" -type f 2>/dev/null | head -1)
[[ -z "$VMLINUZ" ]] && VMLINUZ=$(find "$TEMP_DIR" -name "vmlinuz*" -type f 2>/dev/null | head -1)

if [[ -z "$VMLINUZ" ]]; then
    echo "✗ vmlinuz not found inside .deb"
    exit 1
fi

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ vmlinuz → $OUTPUT_DIR/vmlinuz  ($(du -sh "$OUTPUT_DIR/vmlinuz" | cut -f1))"
