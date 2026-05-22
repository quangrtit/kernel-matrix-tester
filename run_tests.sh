#!/bin/bash
# Run Falco kernel tests.
#
# For each kernel in config/kernels.list:
#   1. Download Falco drivers (.ko/.o)
#   2. Build per-kernel initramfs
#   3. Boot QEMU + run tests
#
# All steps logged to: results/<kernel_name>.log
#
# Usage:
#   ./run_tests.sh                        # all kernels
#   DISTRO=centos ./run_tests.sh          # centos only
#   KERNEL_FILTER=4.18.0 ./run_tests.sh  # substring filter
#   USE_CACHE=0 ./run_tests.sh           # ignore cache, re-run everything

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADER_DIR="$PROJECT_ROOT/downloader"
BUILDER_DIR="$PROJECT_ROOT/builder"
CONFIG_DIR="$PROJECT_ROOT/config"
KERNELS_LIST="$CONFIG_DIR/kernels.list"
RESULTS_DIR="$PROJECT_ROOT/results"

KERNEL_DELAY="${KERNEL_DELAY:-1}"
MAX_KERNEL_MAJOR="${MAX_KERNEL_MAJOR:-5}"  # skip kernels with major version > this
USE_CACHE="${USE_CACHE:-1}"        # set 0 to skip cache and re-run everything
CACHE_FILE="$RESULTS_DIR/cache.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

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

section() {
    echo ""
    echo -e "${BOLD}  ─── $* ───${NC}"
}

# Log to file and console simultaneously
tlog() { echo -e "$*" | tee -a "$CURRENT_LOG"; }

