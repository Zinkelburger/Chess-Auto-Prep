#!/usr/bin/env python3
"""Verify the checked-in Maia model and vocabulary against their lock file."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "tools" / "maia_model.lock.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    manifest = json.loads(LOCK.read_text(encoding="utf-8"))
    entries = [manifest["model"], *manifest["vocabulary"]]
    failures: list[str] = []

    for entry in entries:
        path = ROOT / entry["path"]
        if not path.is_file():
            failures.append(f"missing: {entry['path']}")
            continue
        size = path.stat().st_size
        digest = sha256(path)
        if size != entry["bytes"]:
            failures.append(
                f"size mismatch: {entry['path']} ({size}, expected {entry['bytes']})"
            )
        if digest != entry["sha256"]:
            failures.append(f"checksum mismatch: {entry['path']}")

    if failures:
        print("Maia asset verification failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(f"Maia assets verified ({len(entries)} files).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
