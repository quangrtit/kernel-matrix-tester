#!/bin/bash
# Crawl distro package repos and collect exact kernel version strings.
# Writes to config/kernels.list (use --dry-run to print instead).
#
# Output format: distro:release:kernel_version
# where kernel_version is the exact string from the RPM/deb filename,
# e.g. centos:8:4.18.0-147.8.1.el8_1  or  ubuntu:mainline:5.15.45
#
# These exact strings are then used by the downloader scripts to build
# direct package URLs without guessing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNELS_LIST="${SCRIPT_DIR}/config/kernels.list"
DRY_RUN=false
DISTROS=()

log()  { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]

Crawl distro repos and populate config/kernels.list with exact kernel names.

Options:
  --distro DISTRO    Only fetch: centos, almalinux, rocky, ubuntu, debian
                     (repeat for multiple, default = all)
  --dry-run          Print to stdout, do not write kernels.list
  --output FILE      Write to FILE instead of config/kernels.list
  -h, --help         Show help

Examples:
  $(basename "$0")                          # Fetch all distros
  $(basename "$0") --distro centos          # CentOS only
  $(basename "$0") --distro centos --distro almalinux --dry-run
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --distro)  DISTROS+=("$2"); shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --output)  KERNELS_LIST="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) warn "Unknown option: $1"; usage ;;
    esac
done

