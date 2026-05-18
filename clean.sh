#!/bin/bash
# Clean build artifacts for Falco Kernel Test Framework
#
# Usage:
#   ./clean.sh              — remove initramfs images + logs  (keep kernels/modules)
#   ./clean.sh --all        — remove everything re-buildable/re-downloadable
#   ./clean.sh --kernels    — also remove downloaded vmlinuz files
#   ./clean.sh --modules    — also remove downloaded Falco drivers (.ko/.o)
#   ./clean.sh --results    — remove only test logs/results

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
skip() { echo -e "  ${YELLOW}~${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }

rm_if() {
    local target="$1" label="$2"
    if [[ -e "$target" ]]; then
        rm -rf "$target"
        ok "Removed: $label"
    else
        skip "Already gone: $label"
    fi
}

rm_glob() {
    local pattern="$1" label="$2"
    local count
    # Use find to handle empty glob safely
    count=$(find $pattern -maxdepth 0 2>/dev/null | wc -l || echo 0)
    if [[ "$count" -gt 0 ]]; then
        rm -rf $pattern
        ok "Removed $count × $label"
    else
        skip "Nothing to remove: $label"
    fi
}

MODE="default"
[[ "${1:-}" == "--all"     ]] && MODE="all"
[[ "${1:-}" == "--kernels" ]] && MODE="kernels"
[[ "${1:-}" == "--modules" ]] && MODE="modules"
[[ "${1:-}" == "--results" ]] && MODE="results"

echo ""
echo -e "${BOLD}Falco Kernel Test — Clean${NC}  (mode: ${BOLD}${MODE}${NC})"
echo ""

# ── Always: initramfs images ──────────────────────────────────────────────────
if [[ "$MODE" != "results" ]]; then
    info "Initramfs images"
    rm_if  "$PROJECT_ROOT/initramfs-base.img"     "initramfs-base.img"
    rm_glob "$PROJECT_ROOT/initramfs/*.img"        "initramfs/*.img"
fi

# ── Always (except --modules/--kernels only): results ────────────────────────
if [[ "$MODE" != "modules" ]] && [[ "$MODE" != "kernels" ]]; then
    info "Test results / logs"
    rm_glob "$PROJECT_ROOT/results/*.log"          "results/*.log"
fi

# ── --kernels / --all: downloaded vmlinuz ─────────────────────────────────────
if [[ "$MODE" == "kernels" ]] || [[ "$MODE" == "all" ]]; then
    info "Downloaded kernels (vmlinuz)"
    rm_glob "$PROJECT_ROOT/kernels/*/vmlinuz"      "kernels/*/vmlinuz"
fi

# ── --modules / --all: downloaded drivers ─────────────────────────────────────
if [[ "$MODE" == "modules" ]] || [[ "$MODE" == "all" ]]; then
    info "Downloaded Falco drivers (.ko / .o)"
    rm_glob "$PROJECT_ROOT/modules/*/*.ko"         "modules/*/*.ko"
    rm_glob "$PROJECT_ROOT/modules/*/*.o"          "modules/*/*.o"
fi

# ── --all: also remove Falco binary (will re-download on next setup) ──────────
if [[ "$MODE" == "all" ]]; then
    info "Falco binary"
    rm_if  "$PROJECT_ROOT/falco/bin/falco"         "falco/bin/falco"
fi

echo ""
echo -e "  ${GREEN}Done.${NC}  Run ${BOLD}./setup.sh${NC} to rebuild and re-run tests."
echo ""
