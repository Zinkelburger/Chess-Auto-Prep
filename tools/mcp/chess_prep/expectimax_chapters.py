"""Expectimax trees shared with the app's Search tab.

The v2 app keeps each search it runs on a repertoire chapter as a v4
`tree.json` beside the chapter:

    <repertoire>/.cap-generation/<chapter>.pgn/v2-<run id>/tree.json

and its `Resume` button continues the newest one whose root is the position
on the board (`lib/v2/storage/generation_trees.dart`). The C builder reads
and writes the same format, so sharing a search needs no conversion — only
the same place and the same settings:

  * **place** — a run started with a chapter publishes its tree to
    `v2-agent-<run id>/tree.json` there when the build stops or finishes,
    replacing the file atomically so the app never reads half of one;
  * **settings** — the app resumes only a tree scored at its own engine depth
    (14), with no engine-loss window, for the chapter's side and the rating
    it is asked for (`readSearchSeed` in `lib/v2/workspace/fill_gaps.dart`),
    so a chapter run is held to exactly those;
  * **the other direction** — the app's own trees are read from the same
    folder and copied into a new run, never edited where they lie. A search
    the app ran without a depth limit records the horizon as 512, which the
    builder (at most 64) would refuse, so the copy carries the horizon asked
    for instead, never one shallower than the tree already goes.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from .tools import ToolError

CAP_GENERATION = ".cap-generation"
TREE_FILE = "tree.json"
RUN_PREFIX = "v2-"
AGENT_RUN_PREFIX = "agent-"

#: `fillEvalDepth` in lib/v2/workspace/fill_states.dart.
APP_EVAL_DEPTH = 14

#: `unboundedLossWire` and `unboundedDepthWire` in
#: lib/v2/chess/generation/tree_wire_v4.dart.
UNBOUNDED_LOSS_CP = 100000
UNBOUNDED_DEPTH = 512

#: The builder's own horizon limit (tree_builder/src/pure_search.c).
MAX_BUILDER_PLIES = 64

#: Where a run records what it published, beside `run.json`.
PUBLISH_FILE = "publish.json"


# ── The chapter ────────────────────────────────────────────────────────────


def resolve_chapter(value: Any) -> Path:
    """The chapter file a caller named: an existing `.pgn`, not a link."""
    if not isinstance(value, str) or not value.strip():
        raise ToolError("chapter must be the path of a repertoire chapter .pgn.")
    path = Path(os.path.abspath(Path(value.strip()).expanduser()))
    if path.suffix.lower() != ".pgn":
        raise ToolError(f"{path} is not a .pgn chapter file.")
    if path.is_symlink() or not path.is_file():
        raise ToolError(
            f"No chapter file at {path}. Chapters live in "
            "Documents/repertoires/<repertoire>/<chapter>.pgn; create the "
            "chapter in the app first."
        )
    return path


def chapter_color(chapter: Path) -> str | None:
    """The side in the chapter's `// Color: White|Black` heading, as w/b."""
    try:
        with chapter.open(encoding="utf-8", errors="replace") as fh:
            for _, line in zip(range(20), fh):
                text = line.strip()
                if not text.startswith("//"):
                    if text:
                        break
                    continue
                key, _, value = text[2:].partition(":")
                if key.strip().lower() == "color":
                    side = value.strip().lower()
                    if side in ("white", "black"):
                        return side[0]
    except OSError:
        return None
    return None


def trees_dir(chapter: Path) -> Path:
    return chapter.parent / CAP_GENERATION / chapter.name


def publish_folder(chapter: Path, run_id: str) -> Path:
    return trees_dir(chapter) / f"{RUN_PREFIX}{AGENT_RUN_PREFIX}{run_id}"


# ── Reading saved trees ────────────────────────────────────────────────────


def _read(path: Path) -> dict | None:
    try:
        with path.open(encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("tree"), dict):
        return None
    return data


def saved_trees(chapter: Path) -> list[dict]:
    """Every search tree kept for this chapter, by the app or a run, newest first."""
    folder = trees_dir(chapter)
    if folder.is_symlink() or not folder.is_dir():
        return []
    rows = []
    for entry in folder.iterdir():
        if not entry.name.startswith(RUN_PREFIX) or entry.is_symlink():
            continue
        path = entry / TREE_FILE
        if path.is_symlink() or not path.is_file():
            continue
        data = _read(path)
        if data is None:
            continue
        config = data.get("config") or {}
        rows.append(
            {
                "run": entry.name,
                "by": "agent" if entry.name.startswith(RUN_PREFIX + AGENT_RUN_PREFIX) else "app",
                "path": str(path),
                "fen": data["tree"].get("fen"),
                "color": "w" if config.get("play_as_white") else "b",
                "nodes": data.get("total_nodes"),
                "deepest_ply": data.get("max_depth"),
                "horizon": _horizon(config),
                "complete": data.get("build_complete"),
                "opponent_rating": config.get("maia_elo"),
                "eval_depth": config.get("eval_depth"),
                "evaluation_source": data.get("v2_evaluation_source", "stockfish"),
                "modified": time.strftime(
                    "%Y-%m-%dT%H:%M:%S", time.localtime(path.stat().st_mtime)
                ),
                "_mtime": path.stat().st_mtime,
            }
        )
    rows.sort(key=lambda r: r["_mtime"], reverse=True)
    for row in rows:
        del row["_mtime"]
    return rows


def _horizon(config: dict) -> int | None:
    depth = config.get("max_depth")
    if not isinstance(depth, (int, float)) or depth >= UNBOUNDED_DEPTH:
        return None
    return int(depth)


