"""Expectimax opening-tree runs, driven from an agent.

Answers one question: *in this position, which of my candidate moves scores
best?* — not by asking an engine for its top line, but by building a tree in
which Maia supplies the opponent's replies with probabilities and Stockfish
supplies the evaluations, then folding it back with expectimax. The number
that comes out is a practical win probability against a human of a given
strength, which is a different (and usually more useful) ranking than raw
centipawns.

The engine work is `tree_builder/`, the standalone C reference implementation
of the algorithm — nothing here reimplements the chess. This layer owns the
three things that made running it by hand tedious:

  * **the toolchain** — the builder needs Stockfish, the Maia ONNX model, and
    link-time `libonnxruntime`/`libcurl`, none of which are installed system
    -wide on a typical dev box. `prepare_toolchain` unpacks the binary the app
    ships, builds a symlink farm for the shared libraries out of the pub cache,
    and compiles the builder once into `tree_builder/bin/`.
  * **the position** — callers think in move lists ("1. d4 Nf6 2. Nf3 g6"),
    the builder wants a FEN, and asking for "best move for Black" only makes
    sense at a position with Black to move. That mismatch is caught here with
    an error that says how to fix it, rather than silently scoring the wrong
    side.
  * **the wait** — a real build is tens of minutes, so `expectimax_run`
    returns as soon as the process is up and the rest is polling. Stopping is
    not destructive: the build is breadth-first and resumable, so
    `expectimax_result` can score a partial tree and `expectimax_resume` can
    carry on afterwards.

Runs are directories, like everything else this server produces, so a run
survives the session that started it.
"""

from __future__ import annotations

import gzip
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from .engine_tournament import documents_dir
from .paths import REPO_ROOT, data_dir
from .tools import ToolError

RUNS_DIR_NAME = "expectimax_runs"

#: Every run writes `<BASE>.pgn`, `<BASE>.tree.json` and `<BASE>.db`.
BASE = "tree"
RUN_FILE = "run.json"
LOG_FILE = "build.log"

BUILDER_DIR = REPO_ROOT / "tree_builder"
BUILDER_BIN = BUILDER_DIR / "bin" / "tree_builder"
MAIA_MODEL = REPO_ROOT / "assets" / "maia3_simplified.onnx"
ENGINES_DIR = REPO_ROOT / "assets" / "executables"

#: `make` on a cold tree_builder is ~40 s; give it room.
BUILD_TIMEOUT = 900.0

#: Scoring a saved tree (`--build-now`) re-verifies the selected moves with a
#: deeper search, so it is not instant.
SCORE_TIMEOUT = 900.0

#: The builder always gives the root at least this many candidates, whatever
#: `multipv` says (src/main.c: `root_multipv = our_multipv < 10 ? 10 : ...`).
ROOT_MULTIPV_FLOOR = 10


# ── Locations ──────────────────────────────────────────────────────────────


def runs_dir() -> Path:
    """Where runs live. Override with CHESS_PREP_EXPECTIMAX_DIR."""
    override = os.environ.get("CHESS_PREP_EXPECTIMAX_DIR")
    if override:
        return Path(override).expanduser()
    return documents_dir() / RUNS_DIR_NAME


def toolchain_dir() -> Path:
    """Unpacked Stockfish and the shared-library symlink farm.

    Override with CHESS_PREP_EXPECTIMAX_TOOLCHAIN.
    """
    override = os.environ.get("CHESS_PREP_EXPECTIMAX_TOOLCHAIN")
    if override:
        return Path(override).expanduser()
    return data_dir() / "expectimax-toolchain"


# ── Toolchain ──────────────────────────────────────────────────────────────


def _packaged_stockfish() -> Path | None:
    name = {"linux": "stockfish-linux.gz", "darwin": "stockfish-macos.gz"}.get(
        "linux" if sys.platform.startswith("linux") else sys.platform
    )
    if not name:
        return None
    candidate = ENGINES_DIR / name
    return candidate if candidate.is_file() else None


