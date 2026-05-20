#!/usr/bin/env python3
"""
Generic kernel package crawler for the Falco kernel test matrix.

Reads a YAML config and crawls the specified repository, downloading
vmlinuz kernel images needed for QEMU boot testing.

Usage:
    python3 crawl.py <config.yaml> [--dry-run] [--list]
    python3 crawl.py downloader/configs/centos.yaml --dry-run
    python3 crawl.py downloader/configs/almalinux.yaml --list

Config fields (top-level, shared across all jobs):
    title               - Human-readable description
    download_folder     - Local directory for downloaded packages
    group               - Distro group label (centos, almalinux, rocky, debian, ubuntu)
    start_url           - Default root URL (can be overridden per job)
    base_url            - (optional) Base for resolving relative links
    folder_patterns     - Default folder navigation patterns (can be overridden per job)
    file_patterns       - Default file match patterns (can be overridden per job)
    jobs                - (optional) List of named sub-crawls, each may override:
                            name, start_url, base_url, folder_patterns, file_patterns,
                            link_pattern, extract_link_from_index

Single-job configs (no 'jobs' key) are also supported for backwards compatibility.
"""
import re
import sys
import os
import argparse
import time
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError
from urllib.parse import urljoin, urlparse, urlunparse
from html.parser import HTMLParser

try:
    import yaml
except ImportError:
    sys.exit("Error: PyYAML not found. Install with:  pip3 install pyyaml  or  apt install python3-yaml")

USER_AGENT = "kernel-matrix-tester-crawler/1.0"
FETCH_TIMEOUT = 30      # seconds for index pages
DOWNLOAD_TIMEOUT = 300  # seconds for package files
RETRY_WAIT = 3          # seconds between retries
MAX_RETRIES = 3


# ── HTML link extractor ───────────────────────────────────────────────────────

class _LinkParser(HTMLParser):
    def __init__(self, base_url: str):
        super().__init__()
        self.base_url = base_url
        # Each entry: (name, href, full_url, is_dir)
        # name  = last path component of href (filename or dirname)
        # href  = raw href attribute value (relative or absolute)
        # full_url = href resolved against base_url
        # is_dir   = href ends with /
        self.links: list[tuple[str, str, str, bool]] = []

    def handle_starttag(self, tag, attrs):
        if tag != "a":
            return
        attrs = dict(attrs)
        href = attrs.get("href", "").strip()
        if not href or href.startswith("#") or href in ("..", "../"):
            return
        if href.startswith("?"):  # Apache sort links
            return
        # Skip non-HTTP schemes (rsync://, ftp://, mailto:, etc.)
        if "://" in href and not href.startswith(("http://", "https://")):
            return
        is_dir = href.endswith("/")
        full_url = urljoin(self.base_url, href)
        name = href.rstrip("/").split("/")[-1]
        self.links.append((name, href, full_url, is_dir))


def _fetch(url: str, timeout: int = FETCH_TIMEOUT) -> str:
    req = Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            with urlopen(req, timeout=timeout) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except HTTPError as e:
            if e.code == 404:
                return ""   # silently skip missing paths
            if attempt == MAX_RETRIES:
                raise
        except (URLError, OSError):
            if attempt == MAX_RETRIES:
                raise
        time.sleep(RETRY_WAIT)
    return ""


def _get_links(url: str, base_url: str | None = None) -> list[tuple[str, str, str, bool]]:
    html = _fetch(url)
    if not html:
        return []
    parser = _LinkParser(base_url or url)
    parser.feed(html)
    return parser.links


def _expand_dot(pat: str) -> str:
    """Expand standalone '.' → '.*' to honour the config convention where
    '.' is a glob-style wildcard (any sequence), not a regex single-char match.
    Dots inside character classes [...] are left alone.
    """
    result: list[str] = []
    i = 0
    bracket_depth = 0
    while i < len(pat):
        c = pat[i]
        if c == "\\":                       # escaped char — copy both and skip
            result.append(c)
            if i + 1 < len(pat):
                result.append(pat[i + 1])
                i += 2
            continue
        if c == "[":
            bracket_depth += 1
        elif c == "]" and bracket_depth:
            bracket_depth -= 1
        elif c == "." and not bracket_depth:
            # Already quantified (e.g. ".*") — keep the dot as-is
            if i + 1 < len(pat) and pat[i + 1] in "*+?{":
                result.append(c)
                i += 1
                continue
            result.append(".*")
            i += 1
            continue
        result.append(c)
        i += 1
    return "".join(result)