# ── Discover uname -r ─────────────────────────────────────────────────────────
get_uname_r() {
    local kernel_name="$1" log="$2"
    local vmlinuz="$PROJECT_ROOT/kernels/$kernel_name/vmlinuz"

    # 1. From existing log (previous boot)
    if [[ -f "$log" ]]; then
        local kver
        kver=$(grep -oP '(?<=\[BOOT\] kernel=)\S+' "$log" 2>/dev/null | head -1)
        [[ -n "$kver" ]] && echo "$kver" && return 0
    fi

    # 2. From vmlinuz binary strings (fast)
    if [[ -f "$vmlinuz" ]] && command -v strings &>/dev/null; then
        local kver
        kver=$(strings "$vmlinuz" 2>/dev/null \
               | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" \
               | grep -E "generic|amd64|x86_64|el[6-9]" \
               | awk '{print $1}' | head -1)
        [[ -n "$kver" ]] && echo "$kver" && return 0
    fi

    # 3. Quick discovery boot with base initramfs
    if [[ -f "$vmlinuz" ]] && [[ -f "$PROJECT_ROOT/initramfs-base.img" ]]; then
        local kvm_flag=""; [[ -e /dev/kvm ]] && kvm_flag="-enable-kvm"
        local tmp; tmp=$(mktemp)
        timeout 60 qemu-system-x86_64 \
            -kernel "$vmlinuz" -initrd "$PROJECT_ROOT/initramfs-base.img" \
            -m 256M -smp 1 $kvm_flag -nographic -no-reboot \
            -append "console=ttyS0 init=/init quiet" \
            < /dev/null >> "$tmp" 2>&1 || true
        local kver
        kver=$(grep -oP '(?<=\[BOOT\] kernel=)\S+' "$tmp" 2>/dev/null | head -1)
        rm -f "$tmp"
        [[ -n "$kver" ]] && echo "$kver" && return 0
    fi

    return 1
}

# Parse [TAG] lines from QEMU output for live display
format_vm_line() {
    local line="$1"
    case "$line" in
        "[BOOT] "*)
            local kver arch
            kver=$(sed 's/.*kernel=\([^ ]*\).*/\1/' <<< "$line")
            arch=$(sed 's/.*arch=\([^ ]*\).*/\1/' <<< "$line")
            printf "    ${GREEN}✓${NC}  boot     │  ${BOLD}%s${NC}  (%s)\n" "$kver" "$arch" ;;
        "[KO] "*)
            local rest="${line#\[KO\] }"
            local name result detail
            name=$(awk '{print $1}' <<< "$rest"); result=$(awk '{print $2}' <<< "$rest")
            case "$result" in
                PASS)   printf "    ${GREEN}✓${NC}  .ko      │  %-36s  ${GREEN}PASS${NC}\n" "$name" ;;
                FAIL)   detail=$(cut -d' ' -f3- <<< "$rest" | cut -c1-50)
                        printf "    ${RED}✗${NC}  .ko      │  %-36s  ${RED}FAIL${NC}  %s\n" "$name" "$detail" ;;
                "(none)") printf "    ${DIM}·${NC}  .ko      │  (no modules)\n" ;;
            esac ;;
        "[BPF] "*)
            local rest="${line#\[BPF\] }"
            local name result detail
            name=$(awk '{print $1}' <<< "$rest"); result=$(awk '{print $2}' <<< "$rest")
            case "$result" in
                PASS)   printf "    ${GREEN}✓${NC}  .o       │  %-36s  ${GREEN}PASS${NC}\n" "$name" ;;
                FAIL)   detail=$(cut -d' ' -f3- <<< "$rest" | cut -c1-50)
                        printf "    ${RED}✗${NC}  .o       │  %-36s  ${RED}FAIL${NC}  %s\n" "$name" "$detail" ;;
                SKIP)   detail=$(cut -d' ' -f3- <<< "$rest")
                        printf "    ${YELLOW}~${NC}  .o       │  %-36s  ${YELLOW}SKIP${NC}  %s\n" "$name" "$detail" ;;
                "(none)") printf "    ${DIM}·${NC}  .o       │  (no probes)\n" ;;
            esac ;;
        "[FALCO_KO] "*|"[FALCO_EBPF] "*)
            local tag; [[ "$line" == "[FALCO_KO] "* ]] && tag="falco/ko" || tag="falco/ebpf"
            local rest="${line#*\] }"
            local result detail
            result=$(awk '{print $1}' <<< "$rest"); detail=$(cut -d' ' -f2- <<< "$rest")
            case "$result" in
                PASS) printf "    ${GREEN}✓${NC}  %-8s │  ${GREEN}PASS${NC}  %s\n" "$tag" "$detail" ;;
                FAIL) printf "    ${RED}✗${NC}  %-8s │  ${RED}FAIL${NC}  %s\n"   "$tag" "$detail" ;;
                SKIP) printf "    ${YELLOW}~${NC}  %-8s │  ${YELLOW}SKIP${NC}  %s\n"  "$tag" "$detail" ;;
            esac ;;
        "[FALCO_STEP] "*)
            printf "    ${CYAN}→${NC}  falco    │  %s\n" "${line#\[FALCO_STEP\] }" ;;
        "[FALCO_ERR] "*)
            printf "    ${RED}!${NC}  falco    │  %s\n" "${line#\[FALCO_ERR\] }" ;;
    esac
}

# ── Result cache (results/cache.json) ────────────────────────────────────────
# Kernels are cached when ALL_DONE is present in their log (VM completed its
# test cycle).  Panic / TIMEOUT / initramfs-build failures are NOT cached.

cache_lookup() {
    local kname="$1"
    [[ $USE_CACHE -ne 1 ]] && return 1
    [[ ! -f "$CACHE_FILE" ]] && return 1
    local st
    st=$(CACHE_FILE="$CACHE_FILE" KNAME="$kname" python3 - <<'PYEOF' 2>/dev/null
import json, os, sys
try:
    with open(os.environ['CACHE_FILE']) as f:
        c = json.load(f)
    e = c.get(os.environ['KNAME'], {})
    if e:
        print(e.get('status', ''))
except Exception:
    pass
PYEOF
)
    # Only skip if VM completed its test cycle; FAILED (panic/timeout) must be retried
    [[ "$st" == "PASS" || "$st" == "FAIL" ]] && echo "$st" && return 0
    return 1
}

