#!/usr/bin/env python3
"""
Red Hat Enterprise Linux kernel image crawler.

Reads config.yaml in this directory, authenticates with Red Hat SSO,
queries api.access.redhat.com for kernel RPM packages, then runs a
producer-consumer pipeline: CDN resolvers → queue → download workers.

Package metadata is cached locally for 7 days (.pkg_cache.json).
CDN URLs are always resolved fresh (time-limited signed URLs).

Requires: pip3 install requests pyyaml

Usage:
    python3 downloader/redhat/crawler.py --list    [--verbose]
    python3 downloader/redhat/crawler.py --download --kernels-dir DIR --kernels-list FILE [--verbose] [--dry-run]
"""
import re
import sys
import os
import argparse
import json
import queue
import shutil
import subprocess
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("Error: PyYAML not found. Run: pip3 install pyyaml")

try:
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry
except ImportError:
    sys.exit("Error: requests not found. Run: pip3 install requests")

_HERE          = os.path.dirname(os.path.abspath(__file__))
_CACHE         = os.path.join(_HERE, ".pkg_cache.json")
SSO_URL        = "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
API_BASE       = "https://api.access.redhat.com/management/v1"
CACHE_TTL_DAYS = 7
CDN_WORKERS    = 8
DL_WORKERS     = 4


# ── Auth ──────────────────────────────────────────────────────────────────────

def _new_session() -> "requests.Session":
    s = requests.Session()
    s.mount("https://", HTTPAdapter(max_retries=Retry(
        total=5, backoff_factor=0.5, status_forcelist=[500, 502, 503, 504])))
    return s


def _auth(offline_token: str) -> tuple["requests.Session", str]:
    resp = requests.post(SSO_URL, timeout=30, data={
        "grant_type": "refresh_token", "client_id": "rhsm-api",
        "refresh_token": offline_token,
    })
    resp.raise_for_status()
    token = resp.json().get("access_token")
    if not token:
        raise RuntimeError(f"SSO returned no access_token: {resp.text[:200]}")
    return _new_session(), token


class _TokMgr:
    """Thread-safe access token manager with auto-refresh on 401."""
    def __init__(self, offline_token: str):
        self._offline = offline_token
        self._tok: str = ""
        self._sess: "requests.Session | None" = None
        self._lock = threading.Lock()

    def get(self) -> tuple["requests.Session", str]:
        with self._lock:
            if not self._tok:
                self._sess, self._tok = _auth(self._offline)
            return self._sess, self._tok

    def refresh(self, old_tok: str) -> tuple["requests.Session", str]:
        with self._lock:
            if self._tok == old_tok:
                self._sess, self._tok = _auth(self._offline)
            return self._sess, self._tok


