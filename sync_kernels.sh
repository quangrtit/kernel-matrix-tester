#!/bin/bash
# Sync kernel vmlinuz images from distro repos.
#
# For each distro: crawl repo → find packages → download → extract vmlinuz
# → save to kernels/{name}/vmlinuz → register in config/kernels.list
#
# Usage:
#   ./sync_kernels.sh                    # all distros
#   ./sync_kernels.sh centos almalinux   # specific distros
#   ./sync_kernels.sh --dry-run          # preview only (no download)

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADER_DIR="$PROJECT_ROOT/downloader"
KERNELS_DIR="$PROJECT_ROOT/kernels"
KERNELS_LIST="$PROJECT_ROOT/config/kernels.list"

DRY_RUN=0
TEST_MODE="${TEST_MODE:-0}"                 # 1 = limit to MAX_PER_MAJOR per distro×major group
MAX_PER_MAJOR="${MAX_PER_MAJOR:-20}"        # kernels to keep per group in TEST_MODE
MAX_KERNEL_MAJOR="${MAX_KERNEL_MAJOR:-5}"   # skip kernels with major version > this
SELECTED=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --*)       ;;
        *)         SELECTED+=("$arg") ;;
    esac
done

# Fall back to a project-local tmpdir if /tmp is missing or not writable
if [[ ! -d /tmp ]] || [[ ! -w /tmp ]]; then
    export TMPDIR="$PROJECT_ROOT/.tmp"
    mkdir -p "$TMPDIR"
fi

