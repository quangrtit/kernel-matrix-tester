#!/bin/bash
# Download CentOS/RHEL kernel vmlinuz from vault.centos.org
#
# Accepts the EXACT kernel version string as found in the RPM filename.
# Use fetch_kernel_list.sh to populate config/kernels.list with valid names.
#
# Supported EL versions:
#   el8 / el8_N  → vault.centos.org/{8.N.YYYY}/BaseOS/  (kernel-core RPM)
#   el7          → vault.centos.org/{7.N.YYYY}/{os,updates}/  (kernel RPM)
#   el6          → vault.centos.org/centos/{6.N}/{os,updates}/ (kernel RPM)
set -uo pipefail

KERNEL_VER="${1:-}"
OUTPUT_DIR="${2:-}"

if [[ -z "$KERNEL_VER" ]] || [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <kernel_version> <output_dir>"
    echo ""
    echo "Examples (use exact strings from vault RPM filenames):"
    echo "  $0 4.18.0-147.8.1.el8_1     ./kernels/centos-8-4.18.0-147.8.1.el8_1"
    echo "  $0 4.18.0-240.22.el8         ./kernels/centos-8-4.18.0-240.22.el8"
    echo "  $0 3.10.0-1160.108.1.el7     ./kernels/centos-7-3.10.0-1160.108.1.el7"
    echo "  $0 2.6.32-754.35.1.el6       ./kernels/centos-6-2.6.32-754.35.1.el6"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# ── Detect EL version ─────────────────────────────────────────────────────────
if [[ "$KERNEL_VER" =~ \.el8(_[0-9]+)? ]]; then
    EL="el8"
elif [[ "$KERNEL_VER" =~ \.el7 ]]; then
    EL="el7"
elif [[ "$KERNEL_VER" =~ \.el6 ]]; then
    EL="el6"
elif [[ "$KERNEL_VER" =~ ^4\.18\. ]]; then
    EL="el8"
elif [[ "$KERNEL_VER" =~ ^3\.10\. ]]; then
    EL="el7"
elif [[ "$KERNEL_VER" =~ ^2\.6\. ]]; then
    EL="el6"
else
    echo "✗ Cannot detect EL version from: $KERNEL_VER"
    exit 1
fi

echo "CentOS ${EL} — kernel: $KERNEL_VER"

# ── el8: map sub-minor to vault release path ──────────────────────────────────
# el8_N encodes which CentOS 8 point release the package came from.
el8_vault() {
    local minor="$1"
    case "$minor" in
        0) echo "8.0.1905" ;;
        1) echo "8.1.1911" ;;
        2) echo "8.2.2004" ;;
        3) echo "8.3.2011" ;;
        4) echo "8.4.2105" ;;
        5) echo "8.5.2111" ;;
        *) echo ""         ;;
    esac
}

# ── el7: map kernel patch level to CentOS 7 vault release ────────────────────
# Each CentOS 7.x ships a specific base kernel; updates go to /updates/.
el7_vault_and_repo() {
    local kver="$1"
    local patch
    patch=$(echo "$kver" | grep -oE -- '-[0-9]+' | head -1 | tr -d -)

    local release
    if   [[ $patch -ge 1160 ]]; then release="7.9.2009"
    elif [[ $patch -ge 1127 ]]; then release="7.8.2003"
    elif [[ $patch -ge 1062 ]]; then release="7.7.1908"
    elif [[ $patch -ge 957  ]]; then release="7.6.1810"
    elif [[ $patch -ge 862  ]]; then release="7.5.1804"
    elif [[ $patch -ge 693  ]]; then release="7.4.1708"
    elif [[ $patch -ge 514  ]]; then release="7.3.1611"
    elif [[ $patch -ge 327  ]]; then release="7.2.1511"
    elif [[ $patch -ge 229  ]]; then release="7.1.1503"
    else                              release="7.0.1406"
    fi

    # Sub-patch present (e.g. "3.10.0-1160.108.1.el7") → update package
    if echo "$kver" | grep -qE '\-[0-9]+\.[0-9]+\.[0-9]+.*el7'; then
        echo "${release} updates"
    else
        echo "${release} os"
    fi
}

# ── Build candidate URL list ──────────────────────────────────────────────────
CANDIDATE_URLS=()

