"""Reading and writing the trainer's plain-text records."""

from __future__ import annotations

from pathlib import Path
from typing import Iterator

FIELDS = ("fen", "move", "score", "ply", "result")


def iter_records(path: Path) -> Iterator[str]:
    """Each record as its own text, `fen …\\n…\\ne\\n`, streamed from `path`."""
    lines: list[str] = []
    with open(path) as handle:
        for line in handle:
            lines.append(line)
            if line == "e\n":
                yield "".join(lines)
                lines = []


def parse(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        key, _, value = line.partition(" ")
        if key in FIELDS:
            out[key] = value
    return out


def with_score(text: str, score: int) -> str:
    return "".join(
        f"score {score}\n" if line.startswith("score ") else line
        for line in text.splitlines(keepends=True)
    )


def count(path: Path) -> int:
    n = 0
    with open(path, "rb") as handle:
        for line in handle:
            if line == b"e\n":
                n += 1
    return n