def _matches_any(target: str, patterns: list[str]) -> bool:
    """Return True if target matches at least one pattern.

    Patterns use '.' as a glob wildcard (any sequence of chars), so each
    pattern is expanded via _expand_dot before matching with re.search.
    """
    for pat in patterns:
        expanded = _expand_dot(pat)
        if re.search(expanded, target):
            return True
    return False


# ── Crawl modes ───────────────────────────────────────────────────────────────

def _crawl_folders(
    url: str,
    folder_patterns: list[str],
    file_patterns: list[str],
    base_url: str | None,
    depth: int = 0,
    verbose: bool = False,
) -> list[str]:
    """
    Recursively navigate folder_patterns, collecting file URLs.

    At depth == len(folder_patterns) we are at the target Packages/ directory
    and scan for files matching file_patterns.
    """
    results: list[str] = []

    try:
        # Always resolve relative hrefs against the current page URL, not the
        # global base_url — Apache directory listings use page-relative paths.
        links = _get_links(url, url)
    except Exception as exc:
        print(f"  [warn] cannot fetch {url}: {exc}", file=sys.stderr)
        return results

    if depth >= len(folder_patterns):
        # Target level — match files
        for name, href, full_url, is_dir in links:
            if is_dir:
                continue
            # Match against filename; for Oracle-style hrefs that include a
            # sub-path (e.g. "getPackage/kernel-devel-*.rpm"), also try href.
            if _matches_any(name, file_patterns) or _matches_any(href.lstrip("/"), file_patterns):
                if verbose:
                    print(f"    match: {name}", file=sys.stderr)
                results.append(full_url)
        return results

    pattern = folder_patterns[depth]
    # Strip query/fragment for boundary check — URLs like ?cat=l must not block sub-paths
    url_path = urlunparse(urlparse(url)._replace(query="", fragment=""))
    matched_dirs: list[tuple[str, str]] = []
    for name, href, full_url, is_dir in links:
        if is_dir and re.match(pattern, name):
            # Only navigate deeper — skip links that escape the current directory
            if not full_url.startswith(url_path):
                continue
            matched_dirs.append((name, full_url))

    for name, dir_url in matched_dirs:
        if verbose:
            indent = "  " * (depth + 1)
            print(f"{indent}→ {name}/", file=sys.stderr)
        results.extend(
            _crawl_folders(dir_url, folder_patterns, file_patterns, base_url, depth + 1, verbose)
        )

    return results


def _crawl_index_links(
    start_url: str,
    base_url: str | None,
    link_pattern: str,
    file_patterns: list[str],
    verbose: bool = False,
) -> list[str]:
    """
    Oracle mode: extract all links from start_url that match link_pattern,
    treat each as a repo root, then scan for files matching file_patterns.
    """
    results: list[str] = []

    try:
        links = _get_links(start_url, base_url)
    except Exception as exc:
        print(f"  [warn] cannot fetch {start_url}: {exc}", file=sys.stderr)
        return results

    repo_urls: list[str] = []
    for name, href, full_url, is_dir in links:
        if re.search(link_pattern, href) or re.search(link_pattern, full_url):
            repo_url = full_url if full_url.endswith("/") else full_url + "/"
            repo_urls.append(repo_url)

    print(f"  found {len(repo_urls)} repo URLs matching link_pattern", file=sys.stderr)

    for repo_url in repo_urls:
        if verbose:
            print(f"  → {repo_url}", file=sys.stderr)
        try:
            repo_links = _get_links(repo_url, base_url)
        except Exception as exc:
            print(f"  [warn] {repo_url}: {exc}", file=sys.stderr)
            continue
        for name, href, full_url, is_dir in repo_links:
            if is_dir:
                continue
            rel_href = href.lstrip("/")
            if _matches_any(name, file_patterns) or _matches_any(rel_href, file_patterns):
                if verbose:
                    print(f"    match: {name}", file=sys.stderr)
                results.append(full_url)

    return results


