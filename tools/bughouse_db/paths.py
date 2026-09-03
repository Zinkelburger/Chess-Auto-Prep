"""Where the bughouse archive and its book live.

Deliberately *not* under `assets/`: the corpus is 2.1 GB and must never be
swept into a Flutter build.  It sits beside the other data this repo's tools
generate, under `~/.local/share/chess-prep/`, and `BUGHOUSE_DB_HOME`
relocates the lot for anyone who keeps big corpora on another disk.
"""

from __future__ import annotations

import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def data_home() -> Path:
    override = os.environ.get("BUGHOUSE_DB_HOME")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".local/share/chess-prep/bughouse-db"


def corpus_dir() -> Path:
    return data_home() / "corpus"


def book_path() -> Path:
    return data_home() / "bughouse_book.db"


def manifest_path() -> Path:
    return corpus_dir() / "manifest.json"
