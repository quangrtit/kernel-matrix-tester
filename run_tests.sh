#!/bin/bash
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADER_DIR="$PROJECT_ROOT/downloader"
BUILDER_DIR="$PROJECT_ROOT/builder"
CONFIG_DIR="$PROJECT_ROOT/config"
KERNELS_LIST="$CONFIG_DIR/kernels.list"
RESULTS_DIR="$PROJECT_ROOT/results"

# Delay between kernel runs in seconds (override: KERNEL_DELAY=5 bash run_tests.sh)
KERNEL_DELAY="${KERNEL_DELAY:-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
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
    echo -e "${BOLD}  [$*]${NC}"
}

# Format a structured [TAG] line emitted by the init script in the VM
format_vm_line() {
    local line="$1"
    local name result rest detail

    case "$line" in
        "[BOOT] "*)
            local kver arch
            kver=$(printf '%s' "$line" | sed 's/.*kernel=\([^ ]*\).*/\1/')
            arch=$(printf '%s' "$line" | sed 's/.*arch=\([^ ]*\).*/\1/')
            printf "    ${GREEN}✓${NC}  %-8s │  kernel: ${BOLD}%-36s${NC} arch: %s\n" "Boot OK" "$kver" "$arch"
            ;;
        "[KO] "*)
            rest="${line#\[KO\] }"
            name=$(printf '%s' "$rest" | awk '{print $1}')
            result=$(printf '%s' "$rest" | awk '{print $2}')
            case "$result" in
                PASS) printf "    ${GREEN}✓${NC}  %-8s │  %-40s  ${GREEN}PASS${NC}\n" ".ko" "$name" ;;
                FAIL)
                    detail=$(printf '%s' "$rest" | cut -d' ' -f3- | cut -c1-50)
                    printf "    ${RED}✗${NC}  %-8s │  %-40s  ${RED}FAIL${NC}  %s\n" ".ko" "$name" "$detail" ;;
                "(none)") printf "    ${DIM}·${NC}  %-8s │  (no .ko modules in this initramfs)\n" ".ko" ;;
            esac
            ;;
        "[BPF] "*)
            rest="${line#\[BPF\] }"
            name=$(printf '%s' "$rest" | awk '{print $1}')
            result=$(printf '%s' "$rest" | awk '{print $2}')
            case "$result" in
                PASS) printf "    ${GREEN}✓${NC}  %-8s │  %-40s  ${GREEN}PASS${NC}\n" ".o" "$name" ;;
                FAIL)
                    detail=$(printf '%s' "$rest" | cut -d' ' -f3- | cut -c1-50)
                    printf "    ${RED}✗${NC}  %-8s │  %-40s  ${RED}FAIL${NC}  %s\n" ".o" "$name" "$detail" ;;
                SKIP)
                    detail=$(printf '%s' "$rest" | cut -d' ' -f3-)
                    printf "    ${YELLOW}~${NC}  %-8s │  %-40s  ${YELLOW}SKIP${NC}  %s\n" ".o" "$name" "$detail" ;;
                "(none)") printf "    ${DIM}·${NC}  %-8s │  (no .o probes in this initramfs)\n" ".o" ;;
            esac
            ;;
        "[FALCO] "*)
            rest="${line#\[FALCO\] }"
            result=$(printf '%s' "$rest" | awk '{print $1}')
            detail=$(printf '%s' "$rest" | cut -d' ' -f2-)
            case "$result" in
                PASS) printf "    ${GREEN}✓${NC}  %-8s │  %-40s  ${GREEN}PASS${NC}\n" "falco" "$detail" ;;
                FAIL) printf "    ${RED}✗${NC}  %-8s │  %-40s  ${RED}FAIL${NC}\n" "falco" "$detail" ;;
                SKIP) printf "    ${YELLOW}~${NC}  %-8s │  %-40s  ${YELLOW}SKIP${NC}\n" "falco" "$detail" ;;
            esac
            ;;
        "[FALCO_KO] "*)
            rest="${line#\[FALCO_KO\] }"
            result=$(printf '%s' "$rest" | awk '{print $1}')
            detail=$(printf '%s' "$rest" | cut -d' ' -f2-)
            case "$result" in
                PASS) printf "    ${GREEN}✓${NC}  %-8s │  %-40s  ${GREEN}PASS${NC}\n" "falco/ko" "$detail" ;;
                FAIL) printf "    ${RED}✗${NC}  %-8s │  %-40s  ${RED}FAIL${NC}  %s\n" "falco/ko" "" "$detail" ;;
                SKIP) printf "    ${YELLOW}~${NC}  %-8s │  %-40s  ${YELLOW}SKIP${NC}\n" "falco/ko" "$detail" ;;
            esac
            ;;
        "[FALCO_EBPF] "*)
            rest="${line#\[FALCO_EBPF\] }"
            result=$(printf '%s' "$rest" | awk '{print $1}')
            detail=$(printf '%s' "$rest" | cut -d' ' -f2-)
            case "$result" in
                PASS) printf "    ${GREEN}✓${NC}  %-8s │  %-40s  ${GREEN}PASS${NC}\n" "falco/ebpf" "$detail" ;;
                FAIL) printf "    ${RED}✗${NC}  %-8s │  %-40s  ${RED}FAIL${NC}  %s\n" "falco/ebpf" "" "$detail" ;;
                SKIP) printf "    ${YELLOW}~${NC}  %-8s │  %-40s  ${YELLOW}SKIP${NC}\n" "falco/ebpf" "$detail" ;;
            esac
            ;;
        "[FALCO_STEP] "*)
            rest="${line#\[FALCO_STEP\] }"
            printf "    ${CYAN}→${NC}  %-8s │  %s\n" "falco" "$rest"
            ;;
        "[FALCO_OUT] "*)
            rest="${line#\[FALCO_OUT\] }"
            printf "    ${DIM}   %-8s │  %s${NC}\n" "" "$rest"
            ;;
        "[FALCO_ERR] "*)
            rest="${line#\[FALCO_ERR\] }"
            printf "    ${RED}!${NC}  %-8s │  %s\n" "falco-err" "$rest"
            ;;
    esac
}