# ── Download ──────────────────────────────────────────────────────────────────

def _download(url: str, dest_dir: Path, dry_run: bool = False) -> None:
    filename = url.split("/")[-1]
    dest = dest_dir / filename

    if dest.exists():
        print(f"  skip  {filename}")
        return

    if dry_run:
        print(f"  [DRY] {url}")
        return

    print(f"  ↓  {filename}", end="", flush=True)
    req = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(req, timeout=DOWNLOAD_TIMEOUT) as resp:
            data = resp.read()
        dest.write_bytes(data)
        print(f"  ({len(data) // 1024}K)")
    except Exception as exc:
        print(f"  FAILED: {exc}", file=sys.stderr)
        if dest.exists():
            dest.unlink()
        raise


# ── Main ─────────────────────────────────────────────────────────────────────

def _normalise(patterns: list) -> list[str]:
    return [str(p).split("#")[0].strip() for p in (patterns or []) if p]


def _collect_urls(job: dict, defaults: dict, verbose: bool) -> list[str]:
    start_url       = job.get("start_url")       or defaults.get("start_url", "")
    base_url        = job.get("base_url")        or defaults.get("base_url") or start_url
    folder_patterns = _normalise(job.get("folder_patterns") or defaults.get("folder_patterns") or [])
    file_patterns   = _normalise(job.get("file_patterns")   or defaults.get("file_patterns")   or [])
    link_pattern    = job.get("link_pattern")    or defaults.get("link_pattern")
    extract_index   = bool(job.get("extract_link_from_index",
                                   defaults.get("extract_link_from_index", False)))

    if extract_index and link_pattern:
        return _crawl_index_links(start_url, base_url, link_pattern, file_patterns, verbose)
    return _crawl_folders(start_url, folder_patterns, file_patterns, base_url, verbose=verbose)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Kernel image crawler — reads a YAML config and downloads vmlinuz packages",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("config", help="Path to YAML config file")
    parser.add_argument("--dry-run", action="store_true", help="List matched URLs without downloading")
    parser.add_argument("--list",    action="store_true", help="Print matched URLs only (no download, no log)")
    parser.add_argument("--verbose", action="store_true", help="Show directory navigation")
    parser.add_argument("--base-dir", default=".", metavar="DIR",
                        help="Base directory for download_folder paths (default: .)")
    args = parser.parse_args()

    with open(args.config) as fh:
        cfg = yaml.safe_load(fh)

    title           = cfg.get("title", "Unknown")
    download_folder = cfg["download_folder"]
    jobs            = cfg.get("jobs")

    if not args.list:
        print(f"\n[{title}]")

    # ── Collect matching file URLs ────────────────────────────────────────────
    all_urls: list[str] = []

    if jobs:
        for job in jobs:
            job_name = job.get("name", "job")
            if not args.list:
                print(f"  [{job_name}]", file=sys.stderr)
            urls = _collect_urls(job, cfg, args.verbose)
            if not args.list:
                print(f"    found {len(urls)} packages", file=sys.stderr)
            all_urls.extend(urls)
    else:
        # Single-job config (start_url required at top level)
        if not args.list:
            start_url = cfg.get("start_url", "")
            print(f"  start : {start_url}", file=sys.stderr)
        all_urls = _collect_urls({}, cfg, args.verbose)

    # Deduplicate preserving order
    seen: set[str] = set()
    file_urls = [u for u in all_urls if not (u in seen or seen.add(u))]  # type: ignore[func-returns-value]

    if args.list:
        for u in file_urls:
            print(u)
        return

    print(f"  total : {len(file_urls)} packages")

    if not file_urls:
        return

    # ── Download ──────────────────────────────────────────────────────────────
    dest_dir = Path(args.base_dir) / download_folder
    if not args.dry_run:
        dest_dir.mkdir(parents=True, exist_ok=True)

    errors = 0
    for url in file_urls:
        try:
            _download(url, dest_dir, dry_run=args.dry_run)
        except Exception as exc:
            print(f"  [error] {url.split('/')[-1]}: {exc}", file=sys.stderr)
            errors += 1

    if errors:
        print(f"\n  {errors} error(s) during download", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
