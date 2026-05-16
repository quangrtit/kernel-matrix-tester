#!/bin/bash
# Build minimal base initramfs with busybox and init script
# This is a one-time build - base image is reused for all kernels
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BASE_IMG="$PROJECT_ROOT/initramfs-base.img"

echo "Building minimal base initramfs..."

# Create temporary working directory
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

ROOTFS="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS"

# Create directory structure for initramfs
mkdir -p "$ROOTFS"/{bin,lib,lib64,proc,sys,dev,tmp,lib/modules}

# Copy busybox binary
if ! command -v busybox &>/dev/null; then
    echo "✗ busybox not found. Install: apt-get install busybox-static"
    exit 1
fi
cp "$(which busybox)" "$ROOTFS/bin/busybox"
chmod +x "$ROOTFS/bin/busybox"

# Create symlinks for commonly used busybox commands
for cmd in sh ash mount umount insmod rmmod lsmod ls cat echo \
           grep sleep poweroff mkdir rm chmod kill dmesg find \
           uname mdev; do
    ln -sf busybox "$ROOTFS/bin/$cmd"
done

# Create init script using /bin/sh (ash) - not bash for minimal footprint
cat > "$ROOTFS/init" << 'EOF'
#!/bin/sh

# Mount essential filesystems
mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /tmp

KERNEL_VERSION=$(uname -r)
ARCH=$(uname -m)
HOSTNAME=$(uname -n)

echo "=========================================="
echo "Boot successful!"
echo "=========================================="
echo "Hostname:       $HOSTNAME"
echo "Arch:           $ARCH"
echo "Kernel Version: $KERNEL_VERSION"
echo "=========================================="

# Test .ko kernel modules if present
for ko in /lib/modules/*.ko; do
    [ -f "$ko" ] || continue
    name=$(basename "$ko")
    insmod "$ko" 2>/tmp/err
    if [ $? -eq 0 ]; then
        echo "PASS .ko: $name"
        rmmod "${name%.ko}" 2>/dev/null || true
    else
        echo "FAIL .ko: $name -> $(cat /tmp/err)"
    fi
done

# Test .o eBPF probes if present (requires kernel >= 4.14)
KMAJ=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KMIN=$(echo "$KERNEL_VERSION" | cut -d. -f2)
for bpf in /lib/modules/*.o; do
    [ -f "$bpf" ] || continue
    name=$(basename "$bpf")
    if [ "$KMAJ" -lt 4 ] || { [ "$KMAJ" -eq 4 ] && [ "$KMIN" -lt 14 ]; }; then
        echo "SKIP .o: $name (kernel $KERNEL_VERSION < 4.14)"
    else
        echo "TODO .o: $name (bpftool not included in base)"
    fi
done

echo "=========================================="
echo "ALL_DONE"
echo "=========================================="

sleep 5 

# Shutdown cleanly
poweroff -f
EOF

chmod +x "$ROOTFS/init"

# Pack rootfs into cpio archive (gzip compressed)
# Must cd into rootfs so paths are ./init, ./bin/... (not rootfs/init)
cd "$ROOTFS"
find . | cpio -o -H newc | gzip -1 > "$BASE_IMG"

echo "✓ Base initramfs created: $BASE_IMG"
ls -lh "$BASE_IMG"

