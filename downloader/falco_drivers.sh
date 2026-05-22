#!/bin/bash
# Download Falco kernel drivers (.ko / .o) for a specific kernel.
#
# Usage:
#   ./falco_drivers.sh <kernel_name> <uname_r>
#
# Example:
#   ./falco_drivers.sh centos-7-3.10.0-1160  3.10.0-1160.2.1.el7.x86_64
#
# Saves to:  modules/falco_{distro}_{kernel_version}_x86_64.ko
#            modules/falco_{distro}_{kernel_version}_x86_64.o
#
# Resolution order:
#   1. Custom server (server_url in config/driver_server.yaml)
#   2. Falco CloudFront CDN (fallback)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DRIVER_CONFIG="$PROJECT_ROOT/config/driver_server.yaml"
MODULES_DIR="$PROJECT_ROOT/modules"
mkdir -p "$MODULES_DIR"

_yaml_field() {
    local key="$1" file="$2"
    grep -m1 "^${key}:" "$file" 2>/dev/null | sed 's/^[^:]*: *//; s/ *#.*//' | tr -d '"'"'"
}

SERVER_URL="" FALLBACK_URL="" LISTING_BASE="" DRIVER_VERSION=""
if [[ -f "$DRIVER_CONFIG" ]]; then
    SERVER_URL="$(_yaml_field server_url    "$DRIVER_CONFIG")"
    FALLBACK_URL="$(_yaml_field fallback_url "$DRIVER_CONFIG")"
    LISTING_BASE="$(_yaml_field listing_url  "$DRIVER_CONFIG")"
    DRIVER_VERSION="$(_yaml_field driver_version "$DRIVER_CONFIG")"
fi
SERVER_URL="${DRIVER_SERVER_URL:-${SERVER_URL:-}}"
FALLBACK_URL="${FALLBACK_URL:-https://d20hasrqv82i0q.cloudfront.net}"
LISTING_BASE="${LISTING_BASE:-https://falco-distribution.s3-eu-west-1.amazonaws.com}"
DRIVER_VERSION="${DRIVER_VERSION:-9.1.0+driver}"

FALLBACK_DRIVER_URL="${FALLBACK_URL}/driver/${DRIVER_VERSION//+/%2B}/x86_64"
LISTING_URL="${LISTING_BASE}/?prefix=driver/${DRIVER_VERSION//+/%2B}/x86_64"

