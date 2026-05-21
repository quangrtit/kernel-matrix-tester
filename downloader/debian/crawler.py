#!/usr/bin/env python3
"""
Debian kernel image crawler.

Reads config.yaml in this directory, then crawls snapshot.debian.org for
linux source packages across squeeze (2.6), wheezy (3.2), stretch/buster (4.x),
and bullseye (5.10).

Usage:
    python3 downloader/debian/crawler.py [--list] [--verbose] [--dry-run]
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
from lib import get_links, walk_dirs

_HERE = os.path.dirname(os.path.abspath(__file__))


def collect(verbose: bool = False) -> list[str]:
    with open(os.path.join(_HERE, "config.yaml")) as fh:
        cfg = yaml.safe_load(fh)

    file_re = re.compile(cfg["file_pattern"])
    urls: list[str] = []

    for job in cfg["jobs"]:
        job_name  = job.get("name", "job")
        start_url = job["start_url"]

        if verbose:
            print(f"  [{job_name}] {start_url}", file=sys.stderr)

        if "version_pattern" not in job:
            # Pinned URL (e.g. squeeze) — just scan the directory directly
            try:
                for name, full_url, is_dir in get_links(start_url):
                    if not is_dir and file_re.match(name):
                        if verbose:
                            print(f"    match: {name}", file=sys.stderr)
                        urls.append(full_url)
            except Exception as exc:
                print(f"  [warn] {job_name}: {exc}", file=sys.stderr)
        else:
            # Navigate version subdirectories first, then collect files
            ver_pat = re.compile(job["version_pattern"])
            found = walk_dirs(start_url, [ver_pat], file_re, verbose=verbose)
            urls.extend(found)

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