def newest_tree(chapter: Path, fen: str | None = None) -> dict:
    """The tree the app's Resume would pick: the newest one starting at fen."""
    rows = saved_trees(chapter)
    if fen is not None:
        rows = [r for r in rows if r["fen"] == fen]
    if not rows:
        where = f" starting at {fen}" if fen else ""
        raise ToolError(f"No saved search{where} beside {chapter.name}.")
    return rows[0]


def seed_document(data: dict, plies: int | None) -> tuple[dict, dict]:
    """A saved tree made ready for the builder to continue, and its settings.

    Refuses what the builder would value differently from the app — another
    search method, an evaluation source other than Stockfish, a pruning
    window — rather than letting one tree mix two kinds of number.
    """
    config = data.get("config")
    root = data.get("tree")
    if data.get("version") != 4 or not isinstance(config, dict) or not isinstance(root, dict):
        raise ToolError("That tree is not a v4 saved search.")
    if config.get("algorithm_version") not in (None, 3) or root.get("history_aware") is not True:
        raise ToolError("That tree was built by the older heuristic search.")
    if config.get("search_algorithm") not in (None, "pure"):
        raise ToolError(f"That tree was built by the {config['search_algorithm']} search.")
    source = data.get("v2_evaluation_source", "stockfish")
    if source != "stockfish":
        raise ToolError(
            f"That search scored positions with {source}; only Stockfish "
            "searches can be continued here."
        )
    for key in ("eval_depth", "maia_elo"):
        if not isinstance(config.get(key), int):
            raise ToolError(f"That tree does not record its {key}.")
    if not isinstance(config.get("play_as_white"), bool) or not isinstance(root.get("fen"), str):
        raise ToolError("That tree does not say which side or position it is for.")

    deepest = int(data.get("max_depth") or 0)
    saved = _horizon(config)
    if plies is None:
        plies = saved if saved is not None else max(deepest, 1)
    plies = int(plies)
    if plies > MAX_BUILDER_PLIES:
        raise ToolError(f"plies must be at most {MAX_BUILDER_PLIES}.")
    if plies < max(deepest, saved or 0, 1):
        raise ToolError(
            f"The saved search already reaches ply {max(deepest, saved or 0)}; "
            "plies can only stay or grow."
        )
    loss = config.get("max_eval_loss_cp")
    if not isinstance(loss, int):
        raise ToolError("That tree does not record its engine-loss window.")

    doc = dict(data)
    doc["config"] = dict(config, max_depth=plies)
    doc.pop("v2_evaluation_source", None)
    settings = {
        "fen": root["fen"],
        "color": "w" if config["play_as_white"] else "b",
        "plies": plies,
        "eval_depth": config["eval_depth"],
        "maia_elo": config["maia_elo"],
        "max_eval_loss": loss,
    }
    return doc, settings


# ── Settings the app can resume ────────────────────────────────────────────


def app_build_args(args: dict) -> dict:
    """The build arguments of a chapter run: the app's settings or a refusal."""
    if args.get("search") not in (None, "", "pure"):
        raise ToolError("A chapter search must be pure; the app has no fast search.")
    if args.get("eval_depth") not in (None, "", APP_EVAL_DEPTH):
        raise ToolError(
            f"A chapter search is scored at engine depth {APP_EVAL_DEPTH}, the "
            "app's own; the app cannot resume another depth."
        )
    if args.get("max_eval_loss") not in (None, "", UNBOUNDED_LOSS_CP):
        raise ToolError(
            "A chapter search keeps every move, as the app's does; leave "
            "max_eval_loss out."
        )
    return dict(
        args,
        search="pure",
        eval_depth=APP_EVAL_DEPTH,
        max_eval_loss=UNBOUNDED_LOSS_CP,
    )


# ── Publishing ─────────────────────────────────────────────────────────────


def publish(tree: Path, chapter: Path, run_id: str) -> Path:
    """Put a run's tree where the app's Resume finds it, replacing it whole."""
    data = _read(tree)
    if data is None:
        raise ToolError(f"{tree} is not a readable saved tree.")
    if chapter.is_symlink() or not chapter.is_file():
        raise ToolError(f"The chapter {chapter} is no longer there.")
    folder = publish_folder(chapter, run_id)
    for parent in (folder.parent.parent, folder.parent, folder):
        if parent.is_symlink():
            raise ToolError(f"{parent} is a link; not writing through it.")
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / TREE_FILE
    stage = folder / f".{TREE_FILE}.{os.getpid()}.tmp"
    with stage.open("wb") as fh:
        fh.write(tree.read_bytes())
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(stage, target)
    try:
        fd = os.open(folder, os.O_RDONLY)
    except OSError:
        return target
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)
    return target


def read_publish_record(directory: Path) -> dict | None:
    data = _read_json(directory / PUBLISH_FILE)
    return data if isinstance(data, dict) else None


def write_publish_record(directory: Path, record: dict) -> None:
    path = directory / PUBLISH_FILE
    stage = directory / f".{PUBLISH_FILE}.tmp"
    stage.write_text(json.dumps(record, indent=2), encoding="utf-8")
    os.replace(stage, path)


def _read_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def open_in_app(chapter: Path, line: str, color: str, elo: int) -> str:
    side = "White" if color == "w" else "Black"
    where = f"after {line}" if line else "at the start"
    return (
        f"In the app open {chapter.parent.name} ▸ {chapter.stem}, put the board "
        f"{where} with {side} at the bottom, set Opponent to {elo} in the "
        "Search tab and press Resume: the values show at once and the search "
        "carries on from them (Stop keeps what it has)."
    )
