#!/usr/bin/env python3
"""
Rocky Linux kernel image crawler.

Reads config.yaml in this directory, then crawls dl.rockylinux.org/vault/rocky/
for rocky8 and rocky9 kernel-core RPMs.

Usage:
    python3 downloader/rocky/crawler.py [--list] [--verbose] [--dry-run]
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
from lib import walk_dirs

_HERE = os.path.dirname(os.path.abspath(__file__))


def collect(verbose: bool = False) -> list[str]:
    with open(os.path.join(_HERE, "config.yaml")) as fh:
        cfg = yaml.safe_load(fh)

    base_url = cfg["base_url"]
    file_re  = re.compile(cfg["file_pattern"])
    skip_re  = re.compile(cfg["skip_pattern"])
    urls: list[str] = []

    for job in cfg["jobs"]:
        job_name = job.get("name", "job")
        dir_pats = [re.compile(p) for p in job["dir_patterns"]]

        if verbose:
            print(f"  [{job_name}]", file=sys.stderr)

        raw = walk_dirs(base_url, dir_pats, file_re, verbose=verbose)
        for u in raw:
            if not skip_re.search(u.split("/")[-1]):
                urls.append(u)

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
