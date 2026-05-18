#!/bin/bash
# Download Falco binary + rules from CloudFront packages repository
# Driver version 3.0.0+driver → use Falco binary 0.35.1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

CLOUDFRONT_BASE="https://d20hasrqv82i0q.cloudfront.net"
PACKAGES_URL="${CLOUDFRONT_BASE}/packages/bin/x86_64"

# This binary version matches driver API 9.1.0+driver
# If you change the driver version URL in falco_drivers.sh, update this too.
FALCO_VERSION="${1:-0.43.1}"

FALCO_BIN_DIR="$PROJECT_ROOT/falco/bin"
FALCO_RULES_DIR="$PROJECT_ROOT/falco/rules"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; exit 1; }
skip() { echo -e "  ${YELLOW}~${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }

echo ""
echo -e "${BOLD}Downloading Falco binary v${FALCO_VERSION}...${NC}"
echo ""

# ── Already present? ─────────────────────────────────────────────────────────
if [[ -x "$FALCO_BIN_DIR/falco" ]]; then
    skip "Already present: $FALCO_BIN_DIR/falco  (remove to re-download)"
    exit 0
fi

# ── Determine tarball name (try static first, then regular) ──────────────────
TARBALL_NAME=""
for candidate in "falco-${FALCO_VERSION}-static-x86_64.tar.gz" "falco-${FALCO_VERSION}-x86_64.tar.gz"; do
    info "Probing ${PACKAGES_URL}/${candidate} ..."
    if curl -sf --head --max-time 10 "${PACKAGES_URL}/${candidate}" > /dev/null 2>&1; then
        TARBALL_NAME="$candidate"
        ok "Found: $candidate"
        break
    fi
done

if [[ -z "$TARBALL_NAME" ]]; then
    # Fall back to listing and picking the closest version
    info "Exact version not found — scanning package listing for closest match..."
    LISTING=$(curl -sf --max-time 30 "${CLOUDFRONT_BASE}/?prefix=packages/bin/x86_64/falco-${FALCO_VERSION%.*}" 2>/dev/null || true)
    TARBALL_NAME=$(echo "$LISTING" | grep -oE "falco-[0-9.]+-x86_64\.tar\.gz" | grep -v "static" | sort -V | tail -1)
    [[ -z "$TARBALL_NAME" ]] && fail "Cannot find Falco ${FALCO_VERSION} tarball at ${PACKAGES_URL}"
    ok "Using closest match: $TARBALL_NAME"
fi

# ── Download ─────────────────────────────────────────────────────────────────
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

DOWNLOAD_URL="${PACKAGES_URL}/${TARBALL_NAME}"
info "Downloading ${TARBALL_NAME} ..."
info "URL: ${DOWNLOAD_URL}"

if ! curl -L --progress-bar --max-time 300 --retry 3 \
     -o "$TEMP_DIR/falco.tar.gz" "$DOWNLOAD_URL"; then
    fail "Download failed: $DOWNLOAD_URL"
fi

# ── Extract ───────────────────────────────────────────────────────────────────
info "Extracting tarball..."
mkdir -p "$TEMP_DIR/extract"
tar -xzf "$TEMP_DIR/falco.tar.gz" -C "$TEMP_DIR/extract" 2>/dev/null || \
    { fail "tar extraction failed — is the download complete?"; }

# ── Find and copy Falco binary ────────────────────────────────────────────────
FALCO_ELF=$(find "$TEMP_DIR/extract" -name "falco" -type f -not -name "*.conf" 2>/dev/null | head -1)
if [[ -z "$FALCO_ELF" ]]; then
    echo "  Contents of extracted tarball:"
    find "$TEMP_DIR/extract" -maxdepth 4 | sed 's/^/    /'
    fail "Cannot find 'falco' binary in tarball"
fi

mkdir -p "$FALCO_BIN_DIR"
cp "$FALCO_ELF" "$FALCO_BIN_DIR/falco"
chmod +x "$FALCO_BIN_DIR/falco"
ok "Falco binary → $FALCO_BIN_DIR/falco  ($(du -sh "$FALCO_BIN_DIR/falco" | cut -f1))"

# ── Find and copy rules ───────────────────────────────────────────────────────
mkdir -p "$FALCO_RULES_DIR"

RULES_FILE=$(find "$TEMP_DIR/extract" -name "falco_rules.yaml" -type f 2>/dev/null | head -1)
if [[ -n "$RULES_FILE" ]]; then
    cp "$RULES_FILE" "$FALCO_RULES_DIR/falco_rules.yaml"
    ok "falco_rules.yaml → $FALCO_RULES_DIR/"
else
    skip "falco_rules.yaml not found in tarball — using project default"
fi

# Copy falco.yaml only if we don't have a custom one
FALCO_YAML=$(find "$TEMP_DIR/extract" -name "falco.yaml" -type f 2>/dev/null | head -1)
if [[ -n "$FALCO_YAML" ]] && [[ ! -f "$PROJECT_ROOT/config/falco.yaml" ]]; then
    cp "$FALCO_YAML" "$PROJECT_ROOT/config/falco.yaml"
    ok "falco.yaml → config/falco.yaml"
fi

echo ""
ok "Done. Next: run  bash builder/build_base.sh  to include Falco in initramfs."
echo ""
