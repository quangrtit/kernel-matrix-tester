#!/bin/bash
# Search and download Falco kernel drivers (.ko / .o) for a specific kernel
#
# Usage:
#   ./falco_drivers.sh <kernel_name> <uname_r>
#
# Example:
#   ./falco_drivers.sh centos-7-3.10.0-1160  3.10.0-1160.2.1.el7.x86_64
#
# Downloads to:  modules/<kernel_name>/falco_probe.ko
#                modules/<kernel_name>/falco_probe.o   (if available)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DRIVER_CONFIG="$PROJECT_ROOT/config/driver_server.yaml"

# Read driver server config (YAML field extraction via grep/sed — no deps needed)
_yaml_field() {
    local key="$1" file="$2"
    grep -m1 "^${key}:" "$file" 2>/dev/null | sed 's/^[^:]*: *//; s/ *#.*//' | tr -d '"'"'"
}

DEFAULT_BASE="https://d20hasrqv82i0q.cloudfront.net"
DEFAULT_LISTING="https://falco-distribution.s3-eu-west-1.amazonaws.com"
DEFAULT_VER="9.1.0+driver"

if [[ -f "$DRIVER_CONFIG" ]]; then
    BASE_URL="$(_yaml_field base_url "$DRIVER_CONFIG")"
    LISTING_BASE="$(_yaml_field listing_url "$DRIVER_CONFIG")"
    DRIVER_VERSION="$(_yaml_field driver_version "$DRIVER_CONFIG")"
fi
BASE_URL="${DRIVER_BASE_URL:-${BASE_URL:-$DEFAULT_BASE}}"
LISTING_BASE="${LISTING_BASE:-$DEFAULT_LISTING}"
DRIVER_VERSION="${DRIVER_VERSION:-$DEFAULT_VER}"

DRIVER_URL="${BASE_URL}/driver/${DRIVER_VERSION//+/%2B}/x86_64"
LISTING_URL="${LISTING_BASE}/?prefix=driver/${DRIVER_VERSION//+/%2B}/x86_64"

