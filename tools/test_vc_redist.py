#!/usr/bin/env python3
"""Offline contract tests for the Windows VC++ installer prerequisite."""

from __future__ import annotations

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

    print("vc_redist prerequisite tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