ALL_DISTROS=(centos almalinux rocky ubuntu debian oracle redhat)
[[ ${#SELECTED[@]} -gt 0 ]] && RUN_DISTROS=("${SELECTED[@]}") || RUN_DISTROS=("${ALL_DISTROS[@]}")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
skip() { echo -e "  ${YELLOW}~${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }

# ── vmlinuz extraction ────────────────────────────────────────────────────────

extract_rpm() {
    local pkg="$1" dest="$2"
    local tmp; tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN
    (cd "$tmp" && rpm2cpio "$pkg" | cpio -id --quiet 2>/dev/null || true)
    local v
    v=$(find "$tmp" -name "vmlinuz*" -type f ! -name "*rescue*" ! -name "*debug*" 2>/dev/null | head -1)
    [[ -n "$v" ]] && cp "$v" "$dest"
}

extract_deb() {
    local pkg="$1" dest="$2"
    local tmp; tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN
    (cd "$tmp" && ar x "$pkg" 2>/dev/null) || return 1
    local data_tar
    data_tar=$(ls "$tmp"/data.tar* 2>/dev/null | head -1)
    [[ -n "$data_tar" ]] && tar -xf "$data_tar" -C "$tmp" --wildcards "*/boot/vmlinuz*" 2>/dev/null || true
    local v
    v=$(find "$tmp" -name "vmlinuz*" -type f 2>/dev/null | head -1)
    [[ -n "$v" ]] && cp "$v" "$dest"
}

# ── Parse distro:release:version from a package URL ───────────────────────────

parse_entry() {
    local distro="$1" url="$2"
    local f; f=$(basename "$url")
    local version release

    case "$distro" in
        centos)
            if [[ "$f" == kernel-core-* ]]; then
                version="${f#kernel-core-}"; version="${version%.x86_64.rpm}"
                release=$(echo "$version" | grep -oP '\.el\K[0-9]' || true); release="${release:-8}"
            else
                version="${f#kernel-}"; version="${version%.x86_64.rpm}"
                release=$(echo "$version" | grep -oP '\.el\K[0-9]' || true); release="${release:-7}"
            fi ;;
        almalinux|rocky)
            version="${f#kernel-core-}"; version="${version%.x86_64.rpm}"
            release=$(echo "$version" | grep -oP '\.el\K[0-9]+' || true); release="${release:-8}" ;;
        ubuntu)
            # linux-image-5.4.0-195-generic_5.4.0-195.215_amd64.deb → 5.4.0-195-generic
            # linux-image-unsigned-5.15.0-119-generic_..._amd64.deb → 5.15.0-119-generic
            version="${f#linux-image-unsigned-}"
            version="${version#linux-image-}"
            version="${version%%_*}"
            # derive release label from ABI version (e.g. 5.4 → focal, 5.15 → jammy)
            local major_minor; major_minor=$(echo "$version" | grep -oP '^[0-9]+\.[0-9]+' || true)
            case "$major_minor" in
                3.13) release="trusty"  ;;
                4.4)  release="xenial"  ;;
                4.15) release="bionic"  ;;
                5.0)  release="disco"   ;;
                5.3)  release="eoan"    ;;
                5.4)  release="focal"   ;;
                5.8)  release="groovy"  ;;
                5.11) release="hirsute" ;;
                5.13) release="impish"  ;;
                5.15) release="jammy"   ;;
                5.19) release="kinetic" ;;
                6.2)  release="lunar"   ;;
                6.5)  release="mantic"  ;;
                6.8)  release="noble"   ;;
                6.11) release="oracular";;
                *)    release="ubuntu"  ;;
            esac ;;
        debian)
            # linux-image-5.10.0-43-amd64-unsigned_5.10.251-5_amd64.deb → 5.10.0-43-amd64
            version="${f#linux-image-}"
            version="${version%%_*}"
            version="${version%-unsigned}"
            local deb_major_minor; deb_major_minor=$(echo "$version" | grep -oP '^[0-9]+\.[0-9]+' || true)
            case "$deb_major_minor" in
                2.6)  release="squeeze"  ;;
                3.2)  release="wheezy"   ;;
                3.16) release="jessie"   ;;
                4.9)  release="stretch"  ;;
                4.19) release="buster"   ;;
                5.10) release="bullseye" ;;
                6.1)  release="bookworm" ;;
                *)    release="debian"   ;;
            esac ;;
        oracle)
            # Handles: kernel-*, kernel-core-*, kernel-uek-*, kernel-uek-core-*
            if [[ "$f" == kernel-uek-core-* ]]; then
                version="${f#kernel-uek-core-}"; version="${version%.x86_64.rpm}"
            elif [[ "$f" == kernel-uek-* ]]; then
                version="${f#kernel-uek-}"; version="${version%.x86_64.rpm}"
            elif [[ "$f" == kernel-core-* ]]; then
                version="${f#kernel-core-}"; version="${version%.x86_64.rpm}"
            else
                version="${f#kernel-}"; version="${version%.x86_64.rpm}"
            fi
            local ol_major; ol_major=$(echo "$version" | grep -oP '\.el\K[0-9]+' || true)
            release="${ol_major:+OL${ol_major}}"; release="${release:-oracle}" ;;
        redhat)
            # CDN URLs may carry query params — strip before basename
            local clean_url="${url%%\?*}"
            f=$(basename "$clean_url")
            version="${f#kernel-}"; version="${version%.x86_64.rpm}"
            local rh_major; rh_major=$(echo "$version" | grep -oP '\.el\K[0-9]+' || true)
            release="${rh_major:+rhel${rh_major}}"; release="${release:-rhel}" ;;
        *) return 1 ;;
    esac

    [[ -n "${version:-}" ]] && echo "${distro}:${release}:${version}" || return 1
}

# ── Register entry in kernels.list (idempotent) ───────────────────────────────

register() {
    local entry="$1"
    grep -qxF "$entry" "$KERNELS_LIST" 2>/dev/null && return 0
    echo "$entry" >> "$KERNELS_LIST"
}

# ── Process one package URL ───────────────────────────────────────────────────