KERNEL_NAME="${1:-}"
UNAME_R="${2:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
skip() { echo -e "  ${YELLOW}~${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }

if [[ -z "$KERNEL_NAME" ]] || [[ -z "$UNAME_R" ]]; then
    echo "Usage: $0 <kernel_name> <uname_r>"
    echo ""
    echo "  kernel_name  — e.g. centos-7-3.10.0-1160"
    echo "  uname_r      — exact output of 'uname -r' inside the VM"
    echo "                 e.g. 3.10.0-1160.2.1.el7.x86_64"
    exit 1
fi

DISTRO=$(echo "$KERNEL_NAME" | cut -d- -f1)
OUT_DIR="$PROJECT_ROOT/modules/$KERNEL_NAME"
mkdir -p "$OUT_DIR"

# ── Map distro name to Falco's tag naming convention ─────────────────────────
# Determined empirically from the CloudFront listing.
declare -A DISTRO_TAGS
DISTRO_TAGS=(
    [ubuntu]="ubuntu-generic"
    [debian]="debian"
    [centos]="centos"
    [rocky]="rocky"
    [fedora]="fedora"
    [almalinux]="almalinux"
    [oracle]="oracle"
    [amazonlinux]="amazonlinux2"
    [minikube]="minikube"
)

FALCO_TAGS=()
# Try the mapped tag first, then common alternatives
primary="${DISTRO_TAGS[$DISTRO]:-$DISTRO}"
FALCO_TAGS+=("$primary")
# Add common fallbacks
[[ "$DISTRO" == "rocky" ]] && FALCO_TAGS+=("rhel" "fedora" "centos")
[[ "$DISTRO" == "centos" ]] && FALCO_TAGS+=("rhel")
[[ "$DISTRO" == "debian" ]] && FALCO_TAGS+=("ubuntu")

echo ""
echo -e "${BOLD}Searching Falco drivers for: ${KERNEL_NAME}${NC}"
echo -e "  uname -r : ${BOLD}${UNAME_R}${NC}"
echo -e "  distro   : ${DISTRO} → trying tags: ${FALCO_TAGS[*]}"
echo ""

# ── Search CloudFront for matching files ──────────────────────────────────────
search_driver() {
    local tag="$1" ext="$2"
    # Try revisions _1 through _3
    for rev in 1 2 3; do
        local name="falco_${tag}_${UNAME_R}_${rev}.${ext}"
        local url="${DRIVER_URL}/${name}"
        if curl -sf --head --max-time 10 "$url" > /dev/null 2>&1; then
            echo "$url $name"
            return 0
        fi
    done
    return 1
}

search_via_listing() {
    local tag="$1" ext="$2"
    local prefix="${LISTING_URL}/falco_${tag}_${UNAME_R}"
    local xml
    xml=$(curl -sf --max-time 15 "${prefix//+/%2B}" 2>/dev/null || true)
    local found
    found=$(echo "$xml" | grep -oE "falco_${tag}_[^<]+\.${ext}" | head -1)
    if [[ -n "$found" ]]; then
        echo "${DRIVER_URL}/${found} ${found}"
        return 0
    fi
    return 1
}

download_driver() {
    local url="$1" filename="$2" dest_name="$3"
    local dest="$OUT_DIR/$dest_name"
    if [[ -f "$dest" ]]; then
        skip "Already present: $dest"
        return 0
    fi
    info "Downloading ${filename} ..."
    if curl -L --progress-bar --max-time 120 --retry 2 \
            -o "$dest" "$url" 2>&1; then
        # Verify file is valid (not an XML error page)
        if file "$dest" 2>/dev/null | grep -qE "ELF|data"; then
            ok "→ $dest  ($(du -sh "$dest" | cut -f1))"
            return 0
        else
            rm -f "$dest"
            fail "Downloaded file appears invalid (not ELF/data): $filename"
            return 1
        fi
    else
        rm -f "$dest"
        fail "Download failed: $url"
        return 1
    fi
}

# ── Try each distro tag for .ko and .o ───────────────────────────────────────
KO_FOUND=0
O_FOUND=0

for tag in "${FALCO_TAGS[@]}"; do
    if [[ $KO_FOUND -eq 0 ]]; then
        info "Searching .ko  tag=falco_${tag}_${UNAME_R}..."
        result=$(search_via_listing "$tag" "ko" 2>/dev/null) || \
        result=$(search_driver "$tag" "ko" 2>/dev/null) || true
        if [[ -n "$result" ]]; then
            url=$(echo "$result" | awk '{print $1}')
            fname=$(echo "$result" | awk '{print $2}')
            download_driver "$url" "$fname" "falco_probe.ko" && KO_FOUND=1
        fi
    fi

    if [[ $O_FOUND -eq 0 ]]; then
        # eBPF only supported on kernel >= 4.14
        KMAJ=$(echo "$UNAME_R" | cut -d. -f1)
        KMIN=$(echo "$UNAME_R" | cut -d. -f2)
        if [[ "$KMAJ" -lt 4 ]] || { [[ "$KMAJ" -eq 4 ]] && [[ "$KMIN" -lt 14 ]]; }; then
            skip ".o probe skipped — kernel ${UNAME_R} < 4.14, no eBPF support"
            O_FOUND=-1  # mark as N/A
            break
        fi

        info "Searching .o   tag=falco_${tag}_${UNAME_R}..."
        result=$(search_via_listing "$tag" "o" 2>/dev/null) || \
        result=$(search_driver "$tag" "o" 2>/dev/null) || true
        if [[ -n "$result" ]]; then
            url=$(echo "$result" | awk '{print $1}')
            fname=$(echo "$result" | awk '{print $2}')
            download_driver "$url" "$fname" "falco_probe.o" && O_FOUND=1
        fi
    fi

    [[ $KO_FOUND -eq 1 ]] && [[ $O_FOUND -ne 0 ]] && break
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Result for ${KERNEL_NAME}${NC}"
[[ $KO_FOUND -eq 1 ]]  && ok ".ko → $OUT_DIR/falco_probe.ko" || skip ".ko not found for ${UNAME_R}"
[[ $O_FOUND  -eq 1 ]]  && ok ".o  → $OUT_DIR/falco_probe.o"  || true
[[ $O_FOUND  -eq  0 ]] && [[ "$KMAJ" -ge 4 ]] && skip ".o not found for ${UNAME_R}"
echo ""

if [[ $KO_FOUND -eq 0 ]] && [[ $O_FOUND -le 0 ]]; then
    echo -e "  ${YELLOW}No drivers found.${NC} The Falco test for this kernel will show SKIP."
    echo "  To add support, compile the probe for kernel ${UNAME_R} and place at:"
    echo "    $OUT_DIR/falco_probe.ko"
    exit 1
fi

exit 0