[[ ${#DISTROS[@]} -eq 0 ]] && DISTROS=(centos almalinux rocky ubuntu debian)

fetch_index() {
    curl -sfL --max-time 30 "$1" 2>/dev/null || true
}

# ── CentOS via vault.centos.org ───────────────────────────────────────────────
# el8: vault.centos.org/{8.N.YYYY}/BaseOS/x86_64/os/Packages/  — kernel-core-*
# el7: vault.centos.org/{7.N.YYYY}/{os,updates}/x86_64/Packages/ — kernel-*
# el6: vault.centos.org/centos/{6.N}/{os,updates}/x86_64/Packages/ — kernel-*
fetch_centos() {
    log "Fetching CentOS kernel list from vault.centos.org ..."
    local -A seen=()

    # CentOS 8 releases
    for rel in 8.0.1905 8.1.1911 8.2.2004 8.3.2011 8.4.2105 8.5.2111; do
        local url="https://vault.centos.org/${rel}/BaseOS/x86_64/os/Packages/"
        log "  el8 ${rel}"
        local idx; idx=$(fetch_index "$url")
        [[ -z "$idx" ]] && { warn "  unreachable: ${rel}"; continue; }
        while IFS= read -r ver; do
            [[ -n "${seen[$ver]:-}" ]] && continue
            seen["$ver"]=1
            echo "centos:8:${ver}"
        done < <(printf '%s\n' "$idx" \
            | grep -oE 'kernel-core-[0-9][^"<[:space:]]+\.x86_64\.rpm' \
            | grep -v 'devel\|debug\|modules-core\|modules-extra\|modules-internal' \
            | sed 's/^kernel-core-//; s/\.x86_64\.rpm$//' \
            | sort -uV)
    done

    # CentOS 7 releases — kernel lives in /os/ and update kernels in /updates/
    for rel in 7.0.1406 7.1.1503 7.2.1511 7.3.1611 7.4.1708 7.5.1804 7.6.1810 7.7.1908 7.8.2003 7.9.2009; do
        for repo in os updates; do
            local url="https://vault.centos.org/${rel}/${repo}/x86_64/Packages/"
            log "  el7 ${rel}/${repo}"
            local idx; idx=$(fetch_index "$url")
            [[ -z "$idx" ]] && continue
            while IFS= read -r ver; do
                [[ -n "${seen[$ver]:-}" ]] && continue
                seen["$ver"]=1
                echo "centos:7:${ver}"
            done < <(printf '%s\n' "$idx" \
                | grep -oE 'kernel-[0-9][^"<[:space:]]+\.x86_64\.rpm' \
                | grep -v 'devel\|debug\|headers\|tools\|core\|abi\|doc\|bootupdater\|cross\|modules' \
                | sed 's/^kernel-//; s/\.x86_64\.rpm$//' \
                | sort -uV)
        done
    done

    # CentOS 6 releases
    for rel in 6.0 6.1 6.2 6.3 6.4 6.5 6.6 6.7 6.8 6.9 6.10; do
        for repo in os updates; do
            local url="https://vault.centos.org/centos/${rel}/${repo}/x86_64/Packages/"
            log "  el6 ${rel}/${repo}"
            local idx; idx=$(fetch_index "$url")
            [[ -z "$idx" ]] && continue
            while IFS= read -r ver; do
                [[ -n "${seen[$ver]:-}" ]] && continue
                seen["$ver"]=1
                echo "centos:6:${ver}"
            done < <(printf '%s\n' "$idx" \
                | grep -oE 'kernel-[0-9][^"<[:space:]]+\.x86_64\.rpm' \
                | grep -v 'devel\|debug\|headers\|tools\|core\|abi\|doc\|modules\|firmware' \
                | sed 's/^kernel-//; s/\.x86_64\.rpm$//' \
                | sort -uV)
        done
    done
}

# ── AlmaLinux via repo.almalinux.org/vault ────────────────────────────────────
# vault/{8.N}/BaseOS/x86_64/os/Packages/ — kernel-core-*
fetch_almalinux() {
    log "Fetching AlmaLinux kernel list from repo.almalinux.org/vault ..."
    local -A seen=()

    for rel in 8.4 8.5 8.6 8.7 8.8 8.9 8.10; do
        local url="https://repo.almalinux.org/vault/${rel}/BaseOS/x86_64/os/Packages/"
        log "  al8 ${rel}"
        local idx; idx=$(fetch_index "$url")
        [[ -z "$idx" ]] && { warn "  unreachable: ${rel}"; continue; }
        while IFS= read -r ver; do
            [[ -n "${seen[$ver]:-}" ]] && continue
            seen["$ver"]=1
            echo "almalinux:8:${ver}"
        done < <(printf '%s\n' "$idx" \
            | grep -oE 'kernel-core-[0-9][^"<[:space:]]+\.x86_64\.rpm' \
            | grep -v 'devel\|debug\|modules' \
            | sed 's/^kernel-core-//; s/\.x86_64\.rpm$//' \
            | sort -uV)
    done

    for rel in 9.0 9.1 9.2 9.3 9.4 9.5; do
        local url="https://repo.almalinux.org/vault/${rel}/BaseOS/x86_64/os/Packages/"
        log "  al9 ${rel}"
        local idx; idx=$(fetch_index "$url")
        [[ -z "$idx" ]] && { warn "  unreachable: ${rel}"; continue; }
        while IFS= read -r ver; do
            [[ -n "${seen[$ver]:-}" ]] && continue
            seen["$ver"]=1
            echo "almalinux:9:${ver}"
        done < <(printf '%s\n' "$idx" \
            | grep -oE 'kernel-core-[0-9][^"<[:space:]]+\.x86_64\.rpm' \
            | grep -v 'devel\|debug\|modules' \
            | sed 's/^kernel-core-//; s/\.x86_64\.rpm$//' \
            | sort -uV)
    done
}

# ── Rocky Linux via dl.rockylinux.org ────────────────────────────────────────
# vault/rocky/{8.N}/BaseOS/x86_64/os/Packages/k/  — kernel-core-*
# pub/rocky/{8,9}/BaseOS/x86_64/os/Packages/k/   — current kernels
fetch_rocky() {
    log "Fetching Rocky Linux kernel list from dl.rockylinux.org ..."
    local -A seen=()

    # Rocky 8 vault
    for rel in 8.3 8.4 8.5 8.6 8.7 8.8 8.9 8.10; do
        local url="https://dl.rockylinux.org/vault/rocky/${rel}/BaseOS/x86_64/os/Packages/k/"
        log "  rocky8 vault ${rel}"
        local idx; idx=$(fetch_index "$url")
        [[ -z "$idx" ]] && continue
        while IFS= read -r ver; do
            [[ -n "${seen[$ver]:-}" ]] && continue
            seen["$ver"]=1
            echo "rocky:8:${ver}"
        done < <(printf '%s\n' "$idx" \
            | grep -oE 'kernel-core-[0-9][^"<[:space:]]+\.x86_64\.rpm' \
            | grep -v 'devel\|debug\|modules' \
            | sed 's/^kernel-core-//; s/\.x86_64\.rpm$//' \
            | sort -uV)
    done

    # Rocky 8 current pub
    local url8="https://dl.rockylinux.org/pub/rocky/8/BaseOS/x86_64/os/Packages/k/"
    log "  rocky8 pub"
    local idx8; idx8=$(fetch_index "$url8")
    if [[ -n "$idx8" ]]; then
        while IFS= read -r ver; do
            [[ -n "${seen[$ver]:-}" ]] && continue
            seen["$ver"]=1
            echo "rocky:8:${ver}"
        done < <(printf '%s\n' "$idx8" \
            | grep -oE 'kernel-core-[0-9][^"<[:space:]]+\.x86_64\.rpm' \
            | grep -v 'devel\|debug\|modules' \
            | sed 's/^kernel-core-//; s/\.x86_64\.rpm$//' \
            | sort -uV)
    fi

    # Rocky 9 vault
    for rel in 9.0 9.1 9.2 9.3 9.4 9.5; do
        local url="https://dl.rockylinux.org/vault/rocky/${rel}/BaseOS/x86_64/os/Packages/k/"
        log "  rocky9 vault ${rel}"
        local idx; idx=$(fetch_index "$url")
        [[ -z "$idx" ]] && continue
        while IFS= read -r ver; do
            [[ -n "${seen[$ver]:-}" ]] && continue
            seen["$ver"]=1
            echo "rocky:9:${ver}"
        done < <(printf '%s\n' "$idx" \
            | grep -oE 'kernel-core-[0-9][^"<[:space:]]+\.x86_64\.rpm' \
            | grep -v 'devel\|debug\|modules' \
            | sed 's/^kernel-core-//; s/\.x86_64\.rpm$//' \
            | sort -uV)
    done

    # Rocky 9 current pub
    local url9="https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/k/"
    log "  rocky9 pub"
    local idx9; idx9=$(fetch_index "$url9")
    if [[ -n "$idx9" ]]; then
        while IFS= read -r ver; do
            [[ -n "${seen[$ver]:-}" ]] && continue
            seen["$ver"]=1
            echo "rocky:9:${ver}"
        done < <(printf '%s\n' "$idx9" \
            | grep -oE 'kernel-core-[0-9][^"<[:space:]]+\.x86_64\.rpm' \
            | grep -v 'devel\|debug\|modules' \
            | sed 's/^kernel-core-//; s/\.x86_64\.rpm$//' \
            | sort -uV)
    fi
}

# ── Ubuntu mainline via kernel.ubuntu.com/mainline ────────────────────────────
# Lists available version directories (one HTTP request, no subdirectory scan).
# kernels.list format: ubuntu:mainline:5.15.45
# ubuntu.sh fetches: kernel.ubuntu.com/mainline/v5.15.45/
fetch_ubuntu() {
    log "Fetching Ubuntu mainline kernel list from kernel.ubuntu.com/mainline ..."
    local idx; idx=$(fetch_index "https://kernel.ubuntu.com/mainline/")
    [[ -z "$idx" ]] && { warn "  unreachable"; return; }

    printf '%s\n' "$idx" \
        | grep -oE '"v[0-9]+\.[0-9]+\.[0-9]+/"' \
        | tr -d '"' | sed 's|^v||; s|/$||' \
        | sort -uV \
        | while IFS= read -r ver; do
            echo "ubuntu:mainline:${ver}"
        done
}

# ── Debian via deb.debian.org pool ───────────────────────────────────────────
# kernels.list format: debian:stable:5.10.0-30-amd64
# debian.sh expects version like "5.10.0-30-amd64" and finds linux-image-<ver>_*_amd64.deb
fetch_debian() {
    log "Fetching Debian kernel list from deb.debian.org ..."
    local url="http://deb.debian.org/debian/pool/main/l/linux/"
    local idx; idx=$(fetch_index "$url")
    [[ -z "$idx" ]] && { warn "  unreachable"; return; }

    printf '%s\n' "$idx" \
        | grep -oE 'linux-image-[0-9][^_"<]+_[^"<]+_amd64\.deb' \
        | grep -v 'dbg\|cloud\|rt' \
        | grep -oE 'linux-image-[0-9][0-9.]*-[0-9]+-amd64' \
        | sed 's/^linux-image-//' \
        | sort -uV \
        | while IFS= read -r ver; do
            echo "debian:stable:${ver}"
        done
}

# ── Main ──────────────────────────────────────────────────────────────────────
TMPOUT=$(mktemp)
trap "rm -f $TMPOUT" EXIT

{
    echo "# Falco Kernel Test Matrix — auto-generated $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "# Format: distro:release:kernel_version"
    echo "#"
    echo "# kernel_version is the EXACT string from the RPM/deb filename."
    echo "# Downloaders use this to construct direct package URLs."
    echo "# Regenerate with: ./fetch_kernel_list.sh [--distro NAME]"
    echo ""

    for distro in "${DISTROS[@]}"; do
        printf '# =========================\n# %s\n# =========================\n\n' "$distro"
        case "$distro" in
            centos)    fetch_centos    ;;
            almalinux) fetch_almalinux ;;
            rocky)     fetch_rocky     ;;
            ubuntu)    fetch_ubuntu    ;;
            debian)    fetch_debian    ;;
            *) warn "Unknown distro: $distro" ;;
        esac
        echo ""
    done
} > "$TMPOUT"

if $DRY_RUN; then
    cat "$TMPOUT"
else
    cp "$TMPOUT" "$KERNELS_LIST"
    NENTRIES=$(grep -cE '^[^#[:space:]]' "$KERNELS_LIST" || echo 0)
    log "Written ${NENTRIES} entries to $KERNELS_LIST"
fi
