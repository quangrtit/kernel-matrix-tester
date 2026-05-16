#!/bin/bash
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

step_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
step_fail() { echo -e "  ${RED}✗${NC} $*"; }
step_skip() { echo -e "  ${YELLOW}~${NC} $*"; }
step_info() { echo -e "  ${CYAN}→${NC} $*"; }

banner() {
    echo ""
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $*${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════${NC}"
}

phase() {
    echo ""
    echo -e "${BOLD}  [$*]${NC}"
}

check_prerequisites() {
    banner "Checking prerequisites"
    local missing=0
    for cmd in qemu-system-x86_64 wget cpio gzip; do
        if command -v "$cmd" &>/dev/null; then
            step_ok "$cmd"
        else
            step_fail "$cmd — not found"
            missing=1
        fi
    done
    [[ -e /dev/kvm ]] && step_ok "KVM available" || step_skip "KVM not available (will run slow)"
    [[ $missing -eq 1 ]] && { echo ""; echo -e "${RED}Install missing packages first${NC}"; exit 1; }
}

build_base_if_needed() {
    local base_img="$PROJECT_ROOT/initramfs-base.img"
    banner "Base initramfs"
    if [[ ! -f "$base_img" ]]; then
        step_info "Building base initramfs..."
        bash "$BUILDER_DIR/build_base.sh" && step_ok "Built: $base_img" || {
            step_fail "Build failed"
            exit 1
        }
    else
        step_ok "Already exists: $base_img ($(du -sh "$base_img" | cut -f1))"
    fi
}

run_one_kernel() {
    local distro=$1 version=$2 kernel_version=$3
    local kernel_name="${distro}-${version}-${kernel_version}"
    local output_dir="$PROJECT_ROOT/kernels/$kernel_name"
    local vmlinuz="$output_dir/vmlinuz"
    local initramfs="$PROJECT_ROOT/initramfs/${kernel_name}.img"
    local log_file="$RESULTS_DIR/${kernel_name}.log"
    local status="FAIL"

    banner "Kernel: $kernel_name"

    # ── Phase 1: Download ────────────────────────────────
    phase "1/3  DOWNLOAD"
    if [[ -f "$vmlinuz" ]]; then
        step_skip "Already downloaded: $vmlinuz ($(du -sh "$vmlinuz" | cut -f1))"
    else
        local downloader="$DOWNLOADER_DIR/${distro}.sh"
        if [[ ! -f "$downloader" ]]; then
            step_fail "Downloader not found: $downloader"
            return 1
        fi
        mkdir -p "$output_dir"
        step_info "Running $distro downloader for $kernel_version ..."
        echo ""
        if bash "$downloader" "$kernel_version" "$output_dir"; then
            echo ""
            step_ok "vmlinuz saved: $vmlinuz ($(du -sh "$vmlinuz" | cut -f1))"
        else
            echo ""
            step_fail "Download failed — skipping this kernel"
            return 1
        fi
    fi

    # ── Phase 2: Build initramfs ─────────────────────────
    phase "2/3  BUILD INITRAMFS"
    if [[ -f "$initramfs" ]]; then
        step_skip "Already built: $initramfs ($(du -sh "$initramfs" | cut -f1))"
    else
        step_info "Building initramfs for $kernel_name ..."
        if bash "$BUILDER_DIR/build_per_kernel.sh" "$kernel_name" 2>&1; then
            step_ok "initramfs saved: $initramfs ($(du -sh "$initramfs" | cut -f1))"
        else
            step_fail "Build failed"
            return 1
        fi
    fi

    # ── Phase 3: Boot test ───────────────────────────────
    phase "3/3  BOOT TEST"
    step_info "Starting QEMU ..."
    echo ""

    local kvm_flag=""
    [[ -e /dev/kvm ]] && kvm_flag="-enable-kvm"

    timeout 60 qemu-system-x86_64 \
        -kernel "$vmlinuz" \
        -initrd "$initramfs" \
        -m 512M \
        -smp 2 \
        $kvm_flag \
        -nographic \
        -no-reboot \
        -append "console=ttyS0 init=/init quiet" \
        < /dev/null \
        2>&1 | tee "$log_file" || true

    echo ""
    if grep -q "ALL_DONE" "$log_file"; then
        local kver
        kver=$(grep "Kernel Version:" "$log_file" | head -1 | awk -F': ' '{print $2}')
        step_ok "Boot OK | uname -r: ${BOLD}$kver${NC}"
        status="PASS"
    else
        step_fail "Boot FAILED — last 5 lines of log:"
        tail -5 "$log_file" | sed 's/^/    /'
    fi

    echo "$status" >> "$log_file"
    [[ "$status" == "PASS" ]] && return 0 || return 1
}

main() {
    banner "Falco Kernel Test Framework"

    check_prerequisites
    build_base_if_needed
    mkdir -p "$RESULTS_DIR"

    [[ ! -f "$KERNELS_LIST" ]] && { step_fail "Not found: $KERNELS_LIST"; exit 1; }

    local total=0 passed=0 failed=0
    local results=()

    while IFS=: read -r distro version kernel_version; do
        [[ "$distro" =~ ^# ]] && continue
        [[ -z "$distro" ]]    && continue
        total=$((total + 1))

        if run_one_kernel "$distro" "$version" "$kernel_version"; then
            passed=$((passed + 1))
            results+=("${GREEN}PASS${NC}  ${distro}-${version}-${kernel_version}")
        else
            failed=$((failed + 1))
            results+=("${RED}FAIL${NC}  ${distro}-${version}-${kernel_version}")
        fi

    done < "$KERNELS_LIST"

    # ── Final summary ────────────────────────────────────
    banner "Summary"
    for r in "${results[@]}"; do
        echo -e "  $r"
    done
    echo ""
    echo -e "  Total : $total"
    echo -e "  ${GREEN}Passed${NC}: $passed"
    echo -e "  ${RED}Failed${NC}: $failed"
    echo -e "  Logs  : $RESULTS_DIR"
    echo ""
}

main "$@"