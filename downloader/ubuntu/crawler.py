#!/usr/bin/env python3
"""
Ubuntu kernel image crawler.

Reads config.yaml in this directory, then crawls the Ubuntu pool for
linux and linux-hwe* source directories and collects vmlinuz .deb packages.

Usage:
    python3 downloader/ubuntu/crawler.py [--list] [--verbose] [--dry-run]
"""
import re
import sys
import os
import argparse

try:
    import yaml
except ImportError:
    sys.exit("Error: PyYAML not found. Run: pip3 install pyyaml")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from lib import get_links

_HERE = os.path.dirname(os.path.abspath(__file__))


def collect(verbose: bool = False) -> list[str]:
    with open(os.path.join(_HERE, "config.yaml")) as fh:
        cfg = yaml.safe_load(fh)

    base_url   = cfg["base_url"]
    src_re     = re.compile(cfg["source_pattern"])
    file_re    = re.compile(cfg["file_pattern"])

    urls: list[str] = []

    try:
        top_links = get_links(base_url)
    except Exception as exc:
        print(f"  [warn] cannot fetch {base_url}: {exc}", file=sys.stderr)
        return urls

    for name, full_url, is_dir in top_links:
        if not is_dir or not src_re.match(name):
            continue
        if verbose:
            print(f"  → {name}/", file=sys.stderr)
        try:
            pkg_links = get_links(full_url)
        except Exception as exc:
            print(f"  [warn] {full_url}: {exc}", file=sys.stderr)
            continue
        for fname, furl, fdir in pkg_links:
            if not fdir and file_re.match(fname):
                if verbose:
                    print(f"    match: {fname}", file=sys.stderr)
                urls.append(furl)

    return sorted(set(urls))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list",    action="store_true", help="Print URLs only, no download")
    ap.add_argument("--verbose", action="store_true", help="Show directory navigation")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    urls = collect(args.verbose)
    for u in urls:
        print(u)
    if not args.list:
        print(f"\n  total: {len(urls)} packages", file=sys.stderr)


if __name__ == "__main__":
    main()
