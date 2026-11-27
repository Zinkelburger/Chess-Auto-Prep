"""Where the Hivemind engine, its network and its ONNX runtime live.

Hivemind is no longer the app's engine (the app's Bughouse mode runs
HypeBeast), so it is fetched for the tools alone. Two sources, in order of how
much the caller asked for it:

  1. ``HIVEMIND_BIN`` / ``HIVEMIND_MODEL`` / ``HIVEMIND_LIB`` — an explicit
     build, which is what you want while working on the engine itself.
  2. ``tools/hivemind-engine/*.gz`` in this checkout, written by
     ``python3 tools/fetch_assets.py --only hivemind`` and unpacked into
     ``~/.local/share/chess-prep/bughouse/`` (used as it is when the
     checkout has no fetch of its own).
"""

from __future__ import annotations

import gzip
import os
import platform
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, overload

REPO = Path(__file__).resolve().parents[3]
# The tool-only fetch target; tools/fetch_assets.py HIVEMIND_ASSETS.
ASSETS = REPO / "tools" / "hivemind-engine"


OWN_SUPPORT = Path.home() / ".local/share/chess-prep/bughouse"


class EngineNotInstalled(Exception):
    """No engine anywhere. The message names the one command that fixes it."""

    def __init__(self, detail: str) -> None:
        super().__init__(
            f"{detail}\nRun `python3 tools/fetch_assets.py --only hivemind` to "
            "download it, or set HIVEMIND_BIN and HIVEMIND_MODEL to point at a "
            "build."
        )


def binary_name() -> str:
    return {
        "Windows": "hivemind-windows.exe",
        "Darwin": "hivemind-macos",
    }.get(platform.system(), "hivemind-linux")


def runtime_name() -> str:
    return {
        "Windows": "onnxruntime.dll",
        "Darwin": "libonnxruntime.dylib",
    }.get(platform.system(), "libonnxruntime.so.1")


@dataclass(frozen=True)
class EngineFiles:
    binary: Path
    model: Path
    library_dir: Path | None
    source: str

    def as_dict(self) -> dict:
        return {
            "binary": str(self.binary),
            "model": str(self.model),
            "library_dir": str(self.library_dir) if self.library_dir else None,
            "source": self.source,
        }


def _from_env() -> EngineFiles | None:
    binary, model = os.environ.get("HIVEMIND_BIN"), os.environ.get("HIVEMIND_MODEL")
    if not binary or not model:
        return None
    lib = os.environ.get("HIVEMIND_LIB")
    return EngineFiles(
        binary=Path(binary),
        model=Path(model),
        library_dir=Path(lib) if lib else None,
        source="environment",
    )


def _from_directory(directory: Path, source: str) -> EngineFiles | None:
    binary, model = directory / binary_name(), directory / "hivemind.onnx"
    if not (binary.exists() and model.exists()):
        return None
    return EngineFiles(
        binary=binary,
        model=model,
        library_dir=directory if (directory / runtime_name()).exists() else None,
        source=source,
    )


def _unpack_assets() -> EngineFiles | None:
    """Ungzip the checkout's bundle into our own support directory."""
    wanted = {
        binary_name(): OWN_SUPPORT / binary_name(),
        runtime_name(): OWN_SUPPORT / runtime_name(),
        "hivemind.onnx": OWN_SUPPORT / "hivemind.onnx",
    }
    if not all((ASSETS / f"{name}.gz").exists() for name in wanted):
        return None
    OWN_SUPPORT.mkdir(parents=True, exist_ok=True)
    for name, target in wanted.items():
        source = ASSETS / f"{name}.gz"
        if target.exists() and target.stat().st_mtime >= source.stat().st_mtime:
            continue
        # Unpack beside the target and rename into place. Writing the 54 MB
        # network straight to its final path means one interrupted run leaves a
        # truncated file that the mtime check then skips forever, and the only
        # symptom is an engine that will not load.
        tmp = target.with_name(target.name + f".part{os.getpid()}")
        try:
            with gzip.open(source, "rb") as fin, open(tmp, "wb") as fout:
                shutil.copyfileobj(fin, fout)
            os.replace(tmp, target)
        finally:
            tmp.unlink(missing_ok=True)
    wanted[binary_name()].chmod(0o755)
    return _from_directory(OWN_SUPPORT, "unpacked from tools/hivemind-engine")


def _refreshed_assets() -> EngineFiles | None:
    """[_unpack_assets], but a failed unpack (a full disk) leaves the copy
    already there in use rather than failing the lookup."""
    try:
        return _unpack_assets()
    except OSError:
        return None


@overload
def locate(required: Literal[True] = True) -> EngineFiles: ...
@overload
def locate(required: bool) -> EngineFiles | None: ...
def locate(required: bool = True) -> EngineFiles | None:
    """The first engine that exists, or None (or a raised error) if there is
    no engine to find at all."""
    # The bundle is unpacked (a no-op when the copy is current) before the
    # copy is looked at: taking the copy first meant a bundle refreshed by
    # `fetch_assets.py` was never unpacked, and the old engine ran forever.
    found = (
        _from_env()
        or _refreshed_assets()
        or _from_directory(OWN_SUPPORT, "chess-prep support directory")
    )
    if found is None and required:
        raise EngineNotInstalled(
            f"No Hivemind build found (looked in {ASSETS} and {OWN_SUPPORT})."
        )
    if found is not None:
        missing = [str(p) for p in (found.binary, found.model) if not p.exists()]
        if missing and required:
            raise EngineNotInstalled(f"Missing: {', '.join(missing)}")
    return found
