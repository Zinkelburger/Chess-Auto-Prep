#!/usr/bin/env python3
"""Fetch the pinned official Microsoft VC++ x64 installer prerequisite.

The executable is generated release input, not source: it is downloaded from
Microsoft into packaging/windows/prerequisites/, checked against the committed
size and SHA-256, and then embedded inside the Inno Setup installer. It is not
placed in the installed application directory and it is not part of the
portable zip.

    python3 tools/fetch_vc_redist.py
    python3 tools/fetch_vc_redist.py --check
    python3 tools/fetch_vc_redist.py --force
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tempfile
import urllib.error
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
LOCKFILE = REPO_ROOT / "tools" / "vc_redist.lock.json"
DESTINATION = (
    REPO_ROOT / "packaging" / "windows" / "prerequisites" / "VC_redist.x64.exe"
)


class VerificationError(Exception):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_lock(path: Path = LOCKFILE) -> dict[str, object]:
    data = json.loads(path.read_text(encoding="utf-8"))
    required = {"url", "version", "major", "minor", "build", "bytes", "sha256"}
    missing = sorted(required - data.keys())
    if missing:
        raise VerificationError(f"{path} is missing: {', '.join(missing)}")
    return data


def verify(path: Path, lock: dict[str, object]) -> None:
    if not path.is_file():
        raise VerificationError(f"{path} is missing")
    actual_size = path.stat().st_size
    expected_size = int(lock["bytes"])
    if actual_size != expected_size:
        raise VerificationError(
            f"{path} is {actual_size} bytes; expected {expected_size}"
        )
    actual_hash = sha256_file(path)
    expected_hash = str(lock["sha256"]).lower()
    if actual_hash != expected_hash:
        raise VerificationError(
            f"{path} SHA-256 is {actual_hash}; expected {expected_hash}"
        )


def download(lock: dict[str, object], destination: Path = DESTINATION) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        str(lock["url"]), headers={"User-Agent": "chess-auto-prep-release"}
    )
    try:
        with tempfile.TemporaryDirectory() as temp_dir:
            temporary = Path(temp_dir) / destination.name
            with urllib.request.urlopen(request) as response, temporary.open("wb") as out:
                shutil.copyfileobj(response, out)
            verify(temporary, lock)
            temporary.replace(destination)
    except urllib.error.URLError as exc:
        raise VerificationError(
            f"could not download the Microsoft VC++ prerequisite: {exc}"
        ) from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="verify without downloading")
    parser.add_argument("--force", action="store_true", help="download even if already valid")
    args = parser.parse_args()

    try:
        lock = load_lock()
        if args.check:
            verify(DESTINATION, lock)
        elif not args.force:
            try:
                verify(DESTINATION, lock)
            except VerificationError:
                print(f"[get]  Microsoft VC++ x64 {lock['version']}")
                download(lock)
        else:
            print(f"[get]  Microsoft VC++ x64 {lock['version']}")
            download(lock)
        verify(DESTINATION, lock)
    except (OSError, ValueError, VerificationError) as exc:
        print(f"ERROR: {exc}")
        return 1

    print(
        f"[ok]   {DESTINATION.relative_to(REPO_ROOT)} "
        f"({DESTINATION.stat().st_size / 1e6:.1f} MB, {lock['version']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
