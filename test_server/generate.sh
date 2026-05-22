#!/bin/bash
# Generate fake .ko and .o driver files for every kernel in kernels.list.
# Files contain a minimal ELF header so the downloader's file-type check passes.
# Usage: ./generate.sh   (run from test_server/ or project root)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNELS_LIST="$SCRIPT_DIR/../config/kernels.list"
OUT_DIR="$SCRIPT_DIR"

# Minimal ELF magic (8 bytes) — enough for `file` to report "ELF"
FAKE_ELF=$(printf '\x7fELF\x02\x01\x01\x00')

count_ko=0 count_o=0

while IFS=: read -r distro _release kernel_version; do
    [[ "$distro" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${distro// }" ]] && continue

    base="falco_${distro}_${kernel_version}_x86_64"

    # .ko — always
    ko="$OUT_DIR/${base}.ko"
    if [[ ! -f "$ko" ]]; then
        printf '\x7fELF\x02\x01\x01\x00' > "$ko"
        count_ko=$((count_ko + 1))
    fi

    # .o — only for kernel >= 4.14
    kmaj=$(cut -d. -f1 <<< "$kernel_version")
    kmin=$(cut -d. -f2 <<< "$kernel_version")
    if [[ "$kmaj" =~ ^[0-9]+$ ]] && \
       { [[ "$kmaj" -gt 4 ]] || { [[ "$kmaj" -eq 4 ]] && [[ "$kmin" -ge 14 ]]; }; }; then
        o="$OUT_DIR/${base}.o"
        if [[ ! -f "$o" ]]; then
            printf '\x7fELF\x02\x01\x01\x00' > "$o"
            count_o=$((count_o + 1))
        fi
    fi
done < "$KERNELS_LIST"

echo "Generated: $count_ko .ko  |  $count_o .o  →  $OUT_DIR"
echo "Total files: $(ls "$OUT_DIR"/*.ko "$OUT_DIR"/*.o 2>/dev/null | wc -l)"