def resolve_stockfish() -> Path:
    """A Stockfish binary, unpacking the one the app ships if need be.

    Order: CHESS_PREP_STOCKFISH, then PATH, then `assets/executables/`. The
    unpacked copy is cached and only rewritten when the archive is newer, so
    this costs nothing after the first call.
    """
    override = os.environ.get("CHESS_PREP_STOCKFISH")
    if override:
        path = Path(override).expanduser()
        if not path.is_file():
            raise ToolError(f"CHESS_PREP_STOCKFISH points at nothing: {path}")
        return path

    found = shutil.which("stockfish")
    if found:
        return Path(found)

    archive = _packaged_stockfish()
    if archive is None:
        raise ToolError(
            "No Stockfish. Put one on PATH or set CHESS_PREP_STOCKFISH — this "
            f"platform ({sys.platform}) has no binary in {ENGINES_DIR}."
        )

    out = toolchain_dir() / "stockfish"
    if out.is_file() and out.stat().st_mtime >= archive.stat().st_mtime:
        return out

    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".partial")
    try:
        with gzip.open(archive, "rb") as src, tmp.open("wb") as dst:
            shutil.copyfileobj(src, dst)
        tmp.chmod(0o755)
        tmp.replace(out)
    except OSError as e:
        tmp.unlink(missing_ok=True)
        raise ToolError(f"Could not unpack {archive.name}: {e}") from None
    return out


def _library_candidates(stem: str) -> list[Path]:
    """Real files a `-l<stem>` could point at, best first.

    The pub cache is preferred over the Flutter build directory because a
    build directory is disposable and may not exist at all.
    """
    out: list[Path] = []
    if stem == "onnxruntime":
        pub = Path.home() / ".pub-cache" / "hosted" / "pub.dev"
        if pub.is_dir():
            for pkg in sorted(pub.glob("onnxruntime-*/linux/libonnxruntime.so*")):
                out.append(pkg)
        out += sorted(
            (REPO_ROOT / "build").glob("**/lib/libonnxruntime.so.*"),
        )
    for root in ("/usr/lib64", "/usr/lib", "/usr/local/lib"):
        base = Path(root)
        if not base.is_dir():
            continue
        exact = base / f"lib{stem}.so"
        if exact.exists():
            out.append(exact)
        out += sorted(base.glob(f"lib{stem}.so.*"))
    return [p for p in out if p.is_file()]


def _link_farm() -> Path:
    """A directory the linker and loader can both find the libraries in.

    Fedora ships `libcurl.so.4` but not the `-devel` symlink, and ONNX Runtime
    usually is not packaged at all — the copy that exists is the one Flutter
    pulled into the pub cache. Rather than ask for `dnf install`, symlink what
    is already on the machine under both the link name (`libcurl.so`) and the
    SONAME the loader will ask for (`libonnxruntime.so.1.15.1`).
    """
    lib = toolchain_dir() / "lib"
    lib.mkdir(parents=True, exist_ok=True)
    missing: list[str] = []
    for stem in ("onnxruntime", "curl"):
        candidates = _library_candidates(stem)
        if not candidates:
            missing.append(f"lib{stem}")
            continue
        target = candidates[0]
        for name in {f"lib{stem}.so", target.name}:
            link = lib / name
            if link.is_symlink() and link.resolve() == target.resolve():
                continue
            link.unlink(missing_ok=True)
            link.symlink_to(target)
    if missing:
        raise ToolError(
            "Could not find " + ", ".join(missing) + " anywhere on this "
            "machine. Install the runtime (not necessarily the -devel "
            "package) and try again."
        )
    return lib


def build_env(lib: Path) -> dict:
    """Environment that lets the builder link and then load its libraries."""
    env = dict(os.environ)
    for var in ("LIBRARY_PATH", "LD_LIBRARY_PATH"):
        existing = env.get(var)
        env[var] = f"{lib}{os.pathsep}{existing}" if existing else str(lib)
    return env


