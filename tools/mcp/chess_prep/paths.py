"""Locating the repo's data files and the shared roster.

The roster is the contract between this server and the Flutter app: both read
and write the same JSON file, so an agent can build a field with the app shut
and the app picks it up when it opens (or live, since it watches the file).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# ── Repo data ───────────────────────────────────────────────────────────────

# tools/mcp/chess_prep/paths.py -> repo root is three levels up.
REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent

#: Compact directory shipped with the app. Preferred: it is what the app uses,
#: so the two agree by construction.
ASSET_MAP = REPO_ROOT / "assets" / "data" / "uscf_chesscom_map.json"
ASSET_TITLED = REPO_ROOT / "assets" / "data" / "chesscom_titled.json"

#: Raw research output, used when the asset has not been regenerated yet.
SOURCE_MAP = REPO_ROOT / "scripts" / "data" / "player_mapping.json"

TITLED_DIR = REPO_ROOT / "scripts" / "chesscom_titled_analysis" / "data"


# ── Shared roster ───────────────────────────────────────────────────────────

ROSTER_FILE_NAME = "tournament_session.json"

#: path_provider keys the support directory off the platform's *application
#: identifier*, not the Dart package name. On Linux that is the CMake
#: APPLICATION_ID (`com.example.chess_auto_prep`), on macOS the bundle id
#: (`com.example.chessAutoPrep`). Guessing the package name instead lands in a
#: directory the app never writes to, and the two halves silently never meet.
_LINUX_APP_IDS = ["com.example.chess_auto_prep", "chess_auto_prep"]
_MACOS_APP_IDS = ["com.example.chessAutoPrep", "chess_auto_prep"]
_WINDOWS_APP_IDS = ["com.example\\chess_auto_prep", "chess_auto_prep"]


def _support_roots() -> list[Path]:
    home = Path.home()
    if sys.platform == "darwin":
        base = home / "Library" / "Application Support"
        return [base / name for name in _MACOS_APP_IDS]
    if sys.platform == "win32":
        env = os.environ.get("APPDATA")
        base = Path(env) if env else home / "AppData" / "Roaming"
        return [base / name for name in _WINDOWS_APP_IDS]
    env = os.environ.get("XDG_DATA_HOME")
    base = Path(env) if env else home / ".local" / "share"
    return [base / name for name in _LINUX_APP_IDS]


def app_support_dir() -> Path:
    """The directory Flutter's getApplicationSupportDirectory() resolves to.

    Candidates are probed for evidence the app actually uses them (the roster
    itself, or files the app is known to write) before falling back to the
    first. Kept in step with `tools/mcp/chess_prep_mcp.mjs`, which resolves the
    same directory to find the app's MCP endpoint descriptor.
    """
    candidates = _support_roots()

    for directory in candidates:
        if (directory / ROSTER_FILE_NAME).exists():
            return directory
    # No roster yet: fall back to whichever directory the app has clearly
    # been using, so the first write lands where the app will look.
    for directory in candidates:
        if any(
            (directory / marker).exists()
            for marker in ("shared_preferences.json", "eval_cache.db", "repertoires")
        ):
            return directory
    return candidates[0]


def roster_path() -> Path:
    """The shared roster file. Override with CHESS_PREP_ROSTER (tests do)."""
    override = os.environ.get("CHESS_PREP_ROSTER")
    if override:
        return Path(override)
    return app_support_dir() / ROSTER_FILE_NAME
