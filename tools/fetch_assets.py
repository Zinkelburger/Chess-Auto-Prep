#!/usr/bin/env python3
"""Fetch the Stockfish engine binary for this machine (not tracked in git).

These files are bundled by `pubspec.yaml` and loaded from the Flutter root
bundle at runtime, so they must exist *before* `flutter build` runs -- not
just before someone launches the app in development. Run this from the repo
root as a build prerequisite, including in CI.

    python3 tools/fetch_assets.py            # host platform only (~75 MB)
    python3 tools/fetch_assets.py --check    # verify host asset; non-zero if missing
    python3 tools/fetch_assets.py --force    # re-download and overwrite
    python3 tools/fetch_assets.py --only stockfish-linux
    python3 tools/fetch_assets.py --only stockfish-macos-arm64

Default is the current OS/arch so a Linux checkout does not pull Windows and
macOS engines. Release CI fetches one target per job and Flutter bundles that
file into the app. macOS ships two downloads (Apple Silicon vs Intel), each
with the matching engine in the same `stockfish-macos.gz` slot.

Standard library only, so CI needs no pip install step.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import platform
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LOCKFILE = REPO_ROOT / "tools" / "assets.lock.json"

# --- Stockfish -------------------------------------------------------------
#
# Pinned deliberately. Tracking "latest" would make builds non-reproducible and
# let an upstream release break the app with no commit to point at. To upgrade:
# bump STOCKFISH_TAG, run with --force, verify the app still starts, and commit
# the regenerated assets.lock.json in the same commit.
STOCKFISH_TAG = "sf_18"
STOCKFISH_BASE = (
    f"https://github.com/official-stockfish/Stockfish/releases/download/{STOCKFISH_TAG}"
)

# CPU-baseline builds. Stockfish also publishes avx2/bmi2/avx512 variants that
# are meaningfully faster, but a binary built for an instruction set the user's
# CPU lacks dies with SIGILL at startup. Since this ships to end users rather
# than to a known machine, baseline is the correct default. If you only target
# modern hardware, swap in the -avx2 asset names below.
#
# macOS: Apple Silicon and Intel are different upstream archives, but both
# write `stockfish-macos.gz`. process_connection.dart has one macOS slot; the
# release workflow builds two apps and fetches the matching archive into that
# slot so users download the right architecture instead of a universal binary.
STOCKFISH_ASSETS = {
    "stockfish-linux": "stockfish-ubuntu-x86-64.tar",
    "stockfish-macos-arm64": "stockfish-macos-m1-apple-silicon.tar",
    "stockfish-macos-x86_64": "stockfish-macos-x86-64.tar",
    "stockfish-windows.exe": "stockfish-windows-x86-64.zip",
}

# Maia is NOT fetched. `assets/maia3_simplified.onnx` is a local torch.onnx.export
# artifact with no upstream equivalent -- CSSLab/maia3 publishes PyTorch
# checkpoints on Hugging Face and ships no ONNX at all -- so there is nothing to
# download and no release asset behind it. It stays tracked in git; its checksum,
# tensor contract, and known provenance live in tools/maia_model.lock.json. See
# "Regenerating the Maia model" in README.md.

TARGETS = {
    "stockfish-linux": {
        "dest": "assets/executables/stockfish-linux.gz",
        "url": f"{STOCKFISH_BASE}/{STOCKFISH_ASSETS['stockfish-linux']}",
    },
    "stockfish-macos-arm64": {
        "dest": "assets/executables/stockfish-macos.gz",
        "url": f"{STOCKFISH_BASE}/{STOCKFISH_ASSETS['stockfish-macos-arm64']}",
    },
    "stockfish-macos-x86_64": {
        "dest": "assets/executables/stockfish-macos.gz",
        "url": f"{STOCKFISH_BASE}/{STOCKFISH_ASSETS['stockfish-macos-x86_64']}",
    },
    "stockfish-windows": {
        "dest": "assets/executables/stockfish-windows.exe.gz",
        "url": f"{STOCKFISH_BASE}/{STOCKFISH_ASSETS['stockfish-windows.exe']}",
    },
}


def human(n: int) -> str:
    return f"{n / 1e6:.1f} MB"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def host_targets() -> list[str]:
    """Stockfish target(s) for the machine running this script."""
    plat = sys.platform
    machine = platform.machine().lower()
    if plat.startswith("linux"):
        return ["stockfish-linux"]
    if plat == "darwin":
        if machine in ("arm64", "aarch64"):
            return ["stockfish-macos-arm64"]
        return ["stockfish-macos-x86_64"]
    if plat == "win32":
        return ["stockfish-windows"]
    raise SystemExit(f"ERROR: unsupported platform {plat} ({machine})")


def load_lock() -> dict:
    if LOCKFILE.exists():
        return json.loads(LOCKFILE.read_text())
    return {}


def save_lock(lock: dict) -> None:
    LOCKFILE.parent.mkdir(parents=True, exist_ok=True)
    LOCKFILE.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")


def dest_is_current(name: str, dest: Path, lock: dict) -> bool:
    """True if `dest` exists and matches the lockfile output hash when present."""
    if not dest.exists():
        return False
    expected = lock.get(name, {}).get("output_sha256")
    if not expected:
        return True
    actual = sha256_file(dest)
    if actual == expected:
        return True
    print(
        f"[stale] {name}: {dest.relative_to(REPO_ROOT)} hash mismatch "
        f"(have {actual[:12]}…, want {expected[:12]}…) — re-fetching"
    )
    return False


def download(url: str, dest: Path) -> None:
    """Stream `url` to `dest`, with progress on a tty."""
    print(f"  downloading {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "chess-auto-prep-fetch"})
    try:
        with urllib.request.urlopen(req) as resp, dest.open("wb") as out:
            total = int(resp.headers.get("Content-Length") or 0)
            got = 0
            while True:
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                out.write(chunk)
                got += len(chunk)
                if sys.stderr.isatty() and total:
                    pct = 100 * got / total
                    print(
                        f"\r  {human(got)} / {human(total)} ({pct:.0f}%)",
                        end="",
                        file=sys.stderr,
                    )
    except urllib.error.HTTPError as exc:
        raise SystemExit(
            f"\nERROR: {url}\n  HTTP {exc.code} {exc.reason}\n"
            "  If this is the Maia model, the release asset may not exist yet -- "
            "see 'Regenerating the Maia model' in README.md."
        ) from exc
    if sys.stderr.isatty():
        print(file=sys.stderr)


def extract_stockfish_binary(archive: Path) -> bytes:
    """Pull the engine binary out of an upstream Stockfish tar/zip.

    The archives hold a `stockfish/` directory of docs, scripts and the engine.
    The engine is by far the largest member (~90 MB vs a few KB), so picking the
    largest regular file is robust across the tar and zip layouts without
    hardcoding the per-variant filename.
    """
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as zf:
            members = [m for m in zf.infolist() if not m.is_dir()]
            if not members:
                raise SystemExit(f"ERROR: {archive.name} is empty")
            biggest = max(members, key=lambda m: m.file_size)
            print(f"  extracting {biggest.filename} ({human(biggest.file_size)})")
            return zf.read(biggest)

    with tarfile.open(archive) as tf:
        members = [m for m in tf.getmembers() if m.isfile()]
        if not members:
            raise SystemExit(f"ERROR: {archive.name} is empty")
        biggest = max(members, key=lambda m: m.size)
        print(f"  extracting {biggest.name} ({human(biggest.size)})")
        fh = tf.extractfile(biggest)
        if fh is None:
            raise SystemExit(f"ERROR: could not read {biggest.name}")
        return fh.read()


def write_gz(payload: bytes, dest: Path) -> None:
    """gzip `payload` to `dest` as the app expects.

    process_connection.dart calls `gzip.decode` on the raw asset bytes, so this
    must be a plain gzip stream of the bare executable -- not a tar.gz. mtime is
    pinned to 0 so repeated runs produce byte-identical output and the lockfile
    hash stays meaningful.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(payload)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    tmp.write_bytes(buf.getvalue())
    tmp.replace(dest)