def prepare_toolchain(rebuild: bool = False) -> dict:
    """Everything a run needs, compiling the builder on first use."""
    if not BUILDER_DIR.is_dir():
        raise ToolError(f"Missing {BUILDER_DIR} — is this the right repo?")
    if not MAIA_MODEL.is_file():
        raise ToolError(
            f"Missing the Maia model at {MAIA_MODEL}. Run "
            "`python tools/fetch_assets.py` to download it."
        )

    stockfish = resolve_stockfish()
    lib = _link_farm()
    env = build_env(lib)

    built = False
    if rebuild or not BUILDER_BIN.is_file():
        jobs = str(max(1, (os.cpu_count() or 2) // 2))
        try:
            result = subprocess.run(  # noqa: S603 - our own Makefile
                ["make", "-j", jobs],
                cwd=str(BUILDER_DIR),
                env=env,
                capture_output=True,
                text=True,
                timeout=BUILD_TIMEOUT,
            )
        except FileNotFoundError:
            raise ToolError("`make` is not installed.") from None
        except subprocess.TimeoutExpired:
            raise ToolError(
                f"Building tree_builder took longer than {BUILD_TIMEOUT:.0f}s."
            ) from None
        if result.returncode != 0 or not BUILDER_BIN.is_file():
            tail = "\n".join((result.stderr or result.stdout).strip().splitlines()[-12:])
            raise ToolError(f"Building tree_builder failed:\n{tail}")
        built = True

    return {
        "builder": BUILDER_BIN,
        "stockfish": stockfish,
        "maia_model": MAIA_MODEL,
        "lib": lib,
        "env": env,
        "built_now": built,
    }


# ── Position ───────────────────────────────────────────────────────────────


def resolve_position(
    moves: Any = None, fen: str | None = None, color: str | None = None
) -> dict:
    """Turn a move list (and/or FEN) into the FEN the builder wants.

    `color` is optional and defaults to whoever is to move. Passing the other
    colour is refused rather than guessed at: a line written out to "5... c5"
    ends with White to move, so asking for Black's best move there is almost
    always a request about the position one ply earlier, and only the caller
    knows which they meant.
    """
    try:
        import chess
    except ImportError:
        raise ToolError(
            "python-chess is not installed: pip install -r "
            "tools/mcp/requirements.txt"
        ) from None

    from .opening import parse_move_list

    try:
        board = chess.Board(fen) if fen else chess.Board()
    except ValueError as e:
        raise ToolError(f"Not a legal FEN: {e}") from None

    tokens = parse_move_list(moves)
    played: list[str] = []
    for token in tokens:
        try:
            move = board.parse_san(token)
        except ValueError:
            try:
                move = chess.Move.from_uci(token.lower())
            except ValueError:
                move = None
            if move is None or move not in board.legal_moves:
                context = " ".join(played) or (
                    "the position you gave" if fen else "the starting position"
                )
                raise ToolError(
                    f'"{token}" is not a legal move after {context}.'
                ) from None
        played.append(board.san(move))
        board.push(move)

    to_move = "w" if board.turn else "b"
    if color:
        wanted = color.strip().lower()[:1]
        if wanted not in ("w", "b"):
            raise ToolError('color must be "w" or "b".')
        if wanted != to_move:
            side = "White" if to_move == "w" else "Black"
            other = "Black" if to_move == "w" else "White"
            hint = ""
            if played:
                hint = (
                    f' Drop the last move ("{played[-1]}") to score {other}\'s '
                    "options at that point instead."
                )
            raise ToolError(
                f"You asked for {other}'s best move, but after this line it is "
                f"{side} to move.{hint}"
            )
    else:
        color = to_move

    return {
        "fen": board.fen(),
        "color": to_move,
        "line": " ".join(played),
        "ply": len(played),
    }


# ── Run state ──────────────────────────────────────────────────────────────


def _pid_alive(pid: int) -> bool:
    """Whether that process is still doing work.

    A finished build is a zombie until its parent reaps it, and this server
    *is* the parent — so `kill(pid, 0)` alone reports a run that ended hours
    ago as still going. Reap it if we can, and otherwise read the state out of
    /proc, before falling back to the signal probe.
    """
    try:
        reaped, _ = os.waitpid(pid, os.WNOHANG)
        if reaped == pid:
            return False
    except (ChildProcessError, OSError, AttributeError, ValueError):
        pass  # not our child, or a platform without waitpid

    stat = Path(f"/proc/{pid}/stat")
    if stat.is_file():
        try:
            # "pid (comm) state ..." — comm can contain spaces and brackets.
            fields = stat.read_text(encoding="utf-8").rpartition(")")[2].split()
            if fields:
                return fields[0] != "Z"
        except OSError:
            pass

    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _read_run(directory: Path) -> dict:
    path = directory / RUN_FILE
    try:
        with path.open(encoding="utf-8") as fh:
            state = json.load(fh)
    except (OSError, json.JSONDecodeError):
        raise ToolError(f"{directory.name} is not an expectimax run.") from None
    if not isinstance(state, dict):
        raise ToolError(f"{directory.name} has an unreadable {RUN_FILE}.")
    pid = state.get("pid")
    state["running"] = bool(pid) and _pid_alive(int(pid))
    return state


def _write_run(directory: Path, state: dict) -> None:
    state = {k: v for k, v in state.items() if k != "running"}
    (directory / RUN_FILE).write_text(
        json.dumps(state, indent=2), encoding="utf-8"
    )


def _dirs(root: Path) -> list[Path]:
    if not root.is_dir():
        return []
    return [d for d in root.iterdir() if d.is_dir() and (d / RUN_FILE).is_file()]


def resolve_id(root: Path, wanted: str | None) -> Path:
    """A run directory by id, defaulting to the most recent."""
    directories = _dirs(root)
    if not directories:
        raise ToolError(
            f"No expectimax runs in {root}. Start one with expectimax_run."
        )
    if wanted:
        for d in directories:
            if d.name == wanted:
                return d
        matches = [d for d in directories if d.name.startswith(wanted)]
        if len(matches) == 1:
            return matches[0]
        if matches:
            names = ", ".join(sorted(d.name for d in matches))
            raise ToolError(f'"{wanted}" matches several runs: {names}')
        raise ToolError(f'No run called "{wanted}" in {root}.')
    return max(directories, key=lambda d: d.stat().st_mtime)


def _progress(directory: Path) -> dict:
    """What the build log says, without parsing the whole thing."""
    log = directory / LOG_FILE
    if not log.is_file():
        return {}
    try:
        text = log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    nodes = elapsed = None
    for line in reversed(text.splitlines()):
        stripped = line.strip()
        if stripped.startswith("Depth ") and " complete:" in stripped:
            body = stripped.split(" complete:", 1)[1]
            parts = [p.strip() for p in body.split(",")]
            for part in parts:
                if part.endswith(" nodes"):
                    try:
                        nodes = int(part.split()[0])
                    except ValueError:
                        pass
                elif part.endswith("elapsed"):
                    elapsed = part.rsplit(" ", 1)[0]
            break
    out: dict = {}
    if nodes is not None:
        out["nodes_last_batch"] = nodes
    if elapsed:
        out["elapsed"] = elapsed
    tail = [ln for ln in text.strip().splitlines() if ln.strip()]
    if tail:
        out["log_tail"] = tail[-1].strip()
    return out


def _has_expectimax(tree_path: Path) -> bool:
    """Whether the expectimax stage has already run over this saved tree."""
    try:
        with tree_path.open(encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return False
    root = data.get("tree")
    return isinstance(root, dict) and root.get("expectimax_value") is not None


def _tree_summary(directory: Path) -> dict:
    path = directory / f"{BASE}.tree.json"
    if not path.is_file():
        return {"tree_saved": False}
    try:
        with path.open(encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {"tree_saved": False}
    # Named for what it is: the builder rewrites the tree at checkpoints and
    # on the way out, so a running build's count is behind. `nodes_last_batch`
    # from the log is the live signal.
    return {
        "tree_saved": True,
        "nodes_at_last_save": data.get("total_nodes"),
        "max_ply": data.get("max_depth"),
        "build_complete": data.get("build_complete"),
    }


# ── Reading the answer back ────────────────────────────────────────────────


def _leaf_plies(node: dict) -> list[int]:
    children = node.get("children") or []
    if not children:
        return [node.get("depth", 0)]
    out: list[int] = []
    for child in children:
        out += _leaf_plies(child)
    return out


def _subtree_size(node: dict) -> int:
    return 1 + sum(_subtree_size(c) for c in node.get("children") or [])


def root_table(tree_path: Path) -> dict:
    """The ranking: every candidate at the root with its expectimax value.

    `search` reports how much of the tree each candidate actually got. The
    builder spends its budget where the value is, so the move on top is
    normally the best-searched one — which is worth seeing, because on a build
    stopped early a thin candidate's number is the least trustworthy.
    """
    try:
        with tree_path.open(encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        raise ToolError(f"Could not read {tree_path.name}: {e}") from None

    root = data.get("tree")
    if not isinstance(root, dict):
        raise ToolError(f"{tree_path.name} has no tree in it yet.")

    children = root.get("children") or []
    if not children:
        raise ToolError(
            "The root has no candidate moves yet — the build was stopped "
            "before it finished the first ply."
        )

    rows = []
    for child in children:
        value = child.get("expectimax_value")
        plies = _leaf_plies(child)
        rows.append(
            {
                "move": child.get("move_san") or child.get("move_uci"),
                "expectimax": round(value, 4) if value is not None else None,
                "eval_cp": child.get("engine_eval_cp"),
                "nodes": _subtree_size(child),
                "max_ply": max(plies),
                "avg_leaf_ply": round(sum(plies) / len(plies), 2),
            }
        )
    rows.sort(key=lambda r: (r["expectimax"] is None, -(r["expectimax"] or 0)))

    scored = [r for r in rows if r["expectimax"] is not None]
    margin = None
    if len(scored) >= 2:
        margin = round(scored[0]["expectimax"] - scored[1]["expectimax"], 4)

    return {
        "best": scored[0]["move"] if scored else None,
        "margin_over_second": margin,
        "root_expectimax": (
            round(root["expectimax_value"], 4)
            if root.get("expectimax_value") is not None
            else None
        ),
        "candidates": rows,
        "total_nodes": data.get("total_nodes"),
        "max_ply": data.get("max_depth"),
        "build_complete": data.get("build_complete"),
    }


# ── Building the command line ──────────────────────────────────────────────


def builder_argv(chain: dict, base: Path, position: dict, args: dict) -> list[str]:
    argv = [
        str(chain["builder"]),
        "-c",
        position["color"],
        "-f",
        position["fen"],
        "-S",
        str(chain["stockfish"]),
        "--maia-model",
        str(chain["maia_model"]),
        "-v",
    ]

    def add(flag: str, key: str, default: Any, cast=int) -> None:
        value = args.get(key)
        value = default if value in (None, "") else cast(value)
        if value is not None:
            argv.extend([flag, str(value)])

    add("-d", "plies", 8)
    add("-e", "eval_depth", 16)
    add("-t", "threads", max(1, (os.cpu_count() or 2) - 1))
    add("-p", "min_probability", 0.01, float)
    add("--our-multipv", "multipv", 5)
    add("--max-eval-loss", "max_eval_loss", 40)
    add("--opp-max-children", "opp_max_children", 3)
    add("--opp-mass", "opp_mass", 0.85, float)
    add("--maia-elo", "maia_elo", 2200)
    add("--maia-min-prob", "maia_min_prob", 0.08, float)

    name = (args.get("name") or "").strip()
    if name:
        argv.extend(["-n", name])
    argv.append(str(base))
    return argv


def argv_with(argv: list[str], *extra: str) -> list[str]:
    """Add flags to a stored command line, keeping the base name last."""
    return list(argv[:-1]) + list(extra) + [argv[-1]]


def argv_with_plies(argv: list[str], plies: int) -> list[str]:
    out = list(argv)
    if "-d" in out:
        out[out.index("-d") + 1] = str(plies)
        return out
    return argv_with(out, "-d", str(plies))


def _slug(text: str) -> str:
    keep = [c if c.isalnum() else "-" for c in text.lower()]
    slug = "".join(keep).strip("-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return slug[:40] or "run"


# ── Tools ──────────────────────────────────────────────────────────────────


def register_expectimax_tools(registry: Any) -> None:
    from .tools import _b, _i, _n, _obj, _s

    def _root() -> Path:
        return runs_dir()

    def _score(directory: Path, state: dict, chain: dict) -> dict:
        """Run the builder's expectimax/selection stage over a saved tree.

        Deliberately *not* `--resume`: that restores flags from the database,
        and the database remembers `build_now` once it has seen it (see
        src/main.c), so a resumed run would skip building for ever after. The
        original command line is on disk — reuse it and add `--build-now`.
        """
        argv = argv_with(_build_argv(directory, state, chain), "--build-now")
        log = directory / "score.log"
        try:
            with log.open("wb") as fh:
                result = subprocess.run(  # noqa: S603 - our own tool
                    argv,
                    stdout=fh,
                    stderr=subprocess.STDOUT,
                    stdin=subprocess.DEVNULL,
                    cwd=str(BUILDER_DIR),
                    env=chain["env"],
                    timeout=SCORE_TIMEOUT,
                )
        except subprocess.TimeoutExpired:
            raise ToolError(
                f"Scoring the tree took longer than {SCORE_TIMEOUT:.0f}s."
            ) from None
        if result.returncode != 0:
            tail = log.read_text(encoding="utf-8", errors="replace")
            tail = "\n".join(tail.strip().splitlines()[-12:])
            raise ToolError(f"Scoring failed:\n{tail}")
        return root_table(directory / f"{BASE}.tree.json")

    def _build_argv(directory: Path, state: dict, chain: dict) -> list[str]:
        """The command line this run was started with, still runnable.

        The builder path is refreshed from the toolchain so a run started
        before the repo moved (or before a rebuild) still works.
        """
        argv = state.get("build_argv") or state.get("argv")
        if not isinstance(argv, list) or len(argv) < 2:
            raise ToolError(
                f"{directory.name} has no usable command line in {RUN_FILE}."
            )
        return [str(chain["builder"])] + [str(a) for a in argv[1:]]

    def _stop(state: dict, timeout: float = 300.0) -> bool:
        """Interrupt a build so it saves its partial tree. Not destructive."""
        pid = state.get("pid")
        if not pid or not _pid_alive(int(pid)):
            return False
        try:
            os.kill(int(pid), signal.SIGINT)
        except OSError as e:
            raise ToolError(f"Could not stop the build: {e}") from None
        deadline = time.time() + timeout
        while time.time() < deadline:
            if not _pid_alive(int(pid)):
                return True
            time.sleep(0.5)
        raise ToolError(
            f"The build (pid {pid}) has not stopped after {timeout:.0f}s. It "
            "saves its tree on the way out, so give it a moment and retry."
        )

    # ── run ────────────────────────────────────────────────────────────────

    def expectimax_run(args: dict) -> dict:
        position = resolve_position(
            args.get("moves"), args.get("fen"), args.get("color")
        )
        chain = prepare_toolchain()

        root = _root()
        root.mkdir(parents=True, exist_ok=True)
        label = _slug(args.get("name") or position["line"] or "position")
        directory = root / f"{label}-{time.strftime('%Y%m%d-%H%M%S')}"
        directory.mkdir(parents=True, exist_ok=True)

        argv = builder_argv(chain, directory / BASE, position, args)
        log_path = directory / LOG_FILE
        try:
            with log_path.open("wb") as log:
                process = subprocess.Popen(  # noqa: S603 - our own tool
                    argv,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    stdin=subprocess.DEVNULL,
                    cwd=str(BUILDER_DIR),
                    env=chain["env"],
                    start_new_session=True,
                )
        except OSError as e:
            raise ToolError(f"Could not start the build: {e}") from None

        state = {
            "pid": process.pid,
            "build_argv": argv,
            "position": position,
            "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "log": str(log_path),
        }
        _write_run(directory, state)

        multipv = int(args.get("multipv") or 5)
        return {
            "started": True,
            "id": directory.name,
            "line": position["line"],
            "fen": position["fen"],
            "color": "White" if position["color"] == "w" else "Black",
            "root_candidates": max(ROOT_MULTIPV_FLOOR, multipv),
            "plies": int(args.get("plies") or 8),
            "directory": str(directory),
            "log": str(log_path),
            "pid": process.pid,
            "toolchain_built_now": chain["built_now"],
            "next": (
                "The build runs in the background and can take tens of "
                "minutes. Poll expectimax_status; call expectimax_result when "
                "you want the ranking (it stops the build first, which is "
                "safe — expectimax_resume carries on from there)."
            ),
        }

    # ── status ─────────────────────────────────────────────────────────────

    def expectimax_status(args: dict) -> dict:
        directory = resolve_id(_root(), args.get("id"))
        state = _read_run(directory)
        out = {
            "id": directory.name,
            "running": state["running"],
            "started_at": state.get("startedAt"),
            "line": (state.get("position") or {}).get("line"),
            "color": (state.get("position") or {}).get("color"),
            "directory": str(directory),
        }
        out.update(_progress(directory))
        out.update(_tree_summary(directory))
        # "Finished" means the build reached the depth it was asked for.
        # Not just "the process is gone" (an interrupted run is gone too), and
        # not "a PGN exists" (scoring a partial tree writes one of those).
        out["finished"] = not state["running"] and bool(
            out.get("build_complete")
        )
        out["pgn"] = (
            str(directory / f"{BASE}.pgn")
            if (directory / f"{BASE}.pgn").is_file()
            else None
        )
        return out

    def expectimax_list(args: dict) -> dict:
        limit = int(args.get("limit") or 25)
        rows = []
        for directory in sorted(
            _dirs(_root()), key=lambda d: d.stat().st_mtime, reverse=True
        )[:limit]:
            try:
                state = _read_run(directory)
            except ToolError:
                continue
            position = state.get("position") or {}
            row = {
                "id": directory.name,
                "running": state["running"],
                "line": position.get("line"),
                "color": position.get("color"),
                "started_at": state.get("startedAt"),
            }
            row.update(_tree_summary(directory))
            rows.append(row)
        return {"runs": rows, "directory": str(_root())}

    # ── result ─────────────────────────────────────────────────────────────

    def expectimax_result(args: dict) -> dict:
        directory = resolve_id(_root(), args.get("id"))
        state = _read_run(directory)

        stopped = False
        if state["running"]:
            if not args.get("stop_first", True):
                raise ToolError(
                    f"{directory.name} is still building. Pass stop_first "
                    "(the default) to score what it has, or poll "
                    "expectimax_status."
                )
            stopped = _stop(state)

        tree = directory / f"{BASE}.tree.json"
        if not tree.is_file():
            raise ToolError(
                f"{directory.name} has no tree yet — the build had not got "
                "far enough to save one."
            )

        # A run that reached the end scored itself on the way out; only a tree
        # saved by an interrupt needs the expectimax stage run over it.
        scored = False
        if _has_expectimax(tree):
            table = root_table(tree)
        else:
            table = _score(directory, state, prepare_toolchain())
            scored = True
        position = state.get("position") or {}
        table.update(
            {
                "id": directory.name,
                "line": position.get("line"),
                "fen": position.get("fen"),
                "color": (
                    "White" if position.get("color") == "w" else "Black"
                ),
                "stopped_build": stopped,
                "scored_now": scored,
                "pgn": str(directory / f"{BASE}.pgn"),
                "note": (
                    "expectimax is a practical win probability for the side to "
                    "move; eval_cp is Stockfish after the move from White's "
                    "side, so lower is better for Black. Uneven nodes/"
                    "avg_leaf_ply across candidates means the build was "
                    "stopped early — resume it before trusting close calls."
                ),
            }
        )
        return table

    def expectimax_stop(args: dict) -> dict:
        directory = resolve_id(_root(), args.get("id"))
        state = _read_run(directory)
        if not state["running"]:
            return {"id": directory.name, "stopped": False, "running": False}
        _stop(state)
        out = {"id": directory.name, "stopped": True, "running": False}
        out.update(_tree_summary(directory))
        return out

    def expectimax_resume(args: dict) -> dict:
        directory = resolve_id(_root(), args.get("id"))
        state = _read_run(directory)
        if state["running"]:
            raise ToolError(f"{directory.name} is already building.")

        chain = prepare_toolchain()
        argv = _build_argv(directory, state, chain)
        if args.get("plies") is not None:
            argv = argv_with_plies(argv, int(args["plies"]))

        log_path = directory / LOG_FILE
        try:
            with log_path.open("ab") as log:
                process = subprocess.Popen(  # noqa: S603 - our own tool
                    argv,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    stdin=subprocess.DEVNULL,
                    cwd=str(BUILDER_DIR),
                    env=chain["env"],
                    start_new_session=True,
                )
        except OSError as e:
            raise ToolError(f"Could not resume the build: {e}") from None

        state["pid"] = process.pid
        state["build_argv"] = argv
        state["resumedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        _write_run(directory, state)
        return {
            "id": directory.name,
            "resumed": True,
            "pid": process.pid,
            "plies": args.get("plies"),
            "next": "Poll expectimax_status; expectimax_result for the ranking.",
        }

    # ── Registration ───────────────────────────────────────────────────────

    registry._add(
        "expectimax_run",
        "Start an expectimax opening-tree build and return immediately. Maia "
        "supplies the opponent's replies with probabilities, Stockfish the "
        "evaluations, and folding the tree back gives each candidate a "
        "practical win probability rather than a centipawn score — which is "
        "the number you want when several moves are objectively equal. Give "
        "it a move list ('1. d4 Nf6 2. Nf3 g6') or a FEN. The root always "
        f"gets at least {ROOT_MULTIPV_FLOOR} candidates, so it answers 'which "
        "of my many options here' directly. Builds take tens of minutes; they "
        "are breadth-first and resumable, so stopping early still gives a "
        "usable answer.",
        _obj(
            {
                "moves": _s(
                    "The line, as SAN ('1. d4 Nf6 2. Nf3 g6') or a list. "
                    "Applied from the starting position, or from fen if given."
                ),
                "fen": _s("Starting position (default: the game start)."),
                "color": _s(
                    'Side to build for, "w" or "b". Defaults to whoever is to '
                    "move; passing the other side is refused, because a line "
                    "ending on Black's move is White to move."
                ),
                "name": _s("Label for the run and the PGN headers."),
                "plies": _i("Depth in half-moves (default 8)."),
                "eval_depth": _i("Stockfish search depth per node (default 16)."),
                "multipv": _i(
                    "Candidates at our non-root moves (default 5). The root "
                    f"always gets at least {ROOT_MULTIPV_FLOOR}."
                ),
                "max_eval_loss": _i(
                    "Drop our candidates worse than the best by this many "
                    "centipawns (default 40)."
                ),
                "opp_max_children": _i(
                    "Maia replies kept per opponent move (default 3)."
                ),
                "opp_mass": _n(
                    "Probability mass to cover per opponent move (default "
                    "0.85)."
                ),
                "maia_elo": _i("Strength Maia predicts for (default 2200)."),
                "maia_min_prob": _n(
                    "Ignore Maia replies below this probability (default 0.08)."
                ),
                "min_probability": _n(
                    "Stop exploring a line below this cumulative probability "
                    "(default 0.01)."
                ),
                "threads": _i(
                    "Parallel Stockfish engines (default: cores minus one)."
                ),
            }
        ),
        expectimax_run,
    )

    registry._add(
        "expectimax_result",
        "The answer: every candidate move at the root with its expectimax "
        "value, engine eval, and how much of the tree it actually got. Stops "
        "the build first if it is still going — that is safe and reversible, "
        "because the builder saves its tree on the way out and "
        "expectimax_resume picks up where it left off. Defaults to the most "
        "recent run.",
        _obj(
            {
                "id": _s("Run id (default: the most recent)."),
                "stop_first": _b(
                    "Stop a running build and score what it has (default "
                    "true). Set false to refuse rather than interrupt."
                ),
            }
        ),
        expectimax_result,
    )

    registry._add(
        "expectimax_status",
        "How a build is going: whether its process is up, how far the tree "
        "has got, and the last progress line. Defaults to the most recent run.",
        _obj({"id": _s("Run id (default: the most recent).")}),
        expectimax_status,
    )

    registry._add(
        "expectimax_list",
        "Every saved run, newest first: the line, the side, how big the tree "
        "got, and whether it is still building.",
        _obj({"limit": _i("Max rows (default 25).")}),
        expectimax_list,
    )

    registry._add(
        "expectimax_stop",
        "Interrupt a running build. It saves its partial tree on the way out, "
        "so nothing is lost — score it with expectimax_result or carry on "
        "with expectimax_resume.",
        _obj({"id": _s("Run id (default: the most recent).")}),
        expectimax_stop,
    )

    registry._add(
        "expectimax_resume",
        "Carry on building a stopped run, optionally to a greater depth. Every "
        "evaluation already computed is cached, so resuming is much cheaper "
        "than starting over.",
        _obj(
            {
                "id": _s("Run id (default: the most recent)."),
                "plies": _i("New depth in half-moves (default: as before)."),
            }
        ),
        expectimax_resume,
    )
