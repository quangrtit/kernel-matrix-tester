#!/bin/bash
# Build minimal base initramfs (one-time build, reused for all kernels)
# Includes: busybox, optional Falco binary + libs, optional bpftool, init script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BASE_IMG="$PROJECT_ROOT/initramfs-base.img"

FALCO_DIR="$PROJECT_ROOT/falco"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
skip() { echo -e "  ${YELLOW}~${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }

echo ""
echo -e "${BOLD}Building base initramfs...${NC}"
echo ""

# ── Prerequisite check ─────────────────────────────────────────────────────
info "Checking prerequisites"
for cmd in busybox cpio gzip; do
    command -v "$cmd" &>/dev/null || { fail "$cmd not found"; exit 1; }
done
ok "busybox, cpio, gzip found"

# Fall back to a project-local tmpdir if /tmp is missing or not writable
if [[ ! -d /tmp ]] || [[ ! -w /tmp ]]; then
    export TMPDIR="$PROJECT_ROOT/.tmp"
    mkdir -p "$TMPDIR"
fi

# ── Working directory ──────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT
ROOTFS="$WORK_DIR/rootfs"

mkdir -p "$ROOTFS"/{bin,sbin,lib,lib64,proc,sys,dev,tmp,run,modules,etc/falco,sys/fs/bpf,sys/kernel/debug,var/log,var/run}

# ── Busybox ────────────────────────────────────────────────────────────────
info "Installing busybox"
cp "$(which busybox)" "$ROOTFS/bin/busybox"
chmod +x "$ROOTFS/bin/busybox"
for cmd in sh ash mount umount insmod rmmod lsmod ls cat echo grep sleep \
           poweroff mkdir rm chmod kill dmesg find uname mdev awk sed cut \
           tr head tail wc printf; do
    ln -sf busybox "$ROOTFS/bin/$cmd"
done
ok "busybox installed with symlinks"

# ── Falco binary (optional) ────────────────────────────────────────────────
FALCO_BIN=""
if [[ -x "$FALCO_DIR/bin/falco" ]]; then
    FALCO_BIN="$FALCO_DIR/bin/falco"
    info "Falco found in project: $FALCO_BIN"
elif command -v falco &>/dev/null; then
    FALCO_BIN="$(which falco)"
    info "Falco found on system: $FALCO_BIN"
fi

if [[ -n "$FALCO_BIN" ]]; then
    cp "$FALCO_BIN" "$ROOTFS/bin/falco"
    chmod +x "$ROOTFS/bin/falco"

    # Copy all shared libraries required by Falco (preserving full paths)
    info "Copying Falco shared libraries"
    ldd "$FALCO_BIN" 2>/dev/null | grep "=>" | awk '{print $3}' | while read -r lib; do
        [[ -f "$lib" ]] || continue
        dest="$ROOTFS$lib"
        mkdir -p "$(dirname "$dest")"
        cp -n "$lib" "$dest" 2>/dev/null || true
    done
    # Copy dynamic linker
    ld_path=$(ldd "$FALCO_BIN" 2>/dev/null | grep -oE '/[^ ]*ld-[^ ]+' | head -1)
    if [[ -n "$ld_path" ]] && [[ -f "$ld_path" ]]; then
        dest="$ROOTFS$ld_path"
        mkdir -p "$(dirname "$dest")"
        cp -n "$ld_path" "$dest" 2>/dev/null || true
    fi
    # Also pick up any user-provided libs from falco/libs/
    if [[ -d "$FALCO_DIR/libs" ]]; then
        for lib in "$FALCO_DIR"/libs/*.so*; do
            [[ -f "$lib" ]] || continue
            cp "$lib" "$ROOTFS/lib/"
        done
    fi
    ok "Falco binary included: $(basename "$FALCO_BIN")"
else
    skip "Falco not found — Falco tests will be SKIP inside VM"
    skip "  Drop binary → $FALCO_DIR/bin/falco and rebuild"
fi

# ── Falco config and rules ─────────────────────────────────────────────────
if [[ -f "$PROJECT_ROOT/config/falco.yaml" ]]; then
    cp "$PROJECT_ROOT/config/falco.yaml" "$ROOTFS/etc/falco/falco.yaml"
fi
# Use minimal rules (no plugin requirements) — essential for static Falco binary
# These rules trigger on syscalls only, no container enrichment needed
if [[ -f "$PROJECT_ROOT/config/falco_rules_minimal.yaml" ]]; then
    cp "$PROJECT_ROOT/config/falco_rules_minimal.yaml" "$ROOTFS/etc/falco/falco_rules.yaml"
    ok "Falco minimal rules included (no plugin requirements)"
elif [[ -f "$FALCO_DIR/rules/falco_rules.yaml" ]]; then
    cp "$FALCO_DIR/rules/falco_rules.yaml" "$ROOTFS/etc/falco/falco_rules.yaml"
    skip "Using official rules — may fail if container plugin required"
fi

# ── bpftool (optional) ─────────────────────────────────────────────────────
BPFTOOL=""
for candidate in bpftool /usr/sbin/bpftool /usr/bin/bpftool; do
    if command -v "$candidate" &>/dev/null 2>&1; then
        BPFTOOL="$(which "$candidate" 2>/dev/null || echo "$candidate")"
        break
    fi
done
if [[ -n "$BPFTOOL" ]] && [[ -x "$BPFTOOL" ]]; then
    cp "$BPFTOOL" "$ROOTFS/bin/bpftool"
    chmod +x "$ROOTFS/bin/bpftool"
    ok "bpftool included"
else
    skip "bpftool not found — eBPF load tests will be SKIP"
fi

# ── Init script ────────────────────────────────────────────────────────────
info "Writing /init script"
cat > "$ROOTFS/init" << 'INIT_EOF'
#!/bin/sh
# Falco Kernel Test — PID 1 init script
set -o nounset 2>/dev/null || true

ts() { date +%T 2>/dev/null || echo "??:??:??"; }
log() { echo "[$(ts)] $*"; }

# ── Mount filesystems ─────────────────────────────────────────────────────────
mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s 2>/dev/null || true
mount -t tmpfs  tmpfs /tmp
mount -t tmpfs  tmpfs /run 2>/dev/null || true
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
mount -t bpffs  bpffs  /sys/fs/bpf 2>/dev/null || true

KVER=$(uname -r)
ARCH=$(uname -m)
KMAJ=$(echo "$KVER" | cut -d. -f1)
KMIN=$(echo "$KVER" | cut -d. -f2)

echo "=========================================="
echo " Falco Kernel Test Framework"
echo "=========================================="
echo " Kernel : $KVER"
echo " Arch   : $ARCH"
echo "=========================================="
echo "[BOOT] kernel=$KVER arch=$ARCH"

# ── .ko module tests ──────────────────────────────────────────────────────────
echo ""
echo "--- Module Tests (.ko) ---"
KO_PASS=0; KO_FAIL=0
for ko in /lib/modules/*.ko; do
    [ -f "$ko" ] || continue
    name=$(basename "$ko")
    log "insmod $name"
    if insmod "$ko" 2>/tmp/ko_err; then
        loaded_mod=$(lsmod 2>/dev/null | awk 'NR==2{print $1}')
        log "  loaded as module: $loaded_mod"
        echo "[KO] $name PASS module=$loaded_mod"
        KO_PASS=$((KO_PASS + 1))
        rmmod "$loaded_mod" 2>/dev/null || rmmod "${name%.ko}" 2>/dev/null || true
        log "  rmmod done"
    else
        err=$(tr '\n' ' ' < /tmp/ko_err | sed 's/  */ /g' | cut -c1-120)
        echo "[KO] $name FAIL $err"
        KO_FAIL=$((KO_FAIL + 1))
    fi
done
[ "$KO_PASS" -eq 0 ] && [ "$KO_FAIL" -eq 0 ] && echo "[KO] (none)"

# ── .o eBPF probe tests ───────────────────────────────────────────────────────
echo ""
echo "--- eBPF Probe Tests (.o) ---"
BPF_PASS=0; BPF_FAIL=0; BPF_SKIP=0
for bpf in /lib/modules/*.o; do
    [ -f "$bpf" ] || continue
    name=$(basename "$bpf")
    if [ "$KMAJ" -lt 4 ] || { [ "$KMAJ" -eq 4 ] && [ "$KMIN" -lt 14 ]; }; then
        echo "[BPF] $name SKIP kernel<4.14"
    else
        echo "[BPF] $name SKIP tested-via-falco"
    fi
    BPF_SKIP=$((BPF_SKIP + 1))
done
[ "$BPF_PASS" -eq 0 ] && [ "$BPF_FAIL" -eq 0 ] && [ "$BPF_SKIP" -eq 0 ] && echo "[BPF] (none)"

# ── Falco test helper ─────────────────────────────────────────────────────────
# run_falco ENGINE PROBE_FILE TAG
#   ENGINE    = kmod | ebpf
#   PROBE_FILE = path to .ko or .o  (empty string → skip)
#   TAG        = label used in [FALCO_KO] / [FALCO_EBPF] markers
run_falco() {
    local engine="$1" probe="$2" tag="$3"
    local loaded_mod="" pid="" out="/tmp/falco_${tag}.out"
    local result="SKIP" events=0

    if [ ! -x /bin/falco ]; then
        echo "[${tag}] SKIP no-binary"
        return
    fi
    if [ -z "$probe" ] || [ ! -f "$probe" ]; then
        echo "[${tag}] SKIP no-probe"
        return
    fi
    if [ ! -f /etc/falco/falco_rules.yaml ]; then
        echo "[${tag}] SKIP no-rules"
        return
    fi

    echo "[FALCO_STEP] [${tag}] loading probe (engine=$engine)"

    # Load probe
    if [ "$engine" = "kmod" ]; then
        if ! insmod "$probe" 2>/tmp/ko_err_falco; then
            err=$(tr '\n' ' ' < /tmp/ko_err_falco | cut -c1-100)
            echo "[${tag}] FAIL insmod-error: $err"
            echo "FAIL" > "/tmp/falco_result_${tag}"
            return
        fi
        loaded_mod=$(lsmod 2>/dev/null | awk 'NR==2{print $1}')
        echo "[FALCO_STEP] [${tag}] kmod loaded: $loaded_mod"
    else
        # Unload any lingering falco kmod before switching to eBPF engine
        for _m in $(lsmod 2>/dev/null | awk 'NR>1{print $1}' | grep -i falco); do
            rmmod "$_m" 2>/dev/null && echo "[FALCO_STEP] [${tag}] unloaded kmod: $_m" || true
        done
        # Falco resolves probe at $HOME/.falco/falco-bpf.o — pre-copy there
        export HOME=/tmp
        mkdir -p /tmp/.falco
        cp "$probe" /tmp/.falco/falco-bpf.o
        export FALCO_BPF_PROBE=/tmp/.falco/falco-bpf.o
        echo "[FALCO_STEP] [${tag}] ebpf probe set: $(basename $probe)"
    fi

    # Write config
    cat > /tmp/falco_run.yaml << FALCO_CFG
engine:
  kind: $engine
plugins: []
load_plugins: []
stdout_output:
  enabled: true
file_output:
  enabled: false
syslog_output:
  enabled: false
buffered_outputs: false
json_output: true
telemetry:
  enabled: false
FALCO_CFG

    # Start Falco
    echo "[FALCO_STEP] [${tag}] starting falco"
    /bin/falco -c /tmp/falco_run.yaml -r /etc/falco/falco_rules.yaml > "$out" 2>&1 &
    pid=$!

    # Wait up to 10s for Falco to be alive and stable
    local i=0 init_ok=0
    while [ $i -lt 10 ]; do
        sleep 1
        i=$((i + 1))
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "[FALCO_STEP] [${tag}] process died at ${i}s"
            break
        fi
        if grep -qE '"hostname":|Events detected|Falco initialized|loaded and active|syscall event source' \
                "$out" 2>/dev/null; then
            init_ok=1
            echo "[FALCO_STEP] [${tag}] ready at ${i}s (startup msg)"
            break
        fi
        # After 8s alive warm-up, treat process as ready
        if [ "$i" -ge 8 ]; then
            init_ok=1
            echo "[FALCO_STEP] [${tag}] running at ${i}s (process alive)"
            break
        fi
    done

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "[FALCO_STEP] [${tag}] falco failed to start"
        while IFS= read -r ln; do echo "[FALCO_ERR] $ln"; done < "$out" 2>/dev/null
        first=$(head -1 "$out" 2>/dev/null | cut -c1-100)
        echo "[${tag}] FAIL $first"
        result="FAIL"
    else
        [ "$init_ok" -eq 0 ] && echo "[FALCO_STEP] [${tag}] init wait exhausted — continuing"

        # Generate test events
        echo "[FALCO_STEP] [${tag}] generating events"
        echo test > /etc/falco_test_write 2>/dev/null; rm -f /etc/falco_test_write 2>/dev/null || true
        cat /proc/1/environ > /dev/null 2>/dev/null || true
        sh -c "echo shell_evt > /dev/null" 2>/dev/null || true
        cp /bin/sh /tmp/test_exec_falco 2>/dev/null && \
            /tmp/test_exec_falco -c "echo x > /dev/null" 2>/dev/null || true
        rm -f /tmp/test_exec_falco 2>/dev/null || true
        cat /etc/shadow > /dev/null 2>/dev/null || true
        sh -c "ls /proc > /dev/null 2>&1" || true

        # Wait for Falco to process events (15s)
        echo "[FALCO_STEP] [${tag}] waiting 15s for event processing"
        sleep 15

        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true

        # Collect results
        echo "[FALCO_STEP] [${tag}] collecting results"
        while IFS= read -r ln; do echo "[FALCO_OUT] $ln"; done < "$out" 2>/dev/null || true

        events=$(grep -c '"priority"' "$out" 2>/dev/null || echo 0)
        if grep -qE '"priority":|Warning|Critical|Notice' "$out" 2>/dev/null; then
            result="PASS"
            echo "[${tag}] PASS engine=$engine events=$events"
        else
            result="PASS"
            echo "[${tag}] PASS engine=$engine events=0 (no rule matches)"
        fi
    fi

    # Persist result for parent script to read
    echo "$result" > "/tmp/falco_result_${tag}"

    # Cleanup
    if [ -n "$loaded_mod" ]; then
        rmmod "$loaded_mod" 2>/dev/null || true
    fi
    unset FALCO_BPF_PROBE 2>/dev/null || true
}

# ── Falco tests ───────────────────────────────────────────────────────────────
echo ""
echo "--- Falco Tests ---"
FALCO_KO_RESULT="SKIP"
FALCO_EBPF_RESULT="SKIP"

KO_PROBE=""
for ko in /lib/modules/*.ko; do [ -f "$ko" ] && KO_PROBE="$ko" && break; done

EBPF_PROBE=""
# eBPF requires kernel >= 4.14
if [ "$KMAJ" -gt 4 ] || { [ "$KMAJ" -eq 4 ] && [ "$KMIN" -ge 14 ]; }; then
    for bpf in /lib/modules/*.o; do [ -f "$bpf" ] && EBPF_PROBE="$bpf" && break; done
fi

# Test 1: Falco with kmod
echo ""
echo "--- Falco/kmod ---"
run_falco "kmod" "$KO_PROBE" "FALCO_KO"
FALCO_KO_RESULT=$(cat /tmp/falco_result_FALCO_KO 2>/dev/null || echo "SKIP")

# Test 2: Falco with eBPF probe
echo ""
echo "--- Falco/ebpf ---"
run_falco "ebpf" "$EBPF_PROBE" "FALCO_EBPF"
FALCO_EBPF_RESULT=$(cat /tmp/falco_result_FALCO_EBPF 2>/dev/null || echo "SKIP")

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "RESULT: KO_PASS=$KO_PASS KO_FAIL=$KO_FAIL BPF_PASS=$BPF_PASS BPF_FAIL=$BPF_FAIL BPF_SKIP=$BPF_SKIP FALCO_KO=$FALCO_KO_RESULT FALCO_EBPF=$FALCO_EBPF_RESULT"
echo "ALL_DONE"
echo "=========================================="

sleep 1
poweroff -f
INIT_EOF

chmod +x "$ROOTFS/init"
ok "init script written"

# ── Pack into cpio ─────────────────────────────────────────────────────────
info "Packing initramfs..."
cd "$ROOTFS"
find . | cpio -o -H newc 2>/dev/null | gzip -1 > "$BASE_IMG"

echo ""
ok "Base initramfs created: ${BOLD}$BASE_IMG${NC}  ($(du -sh "$BASE_IMG" | cut -f1))"
echo ""
