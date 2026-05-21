#!/usr/bin/env python3
"""
Filter kernel package URLs to keep at most N per major kernel version.
Reads URLs from stdin, writes filtered URLs to stdout.

Used by sync_kernels.sh TEST_MODE to limit downloads without touching existing cache.

Usage:
    cat urls.txt | python3 downloader/filter_urls.py --distro centos --max 20
"""
import argparse
import os
import re
import sys
from collections import defaultdict


def ver_key(v: str) -> list:
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", v)]


def extract_version(distro: str, url: str) -> str | None:
    f = os.path.basename(url.split("?")[0])
    if distro in ("centos", "almalinux", "rocky", "oracle", "redhat"):
        for prefix in ("kernel-uek-core-", "kernel-uek-", "kernel-core-", "kernel-"):
            if f.startswith(prefix):
                return f[len(prefix) :].removesuffix(".x86_64.rpm")
    elif distro == "ubuntu":
        for prefix in ("linux-image-unsigned-", "linux-image-"):
            if f.startswith(prefix):
                f = f[len(prefix) :]
                break
        return f.split("_")[0]
    elif distro == "debian":
        if f.startswith("linux-image-"):
            f = f[len("linux-image-") :]
        return f.split("_")[0].removesuffix("-unsigned")
    return None


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--distro", required=True)
    ap.add_argument("--max", type=int, default=20, help="Max URLs per major kernel version")
    args = ap.parse_args()

    urls = [line.strip() for line in sys.stdin if line.strip()]
    groups: dict[str, list[tuple[str, str]]] = defaultdict(list)
    unmatched: list[str] = []

    for url in urls:
        version = extract_version(args.distro, url)
        if version:
            major = re.split(r"[.\-]", version)[0]
            if major.isdigit():
                groups[major].append((version, url))
                continue
        unmatched.append(url)

    for major in sorted(groups, key=lambda m: int(m)):
        group = sorted(groups[major], key=lambda x: ver_key(x[0]))
        for _, url in group[-args.max :]:
            print(url)

    for url in unmatched:
        print(url)


if __name__ == "__main__":
    main()