cache_write() {
    local kname="$1" status="$2" elapsed="$3" result_line="${4:-}"
    mkdir -p "$(dirname "$CACHE_FILE")"
    CACHE_FILE="$CACHE_FILE" KNAME="$kname" STATUS="$status" \
    ELAPSED="$elapsed" RESULT_LINE="$result_line" \
    python3 - <<'PYEOF' 2>/dev/null
import json, os
from datetime import datetime, timezone
path = os.environ['CACHE_FILE']
try:
    with open(path) as f:
        c = json.load(f)
except Exception:
    c = {}
c[os.environ['KNAME']] = {
    'cached_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'status': os.environ['STATUS'],
    'elapsed': int(os.environ.get('ELAPSED', 0)),
    'result_line': os.environ.get('RESULT_LINE', ''),
}
with open(path, 'w') as f:
    json.dump(c, f, indent=2)
PYEOF
}

# ── Run one kernel ─────────────────────────────────────────────────────────────
CURRENT_LOG=""

run_one_kernel() {
    local distro=$1 version=$2 kernel_version=$3
    local kname="${distro}-${version}-${kernel_version}"
    local vmlinuz="$PROJECT_ROOT/kernels/$kname/vmlinuz"
    local initramfs="$PROJECT_ROOT/initramfs/${kname}.img"
    local modules_dir="$PROJECT_ROOT/modules/$kname"
    local log="$RESULTS_DIR/${kname}.log"
    CURRENT_LOG="$log"
    local status="FAIL" fail_reason=""

    banner "$kname"
    mkdir -p "$RESULTS_DIR"

    # Write log header
    {
        echo "====================================================="
        echo " Kernel : $kname"
        echo " Date   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "====================================================="
    } > "$log"

    # ── Pre-flight ──────────────────────────────────────────────────────────
    if [[ ! -f "$vmlinuz" ]]; then
        fail "vmlinuz not found — run ./sync_kernels.sh first"
        echo "" >> "$log"; echo "RESULT: SKIP reason=vmlinuz-missing" >> "$log"
        return 1
    fi

    # ── Cache check ──────────────────────────────────────────────────────────
    if [[ $USE_CACHE -eq 1 ]]; then
        local cached_status
        if cached_status=$(cache_lookup "$kname"); then
            skip "Cached (${cached_status}) — skipping re-run  (USE_CACHE=0 to force)"
            echo "RESULT: CACHED status=$cached_status" >> "$log"
            [[ "$cached_status" == "PASS" ]] && return 0 || return 1
        fi
    fi

    # ── 1: Discover uname -r ────────────────────────────────────────────────
    section "1/3  uname -r"
    {
        echo ""
        echo "=== [1/3] uname -r ==="
    } >> "$log"

    local uname_r=""
    if uname_r=$(get_uname_r "$kname" "$log"); then
        ok "uname -r: ${BOLD}$uname_r${NC}"
        echo "uname-r: $uname_r" >> "$log"
    else
        skip "uname -r unknown — driver download skipped"
        echo "uname-r: unknown" >> "$log"
    fi

    # ── 2: Falco drivers ────────────────────────────────────────────────────
    section "2/3  Falco drivers"
    {
        echo ""
        echo "=== [2/3] Falco drivers ==="
    } >> "$log"

    if [[ -z "$uname_r" ]]; then
        skip "Skipped (uname -r unknown)"
        echo "SKIP: uname -r unknown" >> "$log"
    else
        local kmaj kmin
        kmaj=$(cut -d. -f1 <<< "$uname_r")
        kmin=$(cut -d. -f2 <<< "$uname_r")
        local need_ko=0 need_o=0
        [[ ! -f "$modules_dir/falco_probe.ko" ]] && need_ko=1
        if [[ "$kmaj" -gt 4 ]] || { [[ "$kmaj" -eq 4 ]] && [[ "$kmin" -ge 14 ]]; }; then
            [[ ! -f "$modules_dir/falco_probe.o" ]] && need_o=1
        fi

        if [[ $need_ko -eq 0 ]] && [[ $need_o -eq 0 ]]; then
            skip "Already present"
        else
            bash "$DOWNLOADER_DIR/falco_drivers.sh" "$kname" "$uname_r" \
                < /dev/null >> "$log" 2>&1 \
                || skip "No prebuilt drivers found — Falco tests will be SKIP"
        fi
        [[ -f "$modules_dir/falco_probe.ko" ]] && ok "falco_probe.ko"
        [[ -f "$modules_dir/falco_probe.o"  ]] && ok "falco_probe.o"
    fi

    # ── 3: Build initramfs ──────────────────────────────────────────────────
    section "3/3  initramfs"
    {
        echo ""
        echo "=== [3/3] initramfs ==="
    } >> "$log"

    local need_build=0
    if [[ ! -f "$initramfs" ]]; then
        need_build=1
    else
        local img_mtime mod_mtime=0
        img_mtime=$(stat -c %Y "$initramfs" 2>/dev/null || echo 0)
        for f in "$modules_dir"/*.ko "$modules_dir"/*.o; do
            [[ -f "$f" ]] || continue
            local mt; mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
            [[ $mt -gt $mod_mtime ]] && mod_mtime=$mt
        done
        [[ $mod_mtime -gt $img_mtime ]] && need_build=1 && rm -f "$initramfs"
    fi

    if [[ $need_build -eq 0 ]]; then
        skip "Already up-to-date  ($(du -sh "$initramfs" | cut -f1))"
    else
        if bash "$BUILDER_DIR/build_per_kernel.sh" "$kname" < /dev/null >> "$log" 2>&1; then
            ok "Built  ($(du -sh "$initramfs" | cut -f1))"
        else
            fail "initramfs build failed — see $log"
            echo "" >> "$log"; echo "RESULT: FAIL reason=initramfs-build-failed" >> "$log"
            cache_write "$kname" "FAILED" "0" "reason=initramfs-build-failed"
            return 1
        fi
    fi

    # ── Boot test ───────────────────────────────────────────────────────────
    echo ""
    info "Starting QEMU ..."
    {
        echo ""
        echo "=== [BOOT TEST] $(date -u '+%H:%M:%S') ==="
    } >> "$log"
    echo ""

    local kvm_flag=""; [[ -e /dev/kvm ]] && kvm_flag="-enable-kvm"
    local t0=$SECONDS

    # Live display: stream structured [TAG] lines to console
    tail -f "$log" 2>/dev/null \
        | grep --line-buffered -E "^\[(BOOT|KO|BPF|FALCO(_KO|_EBPF|_STEP|_ERR)?)\]" \
        | while IFS= read -r line; do format_vm_line "$line"; done &
    local TAIL_PID=$!

    timeout 180 qemu-system-x86_64 \
        -kernel "$vmlinuz" -initrd "$initramfs" \
        -m 512M -smp 2 $kvm_flag \
        -nographic -no-reboot \
        -append "console=ttyS0 init=/init quiet" \
        < /dev/null >> "$log" 2>&1
    local qemu_rc=$?

    # Drain tail pipeline
    local d=0; while [[ $d -lt 20 ]]; do
        sleep 0.1; d=$((d+1))
        grep -q "ALL_DONE" "$log" 2>/dev/null && break
    done
    pkill -P $$ tail 2>/dev/null || true
    pkill -P $$ grep 2>/dev/null || true
    kill "$TAIL_PID" 2>/dev/null; wait "$TAIL_PID" 2>/dev/null || true

    local elapsed=$((SECONDS - t0))
    echo ""

    # Evaluate result
    if [[ $qemu_rc -eq 124 ]]; then
        fail_reason="TIMEOUT after ${elapsed}s"
        fail "$fail_reason"
        echo "  Last 5 lines:"; tail -5 "$log" | sed 's/^/    /'
        cache_write "$kname" "FAILED" "$elapsed" "reason=TIMEOUT"
    elif grep -q "ALL_DONE" "$log"; then
        local rl; rl=$(grep "^RESULT:" "$log" | tail -1)
        local ko_f bpf_f fko febpf
        ko_f=$(grep -oP 'KO_FAIL=\K\d+'  <<< "$rl" || echo 0)
        bpf_f=$(grep -oP 'BPF_FAIL=\K\d+' <<< "$rl" || echo 0)
        fko=$(grep -oP 'FALCO_KO=\K\S+'   <<< "$rl" || echo SKIP)
        febpf=$(grep -oP 'FALCO_EBPF=\K\S+' <<< "$rl" || echo SKIP)

        if [[ "${ko_f:-0}" -eq 0 ]] && [[ "${bpf_f:-0}" -eq 0 ]] \
           && [[ "$fko" != "FAIL" ]] && [[ "$febpf" != "FAIL" ]]; then
            status="PASS"
        else
            fail_reason=".ko:${ko_f}F .o:${bpf_f}F falco:$fko/$febpf"
        fi

        local ko_p bpf_p bpf_s
        ko_p=$(grep -oP 'KO_PASS=\K\d+'   <<< "$rl" || echo 0)
        bpf_p=$(grep -oP 'BPF_PASS=\K\d+' <<< "$rl" || echo 0)
        bpf_s=$(grep -oP 'BPF_SKIP=\K\d+' <<< "$rl" || echo 0)
        local summary=".ko: ${ko_p}P/${ko_f}F  .o: ${bpf_p}P/${bpf_f}F/${bpf_s}S  falco: ko=$fko ebpf=$febpf"

        # VM completed — cache result (panic/timeout excluded because ALL_DONE not found)
        cache_write "$kname" "$status" "$elapsed" "$rl"

        if [[ "$status" == "PASS" ]]; then
            ok "PASS  (${elapsed}s)  │  $summary"
        else
            fail "FAIL  (${elapsed}s)  │  $summary"
        fi
    else
        fail_reason="kernel panicked or serial lost"
        fail "$fail_reason"
        echo "  Last 5 lines:"; tail -5 "$log" | sed 's/^/    /'
        cache_write "$kname" "FAILED" "$elapsed" "reason=PANIC"
    fi

    echo -e "  ${DIM}log: $log${NC}"

    # Write result footer in log
    {
        echo ""
        echo "====================================================="
        echo " RESULT : $status  (${elapsed}s)"
        [[ -n "$fail_reason" ]] && echo " REASON : $fail_reason"
        echo "====================================================="
    } >> "$log"

    [[ "$status" == "PASS" ]] && return 0 || return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    banner "Falco Kernel Tests"

    for cmd in qemu-system-x86_64 cpio gzip; do
        command -v "$cmd" &>/dev/null || { fail "$cmd not found"; exit 1; }
    done

    [[ ! -f "$KERNELS_LIST" ]] && { fail "Not found: $KERNELS_LIST  (run ./sync_kernels.sh first)"; exit 1; }
    mkdir -p "$RESULTS_DIR"

    local total=0 passed=0 failed=0
    local -a summary_lines=()

    while IFS=: read -r distro version kernel_version; do
        [[ "$distro" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${distro// }" ]] && continue
        [[ -n "${DISTRO:-}" ]] && [[ "$distro" != "$DISTRO" ]] && continue
        [[ -n "${KERNEL_FILTER:-}" ]] && [[ "$kernel_version" != *"$KERNEL_FILTER"* ]] && continue
        [[ "$kernel_version" =~ ^[0-9] ]] || continue
        local kmaj; kmaj="$(cut -d. -f1 <<< "$kernel_version")"
        [[ -n "${MAX_KERNEL_MAJOR:-}" ]] && [[ "$kmaj" -gt "${MAX_KERNEL_MAJOR}" ]] && continue

        total=$((total + 1))
        if run_one_kernel "$distro" "$version" "$kernel_version"; then
            passed=$((passed + 1))
            summary_lines+=("  ${GREEN}PASS${NC}  ${distro}-${version}-${kernel_version}")
        else
            failed=$((failed + 1))
            local rlog="$RESULTS_DIR/${distro}-${version}-${kernel_version}.log"
            local reason=""
            [[ -f "$rlog" ]] && reason=$(grep "^ REASON" "$rlog" | sed 's/ REASON : //' || true)
            summary_lines+=("  ${RED}FAIL${NC}  ${distro}-${version}-${kernel_version}${reason:+  ($reason)}")
        fi

        [[ "${KERNEL_DELAY:-1}" -gt 0 ]] && sleep "${KERNEL_DELAY:-1}"
    done < "$KERNELS_LIST"

    # Final summary
    banner "Summary"
    for line in "${summary_lines[@]}"; do echo -e "$line"; done
    echo ""
    echo -e "  Total  : ${BOLD}$total${NC}"
    echo -e "  ${GREEN}Passed${NC} : $passed"
    echo -e "  ${RED}Failed${NC} : $failed"
    echo -e "  Logs   : $RESULTS_DIR/"
    echo ""

    [[ $failed -eq 0 ]] && return 0 || return 1
}

main "$@"
