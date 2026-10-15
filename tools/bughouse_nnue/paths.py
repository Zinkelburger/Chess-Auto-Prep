"""Where the NNUE toolchain, datasets and nets live.

Beside the archive under `~/.local/share/chess-prep/`, for the same reason
`bughouse_db` keeps the corpus there: a training set is gigabytes and must
never be swept into a Flutter build.  `BUGHOUSE_NNUE_HOME` relocates it.
"""

from __future__ import annotations

import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

#: The variant the site's board plays and the net is trained for.  Captures
#: leave the board and drops spend the hand; see `tools/bughouse_db/frozenhouse.ini`
#: for why the engine's own `bughouse` variant is never used.
VARIANT = "pocketknight"


def data_home() -> Path:
    override = os.environ.get("BUGHOUSE_NNUE_HOME")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".local/share/chess-prep/bughouse-nnue"


def toolchain_dir() -> Path:
    return data_home() / "toolchain"


def tools_binary() -> Path:
    """The variant-nnue-tools engine: Fairy-Stockfish plus the data commands."""
    return toolchain_dir() / "bin" / "variant-nnue-tools"


def trainer_dir() -> Path:
    return toolchain_dir() / "variant-nnue-pytorch"


def trainer_config_dir() -> Path:
    """`variant.h` and `variant.py` for pocketknight, as the tools write them."""
    return toolchain_dir() / "trainer-config"


def plain_dir() -> Path:
    """One plain-text file per archive year, plus its stats."""
    return data_home() / "plain"


def dataset_dir() -> Path:
    """The packed `.bin` files the trainer reads."""
    return data_home() / "dataset"


def nets_dir() -> Path:
    return data_home() / "nets"
