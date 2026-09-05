#!/usr/bin/env python3
"""Offline contract tests for the Windows VC++ installer prerequisite."""

from __future__ import annotations

import io
import json
import tempfile
from pathlib import Path

import fetch_vc_redist as redist


def expect_failure(action, text: str) -> None:
    try:
        action()
    except redist.VerificationError as exc:
        assert text in str(exc), exc
    else:
        raise AssertionError(f"expected VerificationError containing {text!r}")


def check_staging_dir(root: Path) -> None:
    """download() stages the file beside its destination, never in %TEMP%."""
    payload = b"staged bytes"
    destination = root / "prerequisites" / "VC_redist.x64.exe"
    staged: list[Path] = []

    def record(path: Path, _lock: dict) -> None:
        staged.append(Path(path))

    original_urlopen = redist.urllib.request.urlopen
    original_verify = redist.verify
    redist.urllib.request.urlopen = lambda *_a, **_k: io.BytesIO(payload)
    redist.verify = record
    try:
        redist.download({"url": "https://example.invalid"}, destination)
    finally:
        redist.urllib.request.urlopen = original_urlopen
        redist.verify = original_verify

    assert len(staged) == 1, staged
    assert staged[0].parent.parent == destination.parent, (
        f"staged in {staged[0].parent}, which is not inside {destination.parent}"
    )
    assert destination.read_bytes() == payload


def main() -> int:
    lock = redist.load_lock()
    assert lock["url"] == (
        "https://aka.ms/vs/17/release/14.44.35211/VC_redist.x64.exe"
    )
    assert lock["version"] == "14.44.35211.0"
    assert len(str(lock["sha256"])) == 64

    installer = (
        redist.REPO_ROOT / "packaging" / "windows" / "installer.iss"
    ).read_text(encoding="utf-8")
    assert f'#define VCRedistVersion "{lock["version"]}"' in installer
    assert f"#define VCRedistMajor {lock['major']}" in installer
    assert f"#define VCRedistMinor {lock['minor']}" in installer
    assert f"#define VCRedistBuild {lock['build']}" in installer
    assert 'Source: "{#VCRedistDir}\\VC_redist.x64.exe"' in installer
    assert "ShellExec(" in installer and "'/install /quiet /norestart'" in installer
    assert 'Excludes: "concrt140.dll,msvcp140*.dll,vcruntime140*.dll"' in installer

    deletes = installer.split('[InstallDelete]')[1].split('[Icons]')[0]
    for name in ('concrt140.dll', 'msvcp140.dll', 'msvcp140_1.dll',
                 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll',
                 'msvcp140_codecvt_ids.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'):
        assert f'Type: files; Name: "{{app}}\\{name}"' in deletes
    assert '*' not in deletes, 'upgrade cleanup must not delete unrelated files'

    release = (redist.REPO_ROOT / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8"
    )
    assert "runs-on: windows-2022" in release
    assert "Get-AuthenticodeSignature" in release
    assert "FileVersionRaw" in release
    assert "--windows-runtime-from" in release

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        missing = root / "missing.exe"
        expect_failure(lambda: redist.verify(missing, lock), "is missing")

        wrong_size = root / "VC_redist.x64.exe"
        wrong_size.write_bytes(b"MZ")
        expect_failure(lambda: redist.verify(wrong_size, lock), "expected 25635768")

        payload = root / "payload.bin"
        payload.write_bytes(b"known bytes")
        local_lock = {
            "bytes": payload.stat().st_size,
            "sha256": redist.sha256_file(payload),
        }
        redist.verify(payload, local_lock)
        local_lock["sha256"] = "0" * 64
        expect_failure(lambda: redist.verify(payload, local_lock), "SHA-256")

        incomplete = root / "lock.json"
        incomplete.write_text(json.dumps({"url": "https://example.invalid"}))
        expect_failure(lambda: redist.load_lock(incomplete), "is missing")

        # The download must be staged in the destination's own directory. On a
        # Windows runner %TEMP% is on C: and the workspace on D:, and the
        # os.replace that puts the file in place cannot cross a drive.
        check_staging_dir(root)

    print("vc_redist prerequisite tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
