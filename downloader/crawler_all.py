#!/usr/bin/env python3
"""
Run all enabled distro crawlers based on config.yaml.

Usage:
    python3 crawler_all.py                  # download all enabled distros
    python3 crawler_all.py --dry-run        # preview without downloading
    python3 crawler_all.py --list           # print matched URLs only
    python3 crawler_all.py --verbose        # show directory navigation
"""
import os, sys, subprocess

_HERE = os.path.dirname(os.path.abspath(__file__))

try:
    import yaml
except ImportError:
    sys.exit("Error: PyYAML not found. Install with: pip3 install pyyaml")


def main() -> None:
    config_path = os.path.join(_HERE, 'config.yaml')
    with open(config_path) as f:
        cfg = yaml.safe_load(f)

    enabled: list[str] = cfg.get('enabled', [])
    if not enabled:
        sys.exit("No distros enabled in config.yaml")

    extra_args = sys.argv[1:]
    errors = 0

    for distro in enabled:
        crawler = os.path.join(_HERE, distro, 'crawler.py')
        if not os.path.isfile(crawler):
            print(f"  [warn] no crawler found for '{distro}': {crawler}", file=sys.stderr)
            continue

        print(f"\n{'━' * 52}")
        print(f"  {distro}")
        print(f"{'━' * 52}")

        result = subprocess.run([sys.executable, crawler] + extra_args)
        if result.returncode != 0:
            print(f"  [error] {distro} crawler exited {result.returncode}", file=sys.stderr)
            errors += 1

    print()
    if errors:
        print(f"  {errors} distro(s) had errors", file=sys.stderr)
        sys.exit(1)
    else:
        print("  All distros done.")


if __name__ == '__main__':
    main()
