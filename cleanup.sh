#!/bin/bash
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
step_info() { echo -e "  ${CYAN}→${NC} $*"; }

banner() {
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
}

show_usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [option]"
    echo ""
    echo "  all          Xóa toàn bộ (kernels, initramfs, results, base img)"
    echo "  kernels      Xóa thư mục kernels/ (vmlinuz đã tải)"
    echo "  initramfs    Xóa thư mục initramfs/ (per-kernel images)"
    echo "  base         Xóa initramfs-base.img"
    echo "  results      Xóa thư mục results/ (log files)"
    echo "  soft         Chỉ xóa initramfs/ và results/ (giữ kernels đã tải)"
    echo ""
    echo "  (không có option → hiện menu)"
    echo ""
}

show_disk_usage() {
    banner "Disk Usage"
    local items=(
        "$PROJECT_ROOT/initramfs-base.img"
        "$PROJECT_ROOT/kernels"
        "$PROJECT_ROOT/initramfs"
        "$PROJECT_ROOT/results"
    )
    for item in "${items[@]}"; do
        if [[ -e "$item" ]]; then
            local size
            size=$(du -sh "$item" 2>/dev/null | cut -f1)
            echo -e "  ${CYAN}$(basename "$item")${NC}  →  $size"
        else
            echo -e "  $(basename "$item")  →  (not found)"
        fi
    done
    echo ""
}

confirm() {
    local msg=$1
    echo -e "${YELLOW}  $msg${NC}"
    read -rp "  Xác nhận? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

do_clean() {
    local target=$1
    case "$target" in
        base)
            banner "Clean: Base initramfs"
            if [[ -f "$PROJECT_ROOT/initramfs-base.img" ]]; then
                confirm "Xóa initramfs-base.img?" || { echo "  Bỏ qua."; return; }
                rm -f "$PROJECT_ROOT/initramfs-base.img"
                step_ok "Đã xóa initramfs-base.img"
            else
                step_info "initramfs-base.img không tồn tại"
            fi
            ;;
        kernels)
            banner "Clean: Kernels"
            if [[ -d "$PROJECT_ROOT/kernels" ]]; then
                local count
                count=$(find "$PROJECT_ROOT/kernels" -name "vmlinuz" | wc -l)
                confirm "Xóa kernels/ ($count vmlinuz files)?" || { echo "  Bỏ qua."; return; }
                rm -rf "$PROJECT_ROOT/kernels"
                step_ok "Đã xóa kernels/"
            else
                step_info "kernels/ không tồn tại"
            fi
            ;;
        initramfs)
            banner "Clean: Per-kernel initramfs"
            if [[ -d "$PROJECT_ROOT/initramfs" ]]; then
                local count
                count=$(find "$PROJECT_ROOT/initramfs" -name "*.img" | wc -l)
                confirm "Xóa initramfs/ ($count img files)?" || { echo "  Bỏ qua."; return; }
                rm -rf "$PROJECT_ROOT/initramfs"
                step_ok "Đã xóa initramfs/"
            else
                step_info "initramfs/ không tồn tại"
            fi
            ;;
        results)
            banner "Clean: Results"
            if [[ -d "$PROJECT_ROOT/results" ]]; then
                local count
                count=$(find "$PROJECT_ROOT/results" -name "*.log" | wc -l)
                confirm "Xóa results/ ($count log files)?" || { echo "  Bỏ qua."; return; }
                rm -rf "$PROJECT_ROOT/results"
                step_ok "Đã xóa results/"
            else
                step_info "results/ không tồn tại"
            fi
            ;;
        soft)
            banner "Soft Clean (giữ kernels)"
            confirm "Xóa initramfs/ và results/ (giữ kernels đã tải)?" || { echo "  Bỏ qua."; return; }
            rm -rf "$PROJECT_ROOT/initramfs"
            rm -rf "$PROJECT_ROOT/results"
            step_ok "Đã xóa initramfs/ và results/"
            step_info "kernels/ giữ nguyên — chạy lại sẽ skip download"
            ;;
        all)
            banner "Full Clean"
            confirm "Xóa TẤT CẢ (kernels, initramfs, results, base img)?" || { echo "  Bỏ qua."; return; }
            rm -rf "$PROJECT_ROOT/kernels"
            rm -rf "$PROJECT_ROOT/initramfs"
            rm -rf "$PROJECT_ROOT/results"
            rm -f  "$PROJECT_ROOT/initramfs-base.img"
            step_ok "Đã xóa tất cả"
            ;;
        *)
            echo -e "${RED}  Unknown option: $target${NC}"
            show_usage
            exit 1
            ;;
    esac
}

interactive_menu() {
    banner "Cleanup Menu"
    echo -e "  ${BOLD}1${NC}  soft      — Xóa initramfs/ + results/  (giữ kernels)"
    echo -e "  ${BOLD}2${NC}  results   — Xóa results/ only"
    echo -e "  ${BOLD}3${NC}  initramfs — Xóa per-kernel initramfs/"
    echo -e "  ${BOLD}4${NC}  base      — Xóa initramfs-base.img"
    echo -e "  ${BOLD}5${NC}  kernels   — Xóa kernels/ (vmlinuz files)"
    echo -e "  ${BOLD}6${NC}  all       — Xóa tất cả"
    echo -e "  ${BOLD}q${NC}  quit"
    echo ""
    read -rp "  Chọn: " choice
    case "$choice" in
        1) do_clean soft ;;
        2) do_clean results ;;
        3) do_clean initramfs ;;
        4) do_clean base ;;
        5) do_clean kernels ;;
        6) do_clean all ;;
        q|Q) echo "  Thoát."; exit 0 ;;
        *) echo -e "${RED}  Lựa chọn không hợp lệ${NC}"; exit 1 ;;
    esac
}

# ── Main ──────────────────────────────────────────────────
show_disk_usage

if [[ -n "$1" ]]; then
    do_clean "$1"
else
    interactive_menu
fi

echo ""
show_disk_usage