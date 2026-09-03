"""Where the Hivemind engine, its network and its ONNX runtime live.

Three sources, in order of how much the caller asked for it:

  1. ``HIVEMIND_BIN`` / ``HIVEMIND_MODEL`` / ``HIVEMIND_LIB`` — an explicit
     build, which is what you want while working on the engine itself.
  2. The desktop app's support directory. The app extracts the bundle on its
     first analysis, so once you have used Bughouse Lab the files are already
     unpacked and the server costs nothing.
  3. ``assets/bughouse/*.gz`` in this checkout, unpacked into
     ``~/.local/share/chess-prep/bughouse/``. The MCP server never writes
     inside the app's directory — the two share data read-only.
"""

from __future__ import annotations

import gzip
import os
import platform
import shutil
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ASSETS = REPO / "assets" / "bughouse"


def _app_support() -> Path:
    """Where the desktop app extracts its copy of the bundle.

    This mirrors `path_provider`'s `getApplicationSupportDirectory()` on each
    desktop platform, keyed off the same identifiers the Flutter runners are
    built with — `APPLICATION_ID` on Linux, `PRODUCT_BUNDLE_IDENTIFIER` on
    macOS, and the `CompanyName`/`ProductName` pair in `Runner.rc` on Windows.
    We only ever read from here; the server writes under `OWN_SUPPORT`.
    """
    system = platform.system()
    if system == "Windows":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData/Roaming"))
        return base / "com.example" / "Chess Auto Prep" / "bughouse"
    if system == "Darwin":
        return (
            Path.home()
            / "Library/Application Support/com.example.chessAutoPrep/bughouse"
        )
    return Path.home() / ".local/share/com.example.chess_auto_prep/bughouse"


APP_SUPPORT = _app_support()
OWN_SUPPORT = Path.home() / ".local/share/chess-prep/bughouse"


class EngineNotInstalled(Exception):
    """No engine anywhere. The message names the one command that fixes it."""

    def __init__(self, detail: str) -> None:
        super().__init__(
            f"{detail}\nRun `python3 tools/fetch_bughouse.py` to download "
            "the bundle (add `--hivemind <checkout>` to package a local engine "
            "build instead), or set HIVEMIND_BIN and HIVEMIND_MODEL to point "
            "at a build."
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
    return _from_directory(OWN_SUPPORT, "unpacked from assets/bughouse")


def locate(required: bool = True) -> EngineFiles | None:
    """The first engine that exists, or None (or a raised error) if there is
    no engine to find at all."""
    found = (
        _from_env()
        or _from_directory(APP_SUPPORT, "app support directory")
        or _from_directory(OWN_SUPPORT, "chess-prep support directory")
        or _unpack_assets()
    )
    if found is None and required:
        raise EngineNotInstalled(
            f"No Hivemind build found (looked in {APP_SUPPORT}, {OWN_SUPPORT} "
            f"and {ASSETS})."
        )
    if found is not None:
        missing = [str(p) for p in (found.binary, found.model) if not p.exists()]
        if missing and required:
            raise EngineNotInstalled(f"Missing: {', '.join(missing)}")
    return found
