#!/bin/bash
# Clean build artifacts
#
# Usage:
#   ./clean.sh              — remove initramfs + results  (keep kernels/modules)
#   ./clean.sh --results    — remove only test logs
#   ./clean.sh --modules    — also remove Falco drivers (.ko/.o)
#   ./clean.sh --kernels    — also remove downloaded vmlinuz
#   ./clean.sh --all        — remove everything (kernels + modules + Falco binary)

set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
skip() { echo -e "  ${YELLOW}~${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }

rm_if() {
    if [[ -e "$1" ]]; then rm -rf "$1"; ok "Removed: $2"; else skip "Already gone: $2"; fi
}

rm_glob() {
    local files=(); while IFS= read -r f; do [[ -e "$f" ]] && files+=("$f"); done \
        < <(find "$PROJECT_ROOT" -path "$1" 2>/dev/null)
    if [[ ${#files[@]} -gt 0 ]]; then
        rm -rf "${files[@]}"
        ok "Removed ${#files[@]} × $2"
    else
        skip "Nothing to remove: $2"
    fi
}

MODE="default"
for arg in "$@"; do
    case "$arg" in
        --all)     MODE="all" ;;
        --kernels) MODE="kernels" ;;
        --modules) MODE="modules" ;;
        --results) MODE="results" ;;
    esac
done

echo ""
echo -e "${BOLD}Clean${NC}  (mode: ${BOLD}${MODE}${NC})"
echo ""

# Initramfs images (always, except --results only)
if [[ "$MODE" != "results" ]]; then
    info "Initramfs"
    rm_if  "$PROJECT_ROOT/initramfs-base.img"  "initramfs-base.img"
    rm_glob "*/initramfs/*.img"                 "initramfs/*.img"
fi

# Test results / logs
if [[ "$MODE" != "modules" ]] && [[ "$MODE" != "kernels" ]]; then
    info "Results / logs"
    rm_glob "*/results/*.log"  "results/*.log"
    rm_glob "*/results/*"      "results/* (dirs)"
fi

# Downloaded vmlinuz (--kernels or --all)
if [[ "$MODE" == "kernels" ]] || [[ "$MODE" == "all" ]]; then
    info "Kernels (vmlinuz)"
    rm_glob "*/kernels/*/vmlinuz"  "kernels/*/vmlinuz"
fi

# Falco drivers (--modules or --all)
if [[ "$MODE" == "modules" ]] || [[ "$MODE" == "all" ]]; then
    info "Falco drivers"
    rm_glob "*/modules/*/*.ko"  "modules/*/*.ko"
    rm_glob "*/modules/*/*.o"   "modules/*/*.o"
fi

# Falco binary (--all only)
if [[ "$MODE" == "all" ]]; then
    info "Falco binary"
    rm_if "$PROJECT_ROOT/falco/bin/falco"  "falco/bin/falco"
fi

echo ""
echo -e "  ${GREEN}Done.${NC}  Run ${BOLD}./setup.sh${NC} to rebuild."
echo ""
