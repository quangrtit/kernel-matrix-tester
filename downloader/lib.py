#!/usr/bin/env python3
"""
Shared HTTP/HTML utilities for distro kernel crawlers.

Provides:
    fetch(url, timeout)      → raw HTML string
    get_links(url)           → list of (name, full_url, is_dir)
    walk_dirs(start, patterns, file_re, verbose) → list of matching file URLs
"""
import re
import sys
import time
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError
from urllib.parse import urljoin, urlparse, urlunparse
from html.parser import HTMLParser

UA = "kernel-matrix-tester/1.0"
FETCH_TIMEOUT = 30
DOWNLOAD_TIMEOUT = 300
RETRY_WAIT = 3
MAX_RETRIES = 3


class _LinkParser(HTMLParser):
    def __init__(self, base_url: str):
        super().__init__()
        self.base_url = base_url
        self.links: list[tuple[str, str, bool]] = []  # (name, full_url, is_dir)

    def handle_starttag(self, tag, attrs):
        if tag != "a":
            return
        attrs = dict(attrs)
        href = attrs.get("href", "").strip()
        if not href or href.startswith(("#", "?")) or href in ("..", "../"):
            return
        if "://" in href and not href.startswith(("http://", "https://")):
            return
        is_dir = href.endswith("/")
        full_url = urljoin(self.base_url, href)
        name = href.rstrip("/").split("/")[-1]
        self.links.append((name, full_url, is_dir))


def fetch(url: str, timeout: int = FETCH_TIMEOUT) -> str:
    req = Request(url, headers={"User-Agent": UA})
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            with urlopen(req, timeout=timeout) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except HTTPError as e:
            if e.code == 404:
                return ""
            if attempt == MAX_RETRIES:
                raise
        except (URLError, OSError):
            if attempt == MAX_RETRIES:
                raise
        time.sleep(RETRY_WAIT)
    return ""


def get_links(url: str) -> list[tuple[str, str, bool]]:
    """Return list of (name, full_url, is_dir) for all <a> links on page."""
    html = fetch(url)
    if not html:
        return []
    parser = _LinkParser(url)
    parser.feed(html)
    return parser.links


def walk_dirs(
    start: str,
    dir_patterns: list,
    file_re: "re.Pattern",
    verbose: bool = False,
    _depth: int = 0,
) -> list[str]:
    """
    Recursively navigate directories matching dir_patterns[depth], then
    collect files whose names match file_re at the target level.

    dir_patterns: list of compiled re.Pattern or raw strings (compiled on first use).
    """
    results: list[str] = []

    try:
        links = get_links(start)
    except Exception as exc:
        print(f"  [warn] cannot fetch {start}: {exc}", file=sys.stderr)
        return results

    if _depth >= len(dir_patterns):
        for name, full_url, is_dir in links:
            if not is_dir and file_re.search(name):
                if verbose:
                    print(f"    match: {name}", file=sys.stderr)
                results.append(full_url)
        return results

    pat = dir_patterns[_depth]
    if isinstance(pat, str):
        pat = re.compile(pat)

    url_base = urlunparse(urlparse(start)._replace(query="", fragment=""))
    for name, full_url, is_dir in links:
        if is_dir and pat.search(name):
            if not full_url.startswith(url_base):
                continue
            if verbose:
                indent = "  " * (_depth + 1)
                print(f"{indent}→ {name}/", file=sys.stderr)
            results.extend(walk_dirs(full_url, dir_patterns, file_re, verbose, _depth + 1))

    return results