KERNEL_NAME="${1:-}"
UNAME_R="${2:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
skip() { echo -e "  ${YELLOW}~${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }

if [[ -z "$KERNEL_NAME" ]] || [[ -z "$UNAME_R" ]]; then
    echo "Usage: $0 <kernel_name> <uname_r>"
    echo "  kernel_name — e.g. centos-7-3.10.0-1160"
    echo "  uname_r     — e.g. 3.10.0-1160.2.1.el7.x86_64"
    exit 1
fi

# Parse distro and kernel_version from kname (format: distro-release-kernel_version)
DISTRO=$(cut -d- -f1 <<< "$KERNEL_NAME")
KERNEL_VERSION=$(cut -d- -f3- <<< "$KERNEL_NAME")
ARCH="x86_64"
MODULE_BASE="falco_${DISTRO}_${KERNEL_VERSION}_${ARCH}"
KO_DEST="$MODULES_DIR/${MODULE_BASE}.ko"
O_DEST="$MODULES_DIR/${MODULE_BASE}.o"

echo ""
echo -e "${BOLD}Falco drivers: ${MODULE_BASE}${NC}"
echo -e "  uname -r : ${BOLD}${UNAME_R}${NC}"
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────

download_file() {
    local url="$1" dest="$2"
    if curl -fL --progress-bar --max-time 120 --retry 2 -o "$dest" "$url" 2>&1; then
        if file "$dest" 2>/dev/null | grep -qE "ELF|data"; then
            return 0
        fi
        rm -f "$dest"
        fail "Downloaded file is not ELF/data: $url"
        return 1
    fi
    rm -f "$dest"
    return 1
}

# Try HEAD + download from a URL; returns 0 on success
try_url() {
    local url="$1" dest="$2"
    curl -sf --head --max-time 10 "$url" > /dev/null 2>&1 || return 1
    download_file "$url" "$dest"
}

# ── 1. Custom server ──────────────────────────────────────────────────────────

try_custom_server() {
    local ext="$1" dest="$2"
    [[ -z "$SERVER_URL" ]] && return 1
    local url="${SERVER_URL}/${MODULE_BASE}.${ext}"
    info "[custom] ${MODULE_BASE}.${ext} ..."
    try_url "$url" "$dest"
}

# ── 2. Falco CloudFront fallback ──────────────────────────────────────────────

declare -A DISTRO_TAGS
DISTRO_TAGS=([ubuntu]="ubuntu-generic" [debian]="debian" [centos]="centos"
             [rocky]="rocky" [fedora]="fedora" [almalinux]="almalinux"
             [oracle]="oracle" [amazonlinux]="amazonlinux2" [minikube]="minikube")

_cdn_tags() {
    local primary="${DISTRO_TAGS[$DISTRO]:-$DISTRO}"
    echo "$primary"
    [[ "$DISTRO" == "rocky"  ]] && echo -e "rhel\nfedora\ncentos"
    [[ "$DISTRO" == "centos" ]] && echo "rhel"
    [[ "$DISTRO" == "debian" ]] && echo "ubuntu"
}

search_cdn() {
    local tag="$1" ext="$2"
    # Try S3 listing first (handles any revision suffix)
    local prefix="${LISTING_URL}/falco_${tag}_${UNAME_R}"
    local xml found
    xml=$(curl -sf --max-time 15 "${prefix//+/%2B}" 2>/dev/null || true)
    found=$(echo "$xml" | grep -oE "falco_${tag}_[^<]+\.${ext}" | head -1)
    if [[ -n "$found" ]]; then
        echo "${FALLBACK_DRIVER_URL}/${found}"
        return 0
    fi
    # Try revisions _1 _2 _3 directly
    for rev in 1 2 3; do
        local url="${FALLBACK_DRIVER_URL}/falco_${tag}_${UNAME_R}_${rev}.${ext}"
        if curl -sf --head --max-time 10 "$url" > /dev/null 2>&1; then
            echo "$url"
            return 0
        fi
    done
    return 1
}

try_cdn() {
    local ext="$1" dest="$2"
    while IFS= read -r tag; do
        info "[cdn] falco_${tag}_${UNAME_R} .${ext} ..."
        local url
        url=$(search_cdn "$tag" "$ext" 2>/dev/null) || continue
        download_file "$url" "$dest" && return 0
    done < <(_cdn_tags)
    return 1
}

# ── Download .ko ──────────────────────────────────────────────────────────────

KO_OK=0
if [[ -f "$KO_DEST" ]]; then
    skip ".ko already present"
    KO_OK=1
elif try_custom_server "ko" "$KO_DEST"; then
    ok ".ko ← custom server  ($(du -sh "$KO_DEST" | cut -f1))"
    KO_OK=1
elif try_cdn "ko" "$KO_DEST"; then
    ok ".ko ← cdn  ($(du -sh "$KO_DEST" | cut -f1))"
    KO_OK=1
else
    skip ".ko not found"
fi

# ── Download .o (eBPF — kernel >= 4.14 only) ──────────────────────────────────

O_OK=0
KMAJ=$(cut -d. -f1 <<< "$UNAME_R")
KMIN=$(cut -d. -f2 <<< "$UNAME_R")

if ! { [[ "$KMAJ" -gt 4 ]] || { [[ "$KMAJ" -eq 4 ]] && [[ "$KMIN" -ge 14 ]]; }; }; then
    skip ".o skipped — ${UNAME_R} < 4.14, no eBPF support"
    O_OK=-1
elif [[ -f "$O_DEST" ]]; then
    skip ".o already present"
    O_OK=1
elif try_custom_server "o" "$O_DEST"; then
    ok ".o ← custom server  ($(du -sh "$O_DEST" | cut -f1))"
    O_OK=1
elif try_cdn "o" "$O_DEST"; then
    ok ".o ← cdn  ($(du -sh "$O_DEST" | cut -f1))"
    O_OK=1
else
    skip ".o not found"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
if [[ $KO_OK -eq 0 ]] && [[ $O_OK -le 0 ]]; then
    echo -e "  ${YELLOW}No drivers found.${NC} Falco tests for this kernel will SKIP."
    echo "  To add: place falco drivers at:"
    echo "    $KO_DEST"
    exit 1
fi
exit 0
