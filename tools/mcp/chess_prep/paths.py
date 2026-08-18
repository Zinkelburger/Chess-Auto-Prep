"""Where this tooling keeps its data.

Two kinds of file: the bundled directory (read-only, in the repo) and the
working files (roster, opponent list) in a per-user data directory. Nothing
here is shared with the app's own storage — the hand-off is the opponent list,
which the user points the app at explicitly.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# tools/mcp/chess_prep/paths.py -> repo root is three levels up.
REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent

DATA_DIR = Path(__file__).resolve().parent / "data"

#: Compact directory built by scripts/build_directory_assets.py.
ASSET_MAP = DATA_DIR / "uscf_chesscom_map.json"
ASSET_TITLED = DATA_DIR / "chesscom_titled.json"

#: Raw research output, used when the asset has not been regenerated yet.
SOURCE_MAP = REPO_ROOT / "scripts" / "data" / "player_mapping.json"

TITLED_DIR = REPO_ROOT / "scripts" / "chesscom_titled_analysis" / "data"

ROSTER_FILE_NAME = "roster.json"
OPPONENTS_FILE_NAME = "opponents.json"


def data_dir() -> Path:
    """Per-user working directory. Override with CHESS_PREP_DATA_DIR."""
    override = os.environ.get("CHESS_PREP_DATA_DIR")
    if override:
        return Path(override).expanduser()
    home = Path.home()
    if sys.platform == "darwin":
        return home / "Library" / "Application Support" / "chess-prep"
    if sys.platform == "win32":
        base = os.environ.get("APPDATA")
        return (Path(base) if base else home / "AppData" / "Roaming") / "chess-prep"
    base = os.environ.get("XDG_DATA_HOME")
    return (Path(base) if base else home / ".local" / "share") / "chess-prep"


def roster_path() -> Path:
    """The working roster. Override with CHESS_PREP_ROSTER (tests do)."""
    override = os.environ.get("CHESS_PREP_ROSTER")
    if override:
        return Path(override).expanduser()
    return data_dir() / ROSTER_FILE_NAME


def opponents_path() -> Path:
    """Default destination for `opponents_export`: next to the roster."""
    return roster_path().parent / OPPONENTS_FILE_NAME
