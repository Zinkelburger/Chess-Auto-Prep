"""Download the FICS bughouse archive from bughouse-db.org.

The archive is one bzip2'd BPGN per year, 2005 to the present, ~2.1 GB in
total.  The files are kept *compressed* on disk and the indexer streams them
through `bz2` -- expanding the lot would cost ~8.5 GB for no gain.

The year list is discovered from the directory index rather than hardcoded,
so a new year appears the January after it is published without a code
change.  Each completed download records its size and SHA-256 in
`corpus/manifest.json`, which is what `check` verifies against and what lets
a re-run skip files it already has.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
import urllib.error
import urllib.request

from .paths import corpus_dir, manifest_path

BASE = "https://www.bughouse-db.org/dl/"
INDEX_RE = re.compile(r'href="(export(\d{4})\.bpgn\.bz2)"')
UA = {"User-Agent": "chess-auto-prep-bughouse-db"}


def human(n: int) -> str:
    return f"{n / 1e6:.1f} MB" if n < 1e9 else f"{n / 1e9:.2f} GB"


def load_manifest() -> dict:
    path = manifest_path()
    return json.loads(path.read_text()) if path.exists() else {}


def save_manifest(manifest: dict) -> None:
    path = manifest_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def sha256_file(path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def discover() -> list[str]:
    """Every `exportYYYY.bpgn.bz2` the directory index lists, oldest first."""
    req = urllib.request.Request(BASE, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            html = resp.read().decode("utf-8", "replace")
    except urllib.error.URLError as exc:
        raise SystemExit(f"ERROR: cannot reach {BASE}: {exc}") from exc
    names = sorted({m.group(1) for m in INDEX_RE.finditer(html)})
    if not names:
        raise SystemExit(f"ERROR: no .bpgn.bz2 files listed at {BASE}")
    return names


def year_of(name: str) -> int:
    match = INDEX_RE.search(f'href="{name}"')
    return int(match.group(2)) if match else 0


def download(name: str, force: bool) -> bool:
    """Fetch one year.  Returns True when bytes were actually downloaded."""
    dest = corpus_dir() / name
    manifest = load_manifest()
    if dest.exists() and not force:
        recorded = manifest.get(name, {})
        if recorded.get("bytes") == dest.stat().st_size:
            print(f"  {name}: present ({human(dest.stat().st_size)})")
            return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    url = BASE + name
    req = urllib.request.Request(url, headers=UA)
    print(f"  {name}: downloading")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp, part.open("wb") as out:
            total = int(resp.headers.get("Content-Length") or 0)
            got = 0
            while chunk := resp.read(1 << 20):
                out.write(chunk)
                got += len(chunk)
                if sys.stderr.isatty() and total:
                    pct = 100 * got / total
                    print(
                        f"\r    {human(got)} / {human(total)} ({pct:.0f}%)",
                        end="",
                        file=sys.stderr,
                    )
    except urllib.error.URLError as exc:
        part.unlink(missing_ok=True)
        raise SystemExit(f"\nERROR: {url}: {exc}") from exc
    if sys.stderr.isatty():
        print(file=sys.stderr)
    part.replace(dest)
    manifest = load_manifest()
    manifest[name] = {"bytes": dest.stat().st_size, "sha256": sha256_file(dest)}
    save_manifest(manifest)
    print(f"    done ({human(dest.stat().st_size)})")
    return True


def fetch(only: list[int] | None, force: bool) -> int:
    names = discover()
    if only:
        names = [n for n in names if year_of(n) in only]
        if not names:
            raise SystemExit(f"ERROR: no archive years matching {only}")
    print(f"{len(names)} archive year(s) -> {corpus_dir()}")
    for name in names:
        download(name, force)
    return 0


def check(verify_hashes: bool) -> int:
    manifest = load_manifest()
    names = sorted(p.name for p in corpus_dir().glob("export*.bpgn.bz2"))
    if not names:
        print(f"no corpus at {corpus_dir()} -- run `fetch` first")
        return 1
    bad = 0
    total = 0
    for name in names:
        path = corpus_dir() / name
        size = path.stat().st_size
        total += size
        recorded = manifest.get(name)
        if not recorded:
            print(f"  {name}: {human(size)}  (not in manifest)")
            continue
        if recorded["bytes"] != size:
            print(f"  {name}: SIZE MISMATCH {size} != {recorded['bytes']}")
            bad += 1
            continue
        if verify_hashes and sha256_file(path) != recorded["sha256"]:
            print(f"  {name}: SHA-256 MISMATCH")
            bad += 1
            continue
        print(f"  {name}: ok ({human(size)})")
    print(f"{len(names)} file(s), {human(total)}" + (f", {bad} bad" if bad else ""))
    return 1 if bad else 0