process_url() {
    local distro="$1" url="$2"

    local entry
    entry=$(parse_entry "$distro" "$url") || { fail "Cannot parse: $(basename "$url")"; return 0; }

    local version release
    version=$(cut -d: -f3 <<< "$entry")
    release=$(cut -d: -f2 <<< "$entry")
    local kmaj; kmaj=$(cut -d. -f1 <<< "$version")
    if [[ -n "${MAX_KERNEL_MAJOR:-}" ]] && [[ "$kmaj" =~ ^[0-9]+$ ]] && [[ "$kmaj" -gt "$MAX_KERNEL_MAJOR" ]]; then
        return 0
    fi
    local kname="${distro}-${release}-${version}"
    local dest="$KERNELS_DIR/${kname}/vmlinuz"

    if [[ -f "$dest" ]]; then
        skip "$kname  (cached)"
        register "$entry"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY] $kname ← $(basename "$url")"
        return 0
    fi

    info "↓ $kname ..."

    local tmp_pkg tmp_vmlinuz
    tmp_pkg=$(mktemp)
    tmp_vmlinuz=$(mktemp)
    trap "rm -f '$tmp_pkg' '$tmp_vmlinuz'" RETURN

    if ! curl -fL --max-time 600 --retry 3 --retry-delay 5 \
            --speed-limit 1024 --speed-time 60 \
            -o "$tmp_pkg" "$url" 2>/dev/null; then
        fail "Download failed: $url"
        return 1
    fi

    local f; f=$(basename "$url")
    if [[ "$f" == *.rpm ]]; then
        extract_rpm "$tmp_pkg" "$tmp_vmlinuz"
    else
        extract_deb "$tmp_pkg" "$tmp_vmlinuz"
    fi

    if [[ ! -s "$tmp_vmlinuz" ]]; then
        fail "vmlinuz extract failed: $f"
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    mv "$tmp_vmlinuz" "$dest"

    ok "$kname  ($(du -sh "$dest" | cut -f1))"
    register "$entry"
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Ensure kernels.list exists
if [[ ! -f "$KERNELS_LIST" ]]; then
    mkdir -p "$(dirname "$KERNELS_LIST")"
    printf '# Falco Kernel Test Matrix\n# Format: distro:release:kernel_version\n\n' > "$KERNELS_LIST"
fi

echo ""
_mode_tags=""
[[ $DRY_RUN -eq 1 ]]  && _mode_tags+="  (dry-run)"
[[ $TEST_MODE -eq 1 ]] && _mode_tags+="  (test-mode: max ${MAX_PER_MAJOR} per major)"
echo -e "${BOLD}Sync kernel images${NC}  [${RUN_DISTROS[*]}]${_mode_tags}"
echo ""

ERRORS=0
for distro in "${RUN_DISTROS[@]}"; do
    crawler="$DOWNLOADER_DIR/${distro}/crawler.py"
    if [[ ! -f "$crawler" ]]; then
        fail "$distro — crawler not found: $crawler"; continue
    fi

    echo -e "${BOLD}━━━ ${distro} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # RedHat uses its own producer-consumer pipeline (CDN auth + async resolve+download)
    if [[ "$distro" == "redhat" ]]; then
        info "Authenticating with Red Hat SSO ..."
        dry_flag=(); [[ $DRY_RUN -eq 1 ]] && dry_flag=(--dry-run)
        python3 "$crawler" --download \
            --kernels-dir "$KERNELS_DIR" \
            --kernels-list "$KERNELS_LIST" \
            --max-major "${MAX_KERNEL_MAJOR}" \
            "${dry_flag[@]}" \
            || ERRORS=$((ERRORS + 1))
        echo ""
        continue
    fi

    info "Crawling ..."

    mapfile -t urls < <(python3 "$crawler" --list --verbose | sort -u)

    if [[ ${#urls[@]} -eq 0 ]]; then
        fail "No packages found (repo unreachable?)"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    if [[ $TEST_MODE -eq 1 ]]; then
        mapfile -t urls < <(printf '%s\n' "${urls[@]}" | \
            python3 "$DOWNLOADER_DIR/filter_urls.py" --distro "$distro" --max "$MAX_PER_MAJOR")
        echo -e "  found ${#urls[@]} packages (test mode, max ${MAX_PER_MAJOR} per major)"
    else
        echo -e "  found ${#urls[@]} packages"
    fi
    echo ""

    for url in "${urls[@]}"; do
        process_url "$distro" "$url" || ERRORS=$((ERRORS + 1))
    done
    echo ""
done

[[ $ERRORS -gt 0 ]] && { fail "Finished with $ERRORS error(s)"; exit 1; } || echo -e "${GREEN}All done.${NC}"