check_prerequisites() {
    banner "Checking prerequisites"
    local missing=0
    for cmd in qemu-system-x86_64 wget cpio gzip; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd"
        else
            fail "$cmd — not found"
            missing=1
        fi
    done
    [[ -e /dev/kvm ]] && ok "KVM available" || skip "KVM not available (will run slow)"
    [[ $missing -eq 1 ]] && { echo ""; echo -e "${RED}Install missing packages first${NC}"; exit 1; }
}

build_base_if_needed() {
    local base_img="$PROJECT_ROOT/initramfs-base.img"
    banner "Base initramfs"
    if [[ ! -f "$base_img" ]]; then
        info "Building base initramfs..."
        bash "$BUILDER_DIR/build_base.sh" && ok "Built: $base_img" || {
            fail "Build failed"
            exit 1
        }
    else
        ok "Already exists: $base_img  ($(du -sh "$base_img" | cut -f1))"
    fi
}

run_one_kernel() {
    local distro=$1 version=$2 kernel_version=$3
    local kernel_name="${distro}-${version}-${kernel_version}"
    local vmlinuz="$PROJECT_ROOT/kernels/$kernel_name/vmlinuz"
    local initramfs="$PROJECT_ROOT/initramfs/${kernel_name}.img"
    local log_file="$RESULTS_DIR/${kernel_name}.log"
    local status="FAIL"

    banner "Kernel: $kernel_name"

    # ── Phase 1: Download ────────────────────────────────────────────────────
    phase "1/3  DOWNLOAD"
    if [[ -f "$vmlinuz" ]]; then
        skip "Already downloaded: $vmlinuz  ($(du -sh "$vmlinuz" | cut -f1))"
    else
        local downloader="$DOWNLOADER_DIR/${distro}.sh"
        if [[ ! -f "$downloader" ]]; then
            fail "Downloader not found: $downloader"
            return 1
        fi
        mkdir -p "$(dirname "$vmlinuz")"
        info "Running $distro downloader for $kernel_version ..."
        echo ""
        if bash "$downloader" "$kernel_version" "$(dirname "$vmlinuz")" < /dev/null; then
            echo ""
            ok "vmlinuz saved: $vmlinuz  ($(du -sh "$vmlinuz" | cut -f1))"
        else
            echo ""
            fail "Download failed — skipping this kernel"
            return 1
        fi
    fi

    # ── Phase 2: Build initramfs ─────────────────────────────────────────────
    phase "2/3  BUILD INITRAMFS"
    if [[ -f "$initramfs" ]]; then
        skip "Already built: $initramfs  ($(du -sh "$initramfs" | cut -f1))"
    else
        info "Building initramfs for $kernel_name ..."
        if bash "$BUILDER_DIR/build_per_kernel.sh" "$kernel_name" < /dev/null 2>&1; then
            ok "initramfs saved: $initramfs  ($(du -sh "$initramfs" | cut -f1))"
        else
            fail "Build failed"
            return 1
        fi
    fi

    # ── Phase 3: Boot test ───────────────────────────────────────────────────
    phase "3/3  BOOT TEST"
    info "Starting QEMU..."
    echo ""

    local kvm_flag=""
    [[ -e /dev/kvm ]] && kvm_flag="-enable-kvm"

    local start_time=$SECONDS

    # Prepare fresh log file and start a background filter for real-time display
    : > "$log_file"
    tail -f "$log_file" 2>/dev/null \
        | grep --line-buffered -E "^\[(BOOT|KO|BPF|FALCO(_KO|_EBPF|_STEP|_OUT|_ERR)?)\]" \
        | while IFS= read -r line; do
            format_vm_line "$line"
          done &
    local TAIL_PID=$!

    # Run QEMU — all output goes to log file
    # shellcheck disable=SC2086
    timeout 180 qemu-system-x86_64 \
        -kernel "$vmlinuz" \
        -initrd "$initramfs" \
        -m 512M \
        -smp 2 \
        $kvm_flag \
        -nographic \
        -no-reboot \
        -append "console=ttyS0 init=/init quiet" \
        < /dev/null >> "$log_file" 2>&1
    local qemu_exit=$?

    # Drain: wait up to 2s for the tail pipeline to flush remaining lines
    local drain=0
    while [[ $drain -lt 20 ]]; do
        sleep 0.1
        drain=$((drain + 1))
        # Stop draining once ALL_DONE marker has been displayed
        grep -q "ALL_DONE" "$log_file" 2>/dev/null && break
    done
    pkill -P $$ tail
    pkill -P $$ grep

    kill "$TAIL_PID" 2>/dev/null
    wait "$TAIL_PID" 2>/dev/null || true

    local elapsed=$((SECONDS - start_time))
    echo ""

    # ── Evaluate result ────────────────────────────────────────────────────
    if [[ $qemu_exit -eq 124 ]]; then
        fail "TIMEOUT after ${elapsed}s — log: $log_file"
        echo "  Last 5 lines:"
        tail -5 "$log_file" | sed 's/^/    /'
        return 1
    fi

    if grep -q "ALL_DONE" "$log_file"; then
        local result_line
        result_line=$(grep "^RESULT:" "$log_file" | tail -1)
        local ko_pass ko_fail bpf_pass bpf_fail bpf_skip falco_ko falco_ebpf
        ko_pass=$(echo "$result_line"   | grep -oP 'KO_PASS=\K\d+')
        ko_fail=$(echo "$result_line"   | grep -oP 'KO_FAIL=\K\d+')
        bpf_pass=$(echo "$result_line"  | grep -oP 'BPF_PASS=\K\d+')
        bpf_fail=$(echo "$result_line"  | grep -oP 'BPF_FAIL=\K\d+')
        bpf_skip=$(echo "$result_line"  | grep -oP 'BPF_SKIP=\K\d+')
        falco_ko=$(echo "$result_line"  | grep -oP 'FALCO_KO=\K\S+')
        falco_ebpf=$(echo "$result_line"| grep -oP 'FALCO_EBPF=\K\S+')

        # Overall: PASS when no driver FAILs and neither Falco test is FAIL
        if [[ "${ko_fail:-0}" -eq 0 ]] && [[ "${bpf_fail:-0}" -eq 0 ]] \
           && [[ "${falco_ko:-SKIP}"   != "FAIL" ]] \
           && [[ "${falco_ebpf:-SKIP}" != "FAIL" ]]; then
            status="PASS"
        else
            status="FAIL"
        fi

        local falco_summary="ko:${falco_ko:-SKIP} ebpf:${falco_ebpf:-SKIP}"
        if [[ "$status" == "PASS" ]]; then
            ok "Boot PASS  (${elapsed}s)  │  .ko: ${ko_pass:-0}P/${ko_fail:-0}F  .o: ${bpf_pass:-0}P/${bpf_fail:-0}F/${bpf_skip:-0}S  falco: ${falco_summary}"
        else
            fail "Boot FAIL  (${elapsed}s)  │  .ko: ${ko_pass:-0}P/${ko_fail:-0}F  .o: ${bpf_pass:-0}P/${bpf_fail:-0}F/${bpf_skip:-0}S  falco: ${falco_summary}"
        fi
    else
        fail "Boot FAILED — ALL_DONE marker not found  (${elapsed}s)"
        echo "  Last 5 lines of log:"
        tail -5 "$log_file" | sed 's/^/    /'
    fi

    echo "  Log: $log_file"
    [[ "$status" == "PASS" ]] && return 0 || return 1
}

main() {
    banner "Falco Kernel Test Framework"

    check_prerequisites
    build_base_if_needed
    mkdir -p "$RESULTS_DIR"

    [[ ! -f "$KERNELS_LIST" ]] && { fail "Not found: $KERNELS_LIST"; exit 1; }

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

        # Inter-kernel cooldown (let QEMU fully release KVM/resources)
        [[ "$KERNEL_DELAY" -gt 0 ]] && sleep "$KERNEL_DELAY"
    done < "$KERNELS_LIST"

    # ── Final summary ──────────────────────────────────────────────────────
    banner "Summary"
    for r in "${results[@]}"; do
        echo -e "  $r"
    done
    echo ""
    echo -e "  Total : ${BOLD}$total${NC}"
    echo -e "  ${GREEN}Passed${NC}: $passed"
    echo -e "  ${RED}Failed${NC}: $failed"
    echo -e "  Logs  : $RESULTS_DIR"
    echo ""
}

main "$@"