def fetch(name: str, spec: dict, lock: dict, force: bool) -> bool:
    """Returns True if the asset changed on disk."""
    dest = REPO_ROOT / spec["dest"]
    if dest_is_current(name, dest, lock) and not force:
        print(f"[ok]   {name}: {spec['dest']} present ({human(dest.stat().st_size)})")
        return False

    print(f"[get]  {name} -> {spec['dest']}")
    with tempfile.TemporaryDirectory() as td:
        # Keep the upstream filename: extract_stockfish_binary() dispatches on
        # the .zip/.tar suffix, so a generic temp name would send the Windows
        # zip down the tarfile path.
        tmp = Path(td) / os.path.basename(urllib.parse.urlparse(spec["url"]).path)
        download(spec["url"], tmp)

        digest = sha256_file(tmp)
        expected = lock.get(name, {}).get("source_sha256")
        if expected and digest != expected:
            raise SystemExit(
                f"ERROR: checksum mismatch for {name}\n"
                f"  expected {expected}\n  got      {digest}\n"
                "  Upstream artifact changed. Verify before trusting it, then "
                "re-run with --force to accept."
            )

        write_gz(extract_stockfish_binary(tmp), dest)

        lock[name] = {
            "url": spec["url"],
            "source_sha256": digest,
            "output_sha256": sha256_file(dest),
            "output_bytes": dest.stat().st_size,
        }
    print(f"       wrote {spec['dest']} ({human(dest.stat().st_size)})")
    return True


def check_targets(names: list[str], lock: dict) -> int:
    missing: list[str] = []
    mismatched: list[str] = []
    for n in names:
        dest = REPO_ROOT / TARGETS[n]["dest"]
        if not dest.exists():
            print(f"[MISS] {n}: {TARGETS[n]['dest']}")
            missing.append(n)
            continue
        expected = lock.get(n, {}).get("output_sha256")
        if expected and sha256_file(dest) != expected:
            print(f"[HASH] {n}: {TARGETS[n]['dest']} does not match assets.lock.json")
            mismatched.append(n)
            continue
        print(f"[ok  ] {n}: {TARGETS[n]['dest']}")
    if missing or mismatched:
        extra = ""
        if mismatched:
            extra = " Re-run with --force if the lockfile was updated."
        print(
            f"\n{len(missing) + len(mismatched)} asset(s) missing or stale. "
            f"Run: python3 tools/fetch_assets.py{' --only ' + ' --only '.join(names) if names != host_targets() else ''}."
            f"{extra}",
            file=sys.stderr,
        )
        return 1
    print("\nAll requested assets present.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="verify only, do not download")
    ap.add_argument("--force", action="store_true", help="re-download even if present")
    ap.add_argument(
        "--only",
        action="append",
        choices=sorted(TARGETS),
        help="subset (default: host platform only)",
    )
    args = ap.parse_args()

    names = args.only or host_targets()
    lock = load_lock()

    if args.check:
        return check_targets(names, lock)

    changed = False
    for n in names:
        changed |= fetch(n, TARGETS[n], lock, args.force)
    if changed:
        save_lock(lock)
        print(f"\nUpdated {LOCKFILE.relative_to(REPO_ROOT)} -- commit it.")
    print("\nDone. Assets are gitignored; re-run after a clean checkout.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
