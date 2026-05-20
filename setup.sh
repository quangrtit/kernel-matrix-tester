#!/bin/bash
# Full pipeline: Falco binary + base initramfs + sync kernels + run tests
#
# Usage:
#   ./setup.sh                      # everything
#   ./setup.sh centos               # centos kernels only
#   ./setup.sh --sync-only          # sync kernels, no boot tests

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADER_DIR="$PROJECT_ROOT/downloader"
BUILDER_DIR="$PROJECT_ROOT/builder"

SYNC_ONLY=0
PASS_ARGS=()
for arg in "$@"; do
    [[ "$arg" == "--sync-only" ]] && SYNC_ONLY=1 || PASS_ARGS+=("$arg")
done

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; BLUE='\033[0;34m'; NC='\033[0m'
banner() { echo ""; echo -e "${BOLD}${BLUE}══ $* ══${NC}"; echo ""; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
banner "Prerequisites"
missing=0
for cmd in qemu-system-x86_64 curl cpio gzip busybox rpm2cpio python3; do
    command -v "$cmd" &>/dev/null && ok "$cmd" || { fail "$cmd — not found"; missing=1; }
done
[[ $missing -eq 1 ]] && { fail "Install missing packages"; exit 1; }
[[ -e /dev/kvm ]] && ok "KVM available" || echo -e "  ~ KVM not available (will run slower)"

# ── Falco binary ──────────────────────────────────────────────────────────────
banner "Falco binary"
if [[ -x "$PROJECT_ROOT/falco/bin/falco" ]]; then
    ok "Already present: falco/bin/falco"
else
    bash "$DOWNLOADER_DIR/falco_binary.sh"
fi

# ── Base initramfs ────────────────────────────────────────────────────────────
banner "Base initramfs"
BASE_IMG="$PROJECT_ROOT/initramfs-base.img"
REBUILD=0
[[ ! -f "$BASE_IMG" ]] && REBUILD=1
if [[ $REBUILD -eq 0 ]]; then
    BASE_MT=$(stat -c %Y "$BASE_IMG" 2>/dev/null || echo 0)
    for src in "$BUILDER_DIR/build_base.sh" "$PROJECT_ROOT/falco/bin/falco" \
               "$PROJECT_ROOT/config/falco.yaml" "$PROJECT_ROOT/config/falco_rules_minimal.yaml"; do
        [[ -f "$src" ]] || continue
        SRC_MT=$(stat -c %Y "$src" 2>/dev/null || echo 0)
        [[ $SRC_MT -gt $BASE_MT ]] && REBUILD=1 && break
    done
fi
if [[ $REBUILD -eq 1 ]]; then
    rm -f "$BASE_IMG"
    bash "$BUILDER_DIR/build_base.sh" || { fail "Base initramfs build failed"; exit 1; }
else
    ok "Already up-to-date  ($(du -sh "$BASE_IMG" | cut -f1))"
fi

# ── Sync kernel images ────────────────────────────────────────────────────────
bash "$PROJECT_ROOT/sync_kernels.sh" "${PASS_ARGS[@]+"${PASS_ARGS[@]}"}"

[[ $SYNC_ONLY -eq 1 ]] && { echo ""; echo "(--sync-only: skipping boot tests)"; exit 0; }

# ── Run tests ─────────────────────────────────────────────────────────────────
bash "$PROJECT_ROOT/run_tests.sh" "${PASS_ARGS[@]+"${PASS_ARGS[@]}"}"
