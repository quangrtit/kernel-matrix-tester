#!/usr/bin/env python3
"""
Prune kernel images: keep the N newest per (distro, major_kernel_version).

Groups kernels by the leading digit of the kernel version (2.x, 3.x, 4.x, 5.x),
then keeps the newest N within each group per distro.

For each pruned kernel the following artifacts are removed:
  kernels/{kname}/        — vmlinuz
  initramfs/{kname}.img   — per-kernel initramfs
  modules/{kname}/        — compiled Falco driver modules

Usage:
    python3 prune_kernels.py --dry-run          # preview — show what would be removed
    python3 prune_kernels.py --keep 20          # delete, keep 20 per group
    python3 prune_kernels.py --keep 5 centos    # trim only specific distros
"""
import argparse
import os
import re
import shutil
from collections import defaultdict

_HERE = os.path.dirname(os.path.abspath(__file__))


def ver_key(v: str) -> list:
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", v)]


def _dir_size(path: str) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for fname in files:
            try:
                total += os.path.getsize(os.path.join(root, fname))
            except OSError:
                pass
    return total


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--keep", type=int, default=20, metavar="N",
        help="Max kernels per (distro, major_version) — default 20",
    )
    ap.add_argument(
        "--dry-run", action="store_true",
        help="Show what would be deleted without making any changes",
    )
    ap.add_argument("--kernels-dir",   default=os.path.join(_HERE, "kernels"),          metavar="PATH")
    ap.add_argument("--initramfs-dir", default=os.path.join(_HERE, "initramfs"),        metavar="PATH")
    ap.add_argument("--modules-dir",   default=os.path.join(_HERE, "modules"),          metavar="PATH")
    ap.add_argument("--kernels-list",  default=os.path.join(_HERE, "config/kernels.list"), metavar="PATH")
    ap.add_argument("distros", nargs="*", metavar="DISTRO", help="Limit to these distros (default: all)")
    args = ap.parse_args()

    if not os.path.isfile(args.kernels_list):
        print(f"Not found: {args.kernels_list}")
        return 1

    raw_lines: list[str] = []
    entries: list[tuple[str, str, str]] = []
    with open(args.kernels_list) as f:
        for line in f:
            raw_lines.append(line)
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = stripped.split(":")
            if len(parts) != 3:
                continue
            distro, release, version = parts
            if args.distros and distro not in args.distros:
                continue
            entries.append((distro, release, version))

    # Group by (distro, major_kernel_version)
    groups: dict[tuple[str, str], list] = defaultdict(list)
    for e in entries:
        distro, _, version = e
        major = re.split(r"[.\-]", version)[0]
        groups[(distro, major)].append(e)

    to_keep: set[tuple[str, str, str]] = set()
    to_delete: list[tuple[str, str, str]] = []

    for (distro, major), group in sorted(groups.items()):
        sorted_group = sorted(group, key=lambda e: ver_key(e[2]))
        keep_n = sorted_group[-args.keep :]
        drop_n = sorted_group[: -args.keep] if len(sorted_group) > args.keep else []
        for e in keep_n:
            to_keep.add(e)
        to_delete.extend(drop_n)

    print(f"Total:  {len(entries)} kernels in {len(groups)} groups (distro × major_version)")
    print(f"Keep:   {len(to_keep)}")
    print(f"Delete: {len(to_delete)}", end="")
    print("  (dry-run — no changes)" if args.dry_run else "")
    print()

    deleted = 0
    freed = 0
    for distro, release, version in sorted(to_delete, key=lambda e: (e[0], ver_key(e[2]))):
        kname = f"{distro}-{release}-{version}"

        # Collect artifacts and their sizes
        artifacts: list[tuple[str, int]] = []
        kdir      = os.path.join(args.kernels_dir, kname)
        initramfs = os.path.join(args.initramfs_dir, f"{kname}.img")
        modules_d = os.path.join(args.modules_dir, kname)

        if os.path.isdir(kdir):
            artifacts.append((kdir, _dir_size(kdir)))
        if os.path.isfile(initramfs):
            artifacts.append((initramfs, os.path.getsize(initramfs)))
        if os.path.isdir(modules_d):
            artifacts.append((modules_d, _dir_size(modules_d)))

        total_size = sum(s for _, s in artifacts)
        mb = f"  ({total_size // 1048576} MB)" if total_size else ""

        if args.dry_run:
            print(f"  ~ {kname}{mb}")
        else:
            for path, _ in artifacts:
                if os.path.isdir(path):
                    shutil.rmtree(path)
                else:
                    os.remove(path)
            freed += total_size
            if artifacts:
                deleted += 1
            print(f"  ✓ {kname}{mb}")

    if not args.dry_run:
        # Rewrite kernels.list — preserve comments/blanks, drop deleted entries
        # Only filter lines belonging to requested distros (leave others untouched)
        filter_distros = set(args.distros) if args.distros else None
        with open(args.kernels_list, "w") as f:
            for line in raw_lines:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    f.write(line)
                    continue
                parts = stripped.split(":")
                if len(parts) != 3:
                    f.write(line)
                    continue
                distro = parts[0]
                if filter_distros and distro not in filter_distros:
                    f.write(line)  # not in scope, always keep
                    continue
                if tuple(parts) in to_keep:
                    f.write(line)
        mb_freed = freed // 1048576
        print(f"\nDeleted {deleted} kernels ({mb_freed} MB freed)")
        print(f"  artifacts cleaned: kernels/, initramfs/*.img, modules/")
        print(f"Updated {args.kernels_list}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