case "$EL" in
    el8)
        RPM="kernel-core-${KERNEL_VER}.x86_64.rpm"
        echo "Searching for: $RPM"

        # Extract el8 sub-minor (el8_1 → 1, el8 → empty)
        EL8_MINOR=$(echo "$KERNEL_VER" | grep -oP '\.el8_\K[0-9]+' || true)

        if [[ -n "$EL8_MINOR" ]]; then
            vault=$(el8_vault "$EL8_MINOR")
            if [[ -n "$vault" ]]; then
                CANDIDATE_URLS+=("https://vault.centos.org/${vault}/BaseOS/x86_64/os/Packages/${RPM}")
            fi
        fi
        # Fallback: all el8 vaults newest-first
        for v in 8.5.2111 8.4.2105 8.3.2011 8.2.2004 8.1.1911 8.0.1905; do
            CANDIDATE_URLS+=("https://vault.centos.org/${v}/BaseOS/x86_64/os/Packages/${RPM}")
        done
        ;;

    el7)
        RPM="kernel-${KERNEL_VER}.x86_64.rpm"
        echo "Searching for: $RPM"

        # Primary candidate from patch-level heuristic
        read -r prim_release prim_repo < <(el7_vault_and_repo "$KERNEL_VER")
        CANDIDATE_URLS+=("https://vault.centos.org/${prim_release}/${prim_repo}/x86_64/Packages/${RPM}")

        # Fallback: all 7.x vaults, both repos
        for v in 7.9.2009 7.8.2003 7.7.1908 7.6.1810 7.5.1804 7.4.1708 7.3.1611 7.2.1511 7.1.1503 7.0.1406; do
            for repo in updates os; do
                CANDIDATE_URLS+=("https://vault.centos.org/${v}/${repo}/x86_64/Packages/${RPM}")
            done
        done
        # Symlink paths
        for repo in updates os; do
            CANDIDATE_URLS+=("https://vault.centos.org/centos/7/${repo}/x86_64/Packages/${RPM}")
        done
        ;;

    el6)
        RPM="kernel-${KERNEL_VER}.x86_64.rpm"
        echo "Searching for: $RPM"
        for v in 6.10 6.9 6.8 6.7 6.6 6.5 6.4 6.3 6.2 6.1 6.0; do
            for repo in updates os; do
                CANDIDATE_URLS+=("https://vault.centos.org/centos/${v}/${repo}/x86_64/Packages/${RPM}")
            done
        done
        ;;
esac

# ── Try each candidate (exit on first hit) ────────────────────────────────────
DOWNLOAD_URL=""
for url in "${CANDIDATE_URLS[@]}"; do
    echo "  Trying: $url"
    if curl -sf --head --max-time 10 "$url" > /dev/null 2>&1; then
        DOWNLOAD_URL="$url"
        echo "  ✓ Found"
        break
    fi
done

if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "✗ Cannot find RPM for kernel $KERNEL_VER ($EL)"
    echo "  RPM searched: $RPM"
    echo ""
    echo "  Tip: run ./fetch_kernel_list.sh --distro centos --dry-run to list valid names"
    exit 1
fi

# ── Download RPM ──────────────────────────────────────────────────────────────
echo "Downloading $(basename "$DOWNLOAD_URL") ..."
curl -L --progress-bar --max-time 300 --retry 3 \
     -o "$TEMP_DIR/kernel.rpm" "$DOWNLOAD_URL"

if [[ ! -s "$TEMP_DIR/kernel.rpm" ]]; then
    echo "✗ Download failed or file empty"
    exit 1
fi

# ── Extract vmlinuz ───────────────────────────────────────────────────────────
cd "$TEMP_DIR"
rpm2cpio kernel.rpm | cpio -id --quiet 2>/dev/null || true

VMLINUZ=$(find "$TEMP_DIR" -name "vmlinuz*" -type f 2>/dev/null \
          | grep -v "rescue\|debug" | head -1 || true)

if [[ -z "$VMLINUZ" ]]; then
    echo "✗ vmlinuz not found in RPM"
    find "$TEMP_DIR" -name "vmlinuz*" 2>/dev/null | head -5 || true
    exit 1
fi

cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "✓ vmlinuz → $OUTPUT_DIR/vmlinuz  ($(du -sh "$OUTPUT_DIR/vmlinuz" | cut -f1))"
