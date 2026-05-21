#!/usr/bin/env python3
"""
Oracle Linux kernel image crawler.

Reads config.yaml in this directory, then for each job:
  1. Fetches the release index page (start_url)
  2. Finds repo URLs matching link_pattern
  3. Scans each repo for kernel RPMs matching file_pattern

file_pattern is matched against the full URL (Oracle repos use a
getPackage/ prefix in their hrefs, which appears in the resolved URL).

Usage:
    python3 downloader/oracle/crawler.py [--list] [--verbose] [--dry-run]
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

    file_re = re.compile(cfg["file_pattern"])
    urls: list[str] = []

    for job in cfg["jobs"]:
        job_name     = job.get("name", "job")
        start_url    = job["start_url"]
        link_pat     = re.compile(job["link_pattern"])

        if verbose:
            print(f"  [{job_name}] {start_url}", file=sys.stderr)

        try:
            index_links = get_links(start_url)
        except Exception as exc:
            print(f"  [warn] {job_name}: {exc}", file=sys.stderr)
            continue

        # Collect unique repo root URLs from the index page
        repo_urls: set[str] = set()
        for _name, full_url, _is_dir in index_links:
            if link_pat.search(full_url):
                repo_url = full_url if full_url.endswith("/") else full_url.rsplit("/", 1)[0] + "/"
                repo_urls.add(repo_url)

        if verbose:
            print(f"    found {len(repo_urls)} repos", file=sys.stderr)

        for repo_url in sorted(repo_urls):
            try:
                repo_links = get_links(repo_url)
            except Exception as exc:
                print(f"  [warn] {repo_url}: {exc}", file=sys.stderr)
                continue
            for name, full_url, is_dir in repo_links:
                if not is_dir and file_re.search(full_url):
                    if verbose:
                        print(f"    match: {name}", file=sys.stderr)
                    urls.append(full_url)

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