def _hdrs(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Accept": "application/json"}


# ── Package list fetch ────────────────────────────────────────────────────────

def _fetch_packages(tok_mgr: _TokMgr, content_set: str, arch: str,
                    pkg_name: str, verbose: bool, workers: int = 8) -> list[dict]:
    """Fetch all pages concurrently; refresh token on 401."""
    url = f"{API_BASE}/packages/cset/{content_set}/arch/{arch}"

    def _one_page(offset: int) -> tuple[int, list[dict], bool]:
        for attempt in range(2):
            sess, tok = tok_mgr.get()
            resp = sess.get(url, headers=_hdrs(tok),
                            params={"limit": 100, "offset": offset}, timeout=60)
            if resp.status_code == 401 and attempt == 0:
                tok_mgr.refresh(tok)
                continue
            resp.raise_for_status()
            body = resp.json().get("body", [])
            return offset, [p for p in body if p.get("name") == pkg_name], len(body) < 100
        return offset, [], True

    all_pkgs: list[dict] = []
    offset = 0
    page_n = 0

    while offset <= 200_000:
        batch = list(range(offset, min(offset + workers * 100, 200_001), 100))
        results: dict[int, tuple[list[dict], bool]] = {}
        with ThreadPoolExecutor(max_workers=workers) as ex:
            for o, pkgs, last in (f.result() for f in as_completed(
                    {ex.submit(_one_page, o): o for o in batch})):
                results[o] = (pkgs, last)

        stop = float("inf")
        for o in sorted(results):
            if o > stop:
                break
            pkgs, last = results[o]
            all_pkgs.extend(pkgs)
            page_n += 1
            if last:
                stop = o
        if verbose:
            print(f"    pages {page_n}  matched {len(all_pkgs)}", file=sys.stderr)
        if stop < float("inf"):
            break
        offset += workers * 100

    if verbose:
        print(f"    done — {len(all_pkgs)} from {content_set}/{arch}", file=sys.stderr)
    return all_pkgs


def _build_package_list(cfg: dict, tok_mgr: _TokMgr, verbose: bool) -> list[dict]:
    """Return cached or freshly-fetched package metadata list."""
    cached = _load_cache()
    if cached:
        if verbose:
            print(f"  [cache] {len(cached)} packages", file=sys.stderr)
        return cached

    pkg_name      = cfg.get("package_name", "kernel")
    architectures = cfg.get("architectures", ["x86_64"])
    seen: set[str] = set()
    packages: list[dict] = []

    for job in cfg["jobs"]:
        job_name = job.get("name", "job")
        ver_re   = re.compile(job["version_pattern"])
        if verbose:
            print(f"  [{job_name}]", file=sys.stderr)
        for cs in job["content_sets"]:
            for arch in architectures:
                if verbose:
                    print(f"    fetching {cs}/{arch} ...", file=sys.stderr)
                raw = _fetch_packages(tok_mgr, cs, arch, pkg_name, verbose)
                for p in raw:
                    ver  = f"{p.get('version', '')}-{p.get('release', '')}"
                    chk  = p.get("checksum", "")
                    if not chk or chk in seen or not ver_re.search(ver):
                        continue
                    seen.add(chk)
                    epoch   = str(p.get("epoch", "0"))
                    ver_rel = f"{p['version']}-{p['release']}"
                    a       = p.get("arch", "x86_64")
                    fname   = (f"{pkg_name}-{epoch}:{ver_rel}.{a}.rpm"
                               if epoch != "0" else f"{pkg_name}-{ver_rel}.{a}.rpm")
                    packages.append({"checksum": chk, "filename": fname})

    _save_cache(packages)
    return packages


# ── CDN URL resolution ────────────────────────────────────────────────────────

def _resolve_cdn(pkg: dict, tok_mgr: _TokMgr) -> str | None:
    for attempt in range(2):
        sess, tok = tok_mgr.get()
        resp = sess.get(f"{API_BASE}/packages/{pkg['checksum']}/download",
                        headers=_hdrs(tok), timeout=60, allow_redirects=False)
        if resp.status_code == 401 and attempt == 0:
            tok_mgr.refresh(tok)
            continue
        if not resp.ok:
            print(f"  [warn] {pkg['filename']}: HTTP {resp.status_code}", file=sys.stderr)
            return None
        url = resp.json().get("body", {}).get("href", "")
        return url or None
    return None


# ── Download + extract ────────────────────────────────────────────────────────

def _parse_filename(filename: str) -> tuple[str, str] | None:
    """Parse RPM filename → (release_label, version_string)."""
    for prefix in ("kernel-core-", "kernel-"):
        if filename.startswith(prefix):
            ver = filename[len(prefix):].removesuffix(".x86_64.rpm")
            m   = re.search(r'\.el(\d+)', ver)
            return (f"rhel{m.group(1)}" if m else "rhel"), ver
    return None


def _extract_vmlinuz(rpm_path: str, dest: str) -> bool:
    with tempfile.TemporaryDirectory() as tmpdir:
        p1 = subprocess.Popen(["rpm2cpio", rpm_path],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        p2 = subprocess.Popen(["cpio", "-id", "--quiet", "--no-absolute-filenames"],
                               stdin=p1.stdout, cwd=tmpdir,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        p1.stdout.close()
        p2.communicate(timeout=120)
        p1.communicate()
        for root, _, files in os.walk(tmpdir):
            for fn in sorted(files):
                if fn.startswith("vmlinuz") and "rescue" not in fn and "debug" not in fn:
                    shutil.copy2(os.path.join(root, fn), dest)
                    return True
    return False


_reg_lock = threading.Lock()


def _register(release: str, version: str, kernels_list: str) -> None:
    entry = f"redhat:{release}:{version}"
    with _reg_lock:
        try:
            lines = Path(kernels_list).read_text().splitlines()
        except FileNotFoundError:
            lines = []
        if entry not in lines:
            with open(kernels_list, "a") as f:
                f.write(entry + "\n")


def _process_package(filename: str, url: str, kernels_dir: str,
                     kernels_list: str, max_major: int,
                     dry_run: bool) -> str:
    """Download, extract, register. Returns 'done:kname', 'skip:reason', or 'error:msg'."""
    parsed = _parse_filename(filename)
    if not parsed:
        return f"error:cannot parse {filename}"
    release, version = parsed

    kmaj = version.split(".")[0]
    if kmaj.isdigit() and int(kmaj) > max_major:
        return f"skip:major>{max_major}"

    kname = f"redhat-{release}-{version}"
    dest  = Path(kernels_dir) / kname / "vmlinuz"

    if dest.exists():
        _register(release, version, kernels_list)
        return f"skip:{kname}"

    if dry_run:
        return f"dry:{kname}"

    tmp = tempfile.NamedTemporaryFile(suffix=".rpm", delete=False)
    try:
        resp = requests.get(url, stream=True, timeout=600)
        resp.raise_for_status()
        for chunk in resp.iter_content(1024 * 1024):
            tmp.write(chunk)
        tmp.close()

        dest.parent.mkdir(parents=True, exist_ok=True)
        if not _extract_vmlinuz(tmp.name, str(dest)):
            return f"error:vmlinuz not found in {filename}"

        _register(release, version, kernels_list)
        size = dest.stat().st_size // 1024
        return f"done:{kname}:{size}K"
    except Exception as exc:
        dest.unlink(missing_ok=True)
        return f"error:{exc}"
    finally:
        try:
            tmp.close()
        except Exception:
            pass
        if os.path.exists(tmp.name):
            os.unlink(tmp.name)


# ── Pipeline ──────────────────────────────────────────────────────────────────

def run_pipeline(cfg: dict, kernels_dir: str, kernels_list: str,
                 max_major: int, dry_run: bool, verbose: bool) -> int:
    """
    Producer-consumer pipeline:
      CDN_WORKERS resolver threads → Queue → DL_WORKERS download workers.
    Each URL is handed to a free download worker as soon as it is resolved.
    """
    offline_token = cfg["offline_token"]
    tok_mgr  = _TokMgr(offline_token)
    packages = _build_package_list(cfg, tok_mgr, verbose)
    if not packages:
        print("  no packages found", file=sys.stderr)
        return 0

    print(f"  pipeline: {len(packages)} packages  "
          f"resolvers={CDN_WORKERS}  downloaders={DL_WORKERS}", file=sys.stderr)

    url_q: queue.Queue = queue.Queue(maxsize=DL_WORKERS * 2)
    errors   = [0]
    plock    = threading.Lock()

    GREEN = "\033[0;32m"; RED = "\033[0;31m"; YELLOW = "\033[1;33m"; NC = "\033[0m"

    def producer() -> None:
        with ThreadPoolExecutor(max_workers=CDN_WORKERS) as ex:
            futs = {ex.submit(_resolve_cdn, pkg, tok_mgr): pkg for pkg in packages}
            for f in as_completed(futs):
                pkg = futs[f]
                url = f.result()
                if url:
                    url_q.put((pkg["filename"], url))
                elif verbose:
                    print(f"  [warn] no URL for {pkg['filename']}", file=sys.stderr)
        for _ in range(DL_WORKERS):
            url_q.put(None)

    def downloader() -> None:
        while True:
            item = url_q.get()
            if item is None:
                break
            filename, url = item
            result = _process_package(filename, url, kernels_dir, kernels_list,
                                      max_major, dry_run)
            with plock:
                if result.startswith("done:"):
                    parts = result[5:].rsplit(":", 1)
                    kname = parts[0]; size = parts[1] if len(parts) == 2 else ""
                    print(f"  {GREEN}✓{NC} {kname}  ({size})", flush=True)
                elif result.startswith("skip:") and verbose:
                    print(f"  {YELLOW}~{NC} {result[5:]}  (cached)", file=sys.stderr, flush=True)
                elif result.startswith("dry:"):
                    print(f"  [DRY] {result[4:]}", flush=True)
                elif result.startswith("error:"):
                    print(f"  {RED}✗{NC} {filename}: {result[6:]}", file=sys.stderr, flush=True)
                    errors[0] += 1

    with ThreadPoolExecutor(max_workers=1 + DL_WORKERS) as ex:
        prod = ex.submit(producer)
        dls  = [ex.submit(downloader) for _ in range(DL_WORKERS)]
        prod.result()
        for d in dls:
            d.result()

    return errors[0]


# ── List mode (backward compat with sync_kernels.sh) ─────────────────────────

def collect(verbose: bool = False) -> list[str]:
    with open(os.path.join(_HERE, "config.yaml")) as fh:
        cfg = yaml.safe_load(fh)
    tok_mgr  = _TokMgr(cfg["offline_token"])
    packages = _build_package_list(cfg, tok_mgr, verbose)
    if not packages:
        return []

    if verbose:
        print(f"  resolving {len(packages)} CDN URLs ...", file=sys.stderr)

    urls: list[str] = []
    done = 0
    with ThreadPoolExecutor(max_workers=min(CDN_WORKERS, len(packages))) as ex:
        futs = {ex.submit(_resolve_cdn, p, tok_mgr): p for p in packages}
        for f in as_completed(futs):
            url = f.result()
            done += 1
            if verbose and done % 20 == 0:
                print(f"    resolved {done}/{len(packages)}", file=sys.stderr)
            if url:
                urls.append(url)

    return sorted(set(urls))


# ── Cache helpers ─────────────────────────────────────────────────────────────

def _load_cache() -> list[dict]:
    if not os.path.exists(_CACHE):
        return []
    try:
        data = json.loads(Path(_CACHE).read_text())
        ts   = datetime.fromisoformat(data["timestamp"])
        if datetime.now() < ts + timedelta(days=CACHE_TTL_DAYS) and data.get("packages"):
            return data["packages"]
    except Exception:
        pass
    return []


def _save_cache(packages: list[dict]) -> None:
    Path(_CACHE).write_text(
        json.dumps({"timestamp": datetime.now().isoformat(), "packages": packages}, indent=2))


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list",     action="store_true",
                      help="Print CDN URLs to stdout (for sync_kernels.sh)")
    mode.add_argument("--download", action="store_true",
                      help="Pipeline: resolve URLs and download concurrently")
    ap.add_argument("--kernels-dir",  default="kernels",            metavar="DIR")
    ap.add_argument("--kernels-list", default="config/kernels.list", metavar="FILE")
    ap.add_argument("--max-major",    type=int, default=5)
    ap.add_argument("--verbose",      action="store_true")
    ap.add_argument("--dry-run",      action="store_true")
    args = ap.parse_args()

    if args.download:
        with open(os.path.join(_HERE, "config.yaml")) as fh:
            cfg = yaml.safe_load(fh)
        errors = run_pipeline(cfg, args.kernels_dir, args.kernels_list,
                              args.max_major, args.dry_run, args.verbose)
        if errors:
            print(f"\n  {errors} error(s)", file=sys.stderr)
            sys.exit(1)
    else:
        urls = collect(args.verbose)
        for u in urls:
            print(u)
        print(f"\n  total: {len(urls)} packages", file=sys.stderr)


if __name__ == "__main__":
    main()
