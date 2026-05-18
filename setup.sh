#!/bin/bash
# Falco Kernel Test — Full Setup + Test Runner
#
# Workflow:
#   1. Download Falco binary (if not present)
#   2. Build base initramfs (with Falco)
#   3. For each kernel in kernels.list:
#        a. Download vmlinuz
#        b. Discover uname -r (from log, vmlinuz strings, or discovery boot)
#        c. Download Falco .ko/.o drivers
#        d. Build per-kernel initramfs (with drivers)
#   4. Run full test suite

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADER_DIR="$PROJECT_ROOT/downloader"
BUILDER_DIR="$PROJECT_ROOT/builder"
CONFIG_DIR="$PROJECT_ROOT/config"
KERNELS_LIST="$CONFIG_DIR/kernels.list"
RESULTS_DIR="$PROJECT_ROOT/results"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
skip() { echo -e "  ${YELLOW}~${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }

banner() {
    echo ""
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $*${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════${NC}"
}

phase() {
    echo ""
    echo -e "${BOLD}  ──── $* ────${NC}"
}

# ── Prerequisite check ────────────────────────────────────────────────────────
check_prerequisites() {
    banner "Prerequisites"
    local missing=0
    for cmd in qemu-system-x86_64 curl wget cpio gzip busybox; do
        command -v "$cmd" &>/dev/null && ok "$cmd" || { fail "$cmd not found"; missing=1; }
    done
    [[ -e /dev/kvm ]] && ok "KVM available" || skip "KVM not available (will run slow)"
    [[ $missing -eq 1 ]] && { echo ""; fail "Install missing packages and retry"; exit 1; }

    # Check write permission on key directories (may be owned by root from a prior sudo run)
    local perm_issue=0
    for dir in "$PROJECT_ROOT/kernels" "$PROJECT_ROOT/initramfs"; do
        if [[ -d "$dir" ]] && [[ ! -w "$dir" ]]; then
            fail "No write permission: $dir  (owned by $(stat -c %U "$dir"))"
            perm_issue=1
        fi
    done
    # Check that vmlinuz files are readable (not mode 600 owned by root)
    while IFS=: read -r distro version kver; do
        [[ "$distro" =~ ^# ]] && continue
        [[ -z "$distro" ]]    && continue
        local vmlinuz="$PROJECT_ROOT/kernels/${distro}-${version}-${kver}/vmlinuz"
        if [[ -f "$vmlinuz" ]] && [[ ! -r "$vmlinuz" ]]; then
            fail "vmlinuz not readable: $vmlinuz"
            perm_issue=1
        fi
    done < "$KERNELS_LIST"
    if [[ $perm_issue -eq 1 ]]; then
        echo ""
        echo -e "  ${YELLOW}Fix permissions with:${NC}"
        echo -e "  ${BOLD}  sudo chown -R \$USER: $PROJECT_ROOT/kernels/ $PROJECT_ROOT/initramfs/${NC}"
        echo ""
        exit 1
    fi
}

# ── Falco binary download ─────────────────────────────────────────────────────
setup_falco_binary() {
    banner "Falco Binary"
    if [[ -x "$PROJECT_ROOT/falco/bin/falco" ]]; then
        skip "Already present: falco/bin/falco"
        return 0
    fi
    info "Downloading Falco binary..."
    bash "$DOWNLOADER_DIR/falco_binary.sh"
}

# ── Get uname -r for a kernel ─────────────────────────────────────────────────
# Priority: 1) existing log  2) vmlinuz strings  3) discovery boot
get_uname_r() {
    local kernel_name="$1"
    local log="$RESULTS_DIR/${kernel_name}.log"
    local vmlinuz="$PROJECT_ROOT/kernels/$kernel_name/vmlinuz"

    # 1. From existing log
    if [[ -f "$log" ]]; then
        local kver
        kver=$(grep -oP '(?<=\[BOOT\] kernel=)\S+' "$log" 2>/dev/null | head -1)
        [[ -z "$kver" ]] && kver=$(grep -oP '(?<=Kernel Version: )\S+' "$log" 2>/dev/null | head -1)
        [[ -n "$kver" ]] && { echo "$kver"; return 0; }
    fi

    # 2. From vmlinuz strings (fast, no VM needed)
    #    strings returns full build banner like "4.18.0-553.el8_10.x86_64 (mockbuild@...)"
    #    — extract only the first word (the actual uname -r)
    if [[ -f "$vmlinuz" ]]; then
        local kver
        kver=$(strings "$vmlinuz" 2>/dev/null \
               | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" \
               | grep -vE "^[0-9]+\.[0-9]+\.[0-9]+$" \
               | grep -E "generic|amd64|x86_64|el[6789]" \
               | awk '{print $1}' \
               | head -1)
        [[ -n "$kver" ]] && { echo "$kver"; return 0; }
    fi

    # 3. Discovery boot — boot VM with base initramfs, capture [BOOT] line
    if [[ -f "$vmlinuz" ]] && [[ -f "$PROJECT_ROOT/initramfs-base.img" ]]; then
        info "  Discovery boot for $kernel_name (no log found)..."
        local tmplog
        tmplog=$(mktemp)
        local kvm_flag=""
        [[ -e /dev/kvm ]] && kvm_flag="-enable-kvm"

        : > "$tmplog"
        # Use a minimal initramfs that just boots and reports uname-r
        timeout 60 qemu-system-x86_64 \
            -kernel "$vmlinuz" \
            -initrd "$PROJECT_ROOT/initramfs-base.img" \
            -m 256M -smp 1 $kvm_flag \
            -nographic -no-reboot \
            -append "console=ttyS0 init=/init quiet" \
            < /dev/null >> "$tmplog" 2>&1 || true

        local kver
        kver=$(grep -oP '(?<=\[BOOT\] kernel=)\S+' "$tmplog" 2>/dev/null | head -1)
        rm -f "$tmplog"
        [[ -n "$kver" ]] && { echo "$kver"; return 0; }
    fi

    return 1
}

# ── Per-kernel setup ──────────────────────────────────────────────────────────
setup_kernel() {
    local distro="$1" version="$2" kernel_version="$3"
    local kernel_name="${distro}-${version}-${kernel_version}"
    local vmlinuz="$PROJECT_ROOT/kernels/$kernel_name/vmlinuz"
    local initramfs="$PROJECT_ROOT/initramfs/${kernel_name}.img"

    banner "Kernel: $kernel_name"

    # ── Step A: Download vmlinuz ─────────────────────────────────────────────
    phase "A  DOWNLOAD vmlinuz"
    if [[ -f "$vmlinuz" ]]; then
        skip "Already present: $vmlinuz  ($(du -sh "$vmlinuz" | cut -f1))"
    else
        local downloader="$DOWNLOADER_DIR/${distro}.sh"
        [[ ! -f "$downloader" ]] && { fail "Downloader not found: $downloader"; return 1; }
        mkdir -p "$(dirname "$vmlinuz")"
        info "Running $distro downloader for $kernel_version..."
        echo ""
        bash "$downloader" "$kernel_version" "$(dirname "$vmlinuz")" < /dev/null || {
            fail "Download failed for $kernel_name"
            return 1
        }
        echo ""
        ok "vmlinuz → $vmlinuz  ($(du -sh "$vmlinuz" | cut -f1))"
    fi

    # ── Step B: Discover uname -r ────────────────────────────────────────────
    phase "B  DISCOVER uname -r"
    local uname_r
    if uname_r=$(get_uname_r "$kernel_name"); then
        ok "uname -r: ${BOLD}$uname_r${NC}"
    else
        # Build minimal initramfs and boot to discover
        info "Building minimal initramfs for discovery boot..."
        bash "$BUILDER_DIR/build_per_kernel.sh" "$kernel_name" > /dev/null 2>&1 || true
        if uname_r=$(get_uname_r "$kernel_name"); then
            ok "uname -r: ${BOLD}$uname_r${NC}  (discovered via boot)"
        else
            fail "Cannot determine uname -r for $kernel_name — skipping driver download"
            uname_r=""
        fi
    fi

    # ── Step C: Download Falco drivers ───────────────────────────────────────
    phase "C  DOWNLOAD Falco drivers"
    local modules_dir="$PROJECT_ROOT/modules/$kernel_name"
    local kmaj kmin
    kmaj=$(echo "$uname_r" | cut -d. -f1)
    kmin=$(echo "$uname_r" | cut -d. -f2)
    local need_ko=0 need_o=0
    [[ ! -f "$modules_dir/falco_probe.ko" ]] && need_ko=1
    # .o only needed for kernels >= 4.14
    if [[ "$kmaj" -gt 4 ]] || { [[ "$kmaj" -eq 4 ]] && [[ "$kmin" -ge 14 ]]; }; then
        [[ ! -f "$modules_dir/falco_probe.o" ]] && need_o=1
    fi

    if [[ $need_ko -eq 0 ]] && [[ $need_o -eq 0 ]]; then
        skip "Drivers already present in modules/$kernel_name/"
        [[ -f "$modules_dir/falco_probe.ko" ]] && ok "  falco_probe.ko  ($(du -sh "$modules_dir/falco_probe.ko" | cut -f1))"
        [[ -f "$modules_dir/falco_probe.o"  ]] && ok "  falco_probe.o   ($(du -sh "$modules_dir/falco_probe.o"  | cut -f1))"
    elif [[ -n "$uname_r" ]]; then
        [[ $need_ko -eq 1 ]] && info "Need .ko" || info ".ko already present"
        [[ $need_o  -eq 1 ]] && info "Need .o"  || info ".o already present (or not applicable)"
        bash "$DOWNLOADER_DIR/falco_drivers.sh" "$kernel_name" "$uname_r" || \
            skip "No prebuilt drivers found — Falco test will be SKIP for this kernel"
    else
        skip "uname -r unknown — cannot search for drivers"
    fi

    # ── Step D: Build per-kernel initramfs ──────────────────────────────────
    phase "D  BUILD initramfs"
    # Always rebuild if modules were newly downloaded
    if [[ -f "$initramfs" ]]; then
        local initramfs_mtime modules_mtime
        initramfs_mtime=$(stat -c %Y "$initramfs" 2>/dev/null || echo 0)
        modules_mtime=0
        for f in "$modules_dir"/*.ko "$modules_dir"/*.o; do
            [[ -f "$f" ]] || continue
            local fmtime
            fmtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
            [[ $fmtime -gt $modules_mtime ]] && modules_mtime=$fmtime
        done
        if [[ $modules_mtime -le $initramfs_mtime ]]; then
            skip "Already up-to-date: $initramfs  ($(du -sh "$initramfs" | cut -f1))"
            return 0
        fi
        info "Modules are newer than initramfs — rebuilding..."
        rm -f "$initramfs"
    fi

    info "Building $kernel_name initramfs..."
    if bash "$BUILDER_DIR/build_per_kernel.sh" "$kernel_name"; then
        ok "initramfs → $initramfs  ($(du -sh "$initramfs" | cut -f1))"
    else
        fail "initramfs build failed for $kernel_name"
        return 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    banner "Falco Kernel Test — Setup"

    check_prerequisites

    # Phase 1: Falco binary
    setup_falco_binary

    # Phase 2: Base initramfs — rebuild if any source file is newer
    banner "Base Initramfs"
    local base_img="$PROJECT_ROOT/initramfs-base.img"
    local need_base_rebuild=0
    if [[ ! -f "$base_img" ]]; then
        need_base_rebuild=1
    else
        local base_mtime
        base_mtime=$(stat -c %Y "$base_img" 2>/dev/null || echo 0)
        for src in \
            "$BUILDER_DIR/build_base.sh" \
            "$PROJECT_ROOT/falco/bin/falco" \
            "$PROJECT_ROOT/config/falco.yaml" \
            "$PROJECT_ROOT/config/falco_rules_minimal.yaml"; do
            [[ -f "$src" ]] || continue
            local src_mtime
            src_mtime=$(stat -c %Y "$src" 2>/dev/null || echo 0)
            if [[ $src_mtime -gt $base_mtime ]]; then
                info "$(basename "$src") is newer than base image — will rebuild"
                need_base_rebuild=1
                break
            fi
        done
    fi
    if [[ $need_base_rebuild -eq 1 ]]; then
        rm -f "$base_img"
        bash "$BUILDER_DIR/build_base.sh" || { fail "Base build failed"; exit 1; }
    else
        skip "Already up-to-date: initramfs-base.img  ($(du -sh "$base_img" | cut -f1))"
    fi

    # Phase 3: Per-kernel setup
    mkdir -p "$RESULTS_DIR"
    [[ ! -f "$KERNELS_LIST" ]] && { fail "Not found: $KERNELS_LIST"; exit 1; }

    local total=0 ok_count=0 fail_count=0

    while IFS=: read -r distro version kernel_version; do
        [[ "$distro" =~ ^# ]] && continue
        [[ -z "$distro" ]]    && continue
        total=$((total + 1))
        if setup_kernel "$distro" "$version" "$kernel_version"; then
            ok_count=$((ok_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done < "$KERNELS_LIST"

    # Phase 4: Run full tests
    banner "Running Tests"
    echo ""
    bash "$PROJECT_ROOT/run_tests.sh"
}

main "$@"
