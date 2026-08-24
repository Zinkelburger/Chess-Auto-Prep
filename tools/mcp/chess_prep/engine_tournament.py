"""Engine-vs-engine tournaments, driven from an agent.

The hand-off pattern is the one this server already uses everywhere: files.
A tournament is a directory under ``Documents/engine_tournaments`` holding
``tournament.json`` and ``games.pgn``, and "show me this in the app" is a
request file the app watches. Nothing here talks to a running app directly,
so it works the same whether the app is open, closed, or opened afterwards.

The chess itself is *not* reimplemented here. Starting a match, verifying a
binary, and computing standings all shell out to
``tools/run_engine_tournament.dart``, which is the same code the app runs —
so the Elo, Sonneborn-Berger and likelihood-of-superiority numbers an agent
quotes are the numbers on screen, not a second implementation of them.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from .paths import REPO_ROOT
from .tools import ToolError

TOURNAMENTS_DIR_NAME = "engine_tournaments"
METADATA_FILE = "tournament.json"
PGN_FILE = "games.pgn"
ENGINES_FILE = "engines.json"
OPEN_REQUEST_FILE = "open_request.json"
RUN_FILE = "run.json"

#: Handshake the Dart runner prints as soon as it has allocated a directory.
HANDSHAKE_PREFIX = "TOURNAMENT "

#: `dart run` has to compile the tool the first time; later runs are cached.
DEFAULT_STARTUP_TIMEOUT = 180.0

#: Reads (`--show`, `--verify`) are short but still pay the VM start.
DEFAULT_READ_TIMEOUT = 180.0


# ── Locations ──────────────────────────────────────────────────────────────


def documents_dir() -> Path:
    """Mirror of what path_provider hands the app for documents."""
    home = Path.home()
    if sys.platform == "darwin":
        return home / "Documents"
    if sys.platform == "win32":
        profile = os.environ.get("USERPROFILE")
        return (Path(profile) if profile else home) / "Documents"
    xdg = os.environ.get("XDG_DOCUMENTS_DIR")
    return Path(xdg) if xdg else home / "Documents"


def tournaments_dir() -> Path:
    """Where tournaments live. Override with CHESS_PREP_TOURNAMENTS_DIR."""
    override = os.environ.get("CHESS_PREP_TOURNAMENTS_DIR")
    if override:
        return Path(override).expanduser()
    return documents_dir() / TOURNAMENTS_DIR_NAME


def runner_script() -> Path:
    return REPO_ROOT / "tools" / "run_engine_tournament.dart"


def dart_executable() -> str:
    """The Dart VM to run the tool with.

    Prefers the Flutter SDK's own copy: the tool imports the app's packages,
    and a standalone Dart that does not match the SDK the project pins will
    fail to resolve them.
    """
    override = os.environ.get("CHESS_PREP_DART")
    if override:
        return override

    flutter = shutil.which("flutter")
    if flutter:
        candidate = Path(flutter).resolve().parent / "dart"
        if candidate.exists():
            return str(candidate)

    for base in ("~/sdk/flutter", "~/flutter", "~/development/flutter"):
        candidate = Path(base).expanduser() / "bin" / "dart"
        if candidate.exists():
            return str(candidate)

    found = shutil.which("dart")
    if found:
        return found

    raise ToolError(
        "Could not find the Dart VM. Put the Flutter SDK's bin/ on PATH or "
        "set CHESS_PREP_DART to its `dart`."
    )


# ── Reading what is on disk ────────────────────────────────────────────────


def _dirs(root: Path) -> list[Path]:
    if not root.is_dir():
        return []
    return [d for d in root.iterdir() if d.is_dir() and (d / METADATA_FILE).is_file()]


def _read_metadata(directory: Path) -> dict | None:
    try:
        with (directory / METADATA_FILE).open(encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _summary(directory: Path, data: dict) -> dict:
    config = data.get("config") or {}
    games = data.get("games") or []
    engines = [e.get("name") for e in (config.get("engines") or [])]
    per_pairing = int(config.get("gamesPerPairing") or 0)
    pairings = max(1, len(engines) * (len(engines) - 1) // 2) if engines else 1
    if (config.get("format") or "roundRobin") == "gauntlet" and len(engines) > 1:
        pairings = len(engines) - 1
    return {
        "id": directory.name,
        "name": config.get("name"),
        "status": data.get("status"),
        "created_at": data.get("createdAt"),
        "finished_at": data.get("finishedAt"),
        "engines": engines,
        "start_fen": config.get("startFen"),
        "opening": config.get("openingLabel") or None,
        "time_control": _time_control_label(config.get("timeControl") or {}),
        "games_played": len(games),
        "games_total": per_pairing * pairings,
        "directory": str(directory),
        "pgn": str(directory / PGN_FILE),
        "error": data.get("error"),
        "running": _run_state(directory)["running"],
    }


def _time_control_label(tc: dict) -> str:
    kind = tc.get("kind")
    if kind == "movetime":
        return f"{(tc.get('movetimeMs') or 0) / 1000:g}s/move"
    if kind == "incremental":
        base = (tc.get("baseMs") or 0) / 1000
        inc = (tc.get("incrementMs") or 0) / 1000
        period = tc.get("movesPerSession")
        head = f"{period}/" if period else ""
        tail = f"+{inc:g}s" if inc else ""
        return f"{head}{base:g}s{tail}"
    if kind == "fixedDepth":
        return f"depth {tc.get('depth')}"
    if kind == "fixedNodes":
        return f"{tc.get('nodes')} nodes"
    return "unknown"


def resolve_id(root: Path, wanted: str | None) -> Path:
    """A named tournament, or the most recently created one."""
    directories = _dirs(root)
    if not directories:
        raise ToolError(
            f"No tournaments in {root}. Start one with tournament_run."
        )
    if wanted:
        match = root / wanted
        if not (match / METADATA_FILE).is_file():
            names = ", ".join(sorted(d.name for d in directories)[:12])
            raise ToolError(f'No tournament "{wanted}". Available: {names}')
        return match

    def created(d: Path) -> str:
        data = _read_metadata(d) or {}
        return str(data.get("createdAt") or "")

    return max(directories, key=created)


# ── The running process ────────────────────────────────────────────────────


def _run_state(directory: Path) -> dict:
    """What tournament_run recorded, plus whether that process is still up."""
    path = directory / RUN_FILE
    if not path.is_file():
        return {"running": False}
    try:
        with path.open(encoding="utf-8") as fh:
            state = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {"running": False}
    pid = state.get("pid")
    state["running"] = bool(pid) and _pid_alive(int(pid))
    return state


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _app_running() -> bool | None:
    """Whether the desktop app is up. None when we cannot tell."""
    if sys.platform == "win32":
        try:
            out = subprocess.run(
                ["tasklist", "/FI", "IMAGENAME eq chess_auto_prep.exe"],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        return "chess_auto_prep.exe" in out.stdout
    if not shutil.which("pgrep"):
        return None
    try:
        out = subprocess.run(
            ["pgrep", "-f", "chess_auto_prep"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    # Our own command line can match the pattern; ignore this process.
    pids = [p for p in out.stdout.split() if p.strip() and int(p) != os.getpid()]
    return bool(pids)


def _app_launch_command() -> list[str] | None:
    override = os.environ.get("CHESS_AUTO_PREP_BIN")
    if override and Path(override).exists():
        return [override]

    if sys.platform == "darwin":
        for flavour in ("Release", "Debug"):
            bundle = (
                REPO_ROOT
                / "build"
                / "macos"
                / "Build"
                / "Products"
                / flavour
                / "chess_auto_prep.app"
            )
            if bundle.exists():
                return ["open", "-a", str(bundle)]
    elif sys.platform == "win32":
        for flavour in ("Release", "Debug"):
            exe = (
                REPO_ROOT
                / "build"
                / "windows"
                / "x64"
                / "runner"
                / flavour
                / "chess_auto_prep.exe"
            )
            if exe.exists():
                return [str(exe)]
    else:
        for flavour in ("release", "debug"):
            exe = (
                REPO_ROOT
                / "build"
                / "linux"
                / "x64"
                / flavour
                / "bundle"
                / "chess_auto_prep"
            )
            if exe.exists():
                return [str(exe)]

    found = shutil.which("chess_auto_prep")
    return [found] if found else None


# ── Shelling out to the Dart tool ──────────────────────────────────────────


def _dart_json(argv: list[str], timeout: float) -> dict:
    """Run the tool and parse the last line of stdout as JSON.

    The last line, not the whole of stdout: `dart run` prefixes build-hook
    chatter that is not ours to suppress.
    """
    command = [dart_executable(), "run", str(runner_script()), *argv]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(REPO_ROOT),
        )
    except subprocess.TimeoutExpired:
        raise ToolError(
            f"`{' '.join(command[-3:])}` did not finish in {timeout:g}s."
        ) from None
    except OSError as e:
        raise ToolError(f"Could not run the Dart tool: {e}") from None

    for line in reversed((completed.stdout or "").splitlines()):
        candidate = line.strip()
        # The build-hook banner is printed without a newline, so the JSON can
        # share its line.
        brace = candidate.find("{")
        if brace < 0:
            continue
        try:
            parsed = json.loads(candidate[brace:])
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed

    detail = (completed.stderr or completed.stdout or "").strip()[-800:]
    raise ToolError(f"The Dart tool printed no JSON (exit {completed.returncode}).\n{detail}")


# ── Tools ──────────────────────────────────────────────────────────────────


def register_engine_tournament_tools(registry: Any) -> None:
    from .tools import _b, _i, _obj, _s

    def _root() -> Path:
        return tournaments_dir()

    # ── run ────────────────────────────────────────────────────────────────

    def tournament_run(args: dict) -> dict:
        root = _root()
        root.mkdir(parents=True, exist_ok=True)
        script = runner_script()
        if not script.is_file():
            raise ToolError(f"Missing {script}.")

        argv = [dart_executable(), "run", str(script), "--root", str(root)]

        name = (args.get("name") or "").strip()
        if name:
            argv += ["--name", name]
        fen = (args.get("fen") or "").strip()
        if fen:
            argv += ["--fen", fen]
        opening = (args.get("opening") or "").strip()
        if opening:
            argv += ["--opening", opening]

        games = args.get("games")
        if games is not None:
            if int(games) < 1:
                raise ToolError("games must be at least 1.")
            argv += ["--games", str(int(games))]

        # One time control, not three.
        chosen = [
            k
            for k in ("movetime_ms", "tc", "depth")
            if args.get(k) not in (None, "")
        ]
        if len(chosen) > 1:
            raise ToolError(
                f"Pick one time control, not {len(chosen)}: {', '.join(chosen)}."
            )
        if args.get("movetime_ms") is not None:
            argv += ["--movetime", str(int(args["movetime_ms"]))]
        elif args.get("tc"):
            argv += ["--tc", str(args["tc"])]
        elif args.get("depth") is not None:
            argv += ["--depth", str(int(args["depth"]))]

        if args.get("concurrency") is not None:
            argv += ["--concurrency", str(int(args["concurrency"]))]
        for entry in args.get("engines") or []:
            argv += ["--engine", str(entry)]

        logs = root / ".runs"
        logs.mkdir(parents=True, exist_ok=True)
        log_path = logs / f"run-{int(time.time() * 1000)}.log"

        try:
            with log_path.open("wb") as log:
                process = subprocess.Popen(  # noqa: S603 - our own tool
                    argv,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    stdin=subprocess.DEVNULL,
                    cwd=str(REPO_ROOT),
                    start_new_session=True,
                )
        except OSError as e:
            raise ToolError(f"Could not start the tournament: {e}") from None

        timeout = float(args.get("startup_timeout") or DEFAULT_STARTUP_TIMEOUT)
        handshake = _await_handshake(process, log_path, timeout)

        directory = Path(handshake["directory"])
        (directory / RUN_FILE).write_text(
            json.dumps(
                {
                    "pid": process.pid,
                    "log": str(log_path),
                    "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    "argv": argv,
                },
                indent=2,
            ),
            encoding="utf-8",
        )

        opened = None
        if args.get("open_app", True):
            opened = _open(directory.name, root, args.get("launch", "auto"))

        return {
            "started": True,
            "id": directory.name,
            "games_total": handshake.get("totalGames"),
            "time_control": handshake.get("timeControl"),
            "start_fen": handshake.get("startFen"),
            "directory": handshake.get("directory"),
            "pgn": handshake.get("pgn"),
            "log": str(log_path),
            "pid": process.pid,
            "opened_in_app": opened,
            "next": (
                "Games are played one at a time and written as they finish. "
                "Poll tournament_status for progress; tournament_crosstable "
                "for the standings."
            ),
        }

    def _await_handshake(
        process: subprocess.Popen, log_path: Path, timeout: float
    ) -> dict:
        """Wait for the runner to say which directory it took.

        It prints that line before the first engine thinks, so this returns
        long before the match does — but after a cold `dart run` compile,
        which is what the generous default timeout is for.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                text = log_path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                text = ""
            for line in text.splitlines():
                index = line.find(HANDSHAKE_PREFIX)
                if index < 0:
                    continue
                try:
                    return json.loads(line[index + len(HANDSHAKE_PREFIX) :])
                except json.JSONDecodeError:
                    continue
            if process.poll() is not None:
                raise ToolError(
                    "The tournament exited before it started. Its output:\n"
                    + text.strip()[-1500:]
                )
            time.sleep(0.4)

        process.terminate()
        raise ToolError(
            f"No tournament directory after {timeout:g}s. Output so far:\n"
            + log_path.read_text(encoding="utf-8", errors="replace")[-1500:]
        )

    # ── read ───────────────────────────────────────────────────────────────

    def tournament_list(args: dict) -> dict:
        root = _root()
        rows = []
        for directory in _dirs(root):
            data = _read_metadata(directory)
            if data:
                rows.append(_summary(directory, data))
        rows.sort(key=lambda r: str(r.get("created_at") or ""), reverse=True)
        limit = int(args.get("limit") or 25)
        return {"root": str(root), "count": len(rows), "tournaments": rows[:limit]}

    def tournament_status(args: dict) -> dict:
        root = _root()
        directory = resolve_id(root, args.get("id"))
        data = _read_metadata(directory)
        if data is None:
            raise ToolError(f"Could not read {directory / METADATA_FILE}.")
        summary = _summary(directory, data)
        games = data.get("games") or []

        # Counting, not modelling: how many of each result and each ending.
        results: dict[str, int] = {}
        terminations: dict[str, int] = {}
        for game in games:
            results[str(game.get("result"))] = results.get(str(game.get("result")), 0) + 1
            key = str(game.get("termination"))
            terminations[key] = terminations.get(key, 0) + 1

        run = _run_state(directory)
        summary.update(
            {
                "results": results,
                "terminations": terminations,
                "last_game": games[-1] if games else None,
                "log": run.get("log"),
                "pid": run.get("pid"),
            }
        )
        return summary

    def tournament_crosstable(args: dict) -> dict:
        root = _root()
        directory = resolve_id(root, args.get("id"))
        payload = _dart_json(
            ["--root", str(root), "--show", directory.name],
            float(args.get("timeout") or DEFAULT_READ_TIMEOUT),
        )
        if not payload.get("ok"):
            raise ToolError(str(payload.get("error") or "Could not read it."))
        return payload

    def tournament_games(args: dict) -> dict:
        root = _root()
        directory = resolve_id(root, args.get("id"))
        data = _read_metadata(directory) or {}
        games = data.get("games") or []
        return {
            "id": directory.name,
            "pgn": str(directory / PGN_FILE),
            "count": len(games),
            "games": [
                {
                    "number": (g.get("gameIndex") or 0) + 1,
                    "round": g.get("round"),
                    "white": g.get("whiteName"),
                    "black": g.get("blackName"),
                    "result": g.get("result"),
                    "termination": g.get("termination"),
                    "detail": g.get("detail"),
                    "plies": g.get("plies"),
                    "seconds": round((g.get("durationMs") or 0) / 1000, 1),
                }
                for g in games
            ],
        }

    def tournament_game_pgn(args: dict) -> dict:
        root = _root()
        directory = resolve_id(root, args.get("id"))
        number = args.get("number")
        if number is None:
            raise ToolError("Provide number (1-based, from tournament_games).")
        pgn_path = directory / PGN_FILE
        try:
            text = pgn_path.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            raise ToolError(f"Could not read {pgn_path}: {e}") from None
        chunks = _split_games(text)
        index = int(number) - 1
        if index < 0 or index >= len(chunks):
            raise ToolError(
                f"Game {number} is out of range — the file holds {len(chunks)}."
            )
        return {"id": directory.name, "number": int(number), "pgn": chunks[index]}

    def tournament_stop(args: dict) -> dict:
        root = _root()
        directory = resolve_id(root, args.get("id"))
        run = _run_state(directory)
        if not run.get("running"):
            return {
                "id": directory.name,
                "stopped": False,
                "reason": "It is not running.",
            }
        pid = int(run["pid"])
        try:
            # SIGINT, not SIGTERM: the runner catches it and stops cleanly
            # after the game in flight, so the PGN stays whole.
            os.kill(pid, signal.SIGINT)
        except OSError as e:
            raise ToolError(f"Could not signal pid {pid}: {e}") from None
        return {
            "id": directory.name,
            "stopped": True,
            "pid": pid,
            "note": "It finishes the game in flight first.",
        }

    # ── open in the app ────────────────────────────────────────────────────

    def _open(tournament_id: str, root: Path, launch: Any) -> dict:
        root.mkdir(parents=True, exist_ok=True)
        request = root / OPEN_REQUEST_FILE
        payload = json.dumps(
            {
                "tournamentId": tournament_id,
                "requestedAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
            }
        )
        tmp = request.with_suffix(".json.tmp")
        tmp.write_text(payload, encoding="utf-8")
        tmp.replace(request)

        mode = str(launch or "auto")
        if mode not in {"auto", "always", "never"}:
            raise ToolError('launch must be "auto", "always" or "never".')

        running = _app_running()
        # "auto" launches only when we are sure the app is down. Unknown is
        # not a licence to start a second copy of someone's app.
        if mode == "never" or (mode == "auto" and running is not False):
            if running:
                note = "The running app jumps to it."
            elif running is None:
                note = (
                    "Could not tell whether the app is running, so nothing was "
                    "launched. A running app jumps to it; otherwise it opens "
                    "on it next launch."
                )
            else:
                note = "Written; the app opens on it next launch."
            return {
                "request_written": str(request),
                "launched": False,
                "app_running": running,
                "note": note,
            }

        command = _app_launch_command()
        if command is None:
            return {
                "request_written": str(request),
                "launched": False,
                "app_running": running,
                "note": (
                    "No built app found. Build it (`flutter build linux`) or set "
                    "CHESS_AUTO_PREP_BIN. The request is written either way, so "
                    "starting the app by hand still lands on this tournament."
                ),
            }
        try:
            subprocess.Popen(  # noqa: S603 - the user's own app
                command,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as e:
            raise ToolError(f"Could not launch the app: {e}") from None
        return {
            "request_written": str(request),
            "launched": True,
            "command": command,
            "app_running": running,
        }

    def tournament_open(args: dict) -> dict:
        root = _root()
        directory = resolve_id(root, args.get("id"))
        result = _open(directory.name, root, args.get("launch", "auto"))
        result["id"] = directory.name
        return result

    # ── engines ────────────────────────────────────────────────────────────

    def tournament_engines(args: dict) -> dict:
        root = _root()
        path = root / ENGINES_FILE
        stored: list[dict] = []
        if path.is_file():
            try:
                with path.open(encoding="utf-8") as fh:
                    loaded = json.load(fh)
                if isinstance(loaded, list):
                    stored = [e for e in loaded if isinstance(e, dict)]
            except (OSError, json.JSONDecodeError):
                stored = []
        return {
            "registry": str(path),
            "engines": [
                {
                    "id": "bundled-stockfish",
                    "name": "Stockfish (bundled)",
                    "path": None,
                    "bundled": True,
                }
            ]
            + [
                {
                    "id": e.get("id"),
                    "name": e.get("name"),
                    "path": e.get("executablePath"),
                    "hash_mb": e.get("hashMb"),
                    "threads": e.get("threads"),
                    "bundled": not e.get("executablePath"),
                }
                for e in stored
                if e.get("id") != "bundled-stockfish"
            ],
        }

    def tournament_add_engine(args: dict) -> dict:
        path = (args.get("path") or "").strip()
        if not path:
            raise ToolError("Provide path to a UCI engine binary.")
        report = _dart_json(
            ["--verify", path],
            float(args.get("timeout") or DEFAULT_READ_TIMEOUT),
        )
        if not report.get("ok"):
            return {
                "added": False,
                "path": path,
                "reason": report.get("message"),
                "transcript": report.get("transcript"),
            }

        root = _root()
        root.mkdir(parents=True, exist_ok=True)
        registry_path = root / ENGINES_FILE
        entries: list[dict] = []
        if registry_path.is_file():
            try:
                with registry_path.open(encoding="utf-8") as fh:
                    loaded = json.load(fh)
                if isinstance(loaded, list):
                    entries = [e for e in loaded if isinstance(e, dict)]
            except (OSError, json.JSONDecodeError):
                entries = []

        name = (args.get("name") or report.get("name") or Path(path).stem).strip()
        existing = next(
            (e for e in entries if e.get("executablePath") == path), None
        )
        if existing is not None:
            existing["name"] = name
        else:
            entries.append(
                {
                    "id": f"engine-{int(time.time() * 1000):x}",
                    "name": name,
                    "executablePath": path,
                    "hashMb": int(args.get("hash_mb") or 128),
                    "threads": int(args.get("threads") or 1),
                    "ponder": False,
                }
            )
        registry_path.write_text(
            json.dumps(entries, indent=2), encoding="utf-8"
        )
        return {
            "added": True,
            "name": name,
            "path": path,
            "reports_itself_as": report.get("name"),
            "author": report.get("author"),
            "sample_move": report.get("sampleMove"),
            "registry": str(registry_path),
            "note": (
                'Pass it to tournament_run as engines: ["'
                + name
                + "="
                + path
                + '"].'
            ),
        }

    # ── Registration ───────────────────────────────────────────────────────

    registry._add(
        "tournament_run",
        "Start an engine-vs-engine match from a position and (by default) "
        "open the app on it. Returns as soon as the tournament directory "
        "exists — the games play on in the background and are written one by "
        "one, so poll tournament_status. Defaults match the app's: the "
        "bundled Stockfish against itself, 2s per move, 10 games with the "
        "colours alternating, one game at a time, and the draw/resign "
        "adjudication that stops two equal engines shuffling forever.",
        _obj(
            {
                "fen": _s(
                    "Position every game starts from. Omit for the standard "
                    "starting position."
                ),
                "name": _s('Tournament name (default "Engine match").'),
                "opening": _s("Label for the PGN Opening tag."),
                "games": _i("Games per pairing (default 10)."),
                "movetime_ms": _i(
                    "Fixed think time per move in ms (default 2000). "
                    "Mutually exclusive with tc and depth."
                ),
                "tc": _s(
                    'Clock in seconds instead: "60+0.6", "40/600+10", "120".'
                ),
                "depth": _i("Fixed search depth instead of a clock."),
                "concurrency": _i(
                    "Games in flight at once (default 1, which is fairest)."
                ),
                "engines": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": (
                        'Competitors as "Name=/path/to/binary", two or more. '
                        "Omit for the bundled Stockfish playing itself. Verify "
                        "an unfamiliar binary with tournament_add_engine first."
                    ),
                },
                "open_app": _b(
                    "Open the app on the new tournament (default true)."
                ),
                "launch": _s(
                    'When to start the app: "auto" (default, only if it is '
                    'not already running), "always", "never".'
                ),
                "startup_timeout": _i(
                    "Seconds to wait for the directory to appear (default "
                    "180; a cold `dart run` has to compile first)."
                ),
            }
        ),
        tournament_run,
    )

    registry._add(
        "tournament_status",
        "How a tournament is going: status, games played of total, what the "
        "results and endings look like so far, and whether its process is "
        "still up. Defaults to the most recent tournament.",
        _obj({"id": _s("Tournament id (default: the most recent).")}),
        tournament_status,
    )

    registry._add(
        "tournament_list",
        "Every saved tournament, newest first: who played, from what "
        "position, under what time control, how many games are in, and "
        "whether it is still running. Use it to find the id the other "
        "tournament_* tools want — they default to the most recent.",
        _obj({"limit": _i("Max rows (default 25).")}),
        tournament_list,
    )

    registry._add(
        "tournament_crosstable",
        "The results summary: standings with score, W/D/L, draw rate, "
        "Sonneborn-Berger, the implied Elo difference with its 95% interval, "
        "and likelihood of superiority, plus the head-to-head grid and a "
        "rendered table. Computed by the same code the app displays, so the "
        "numbers agree.",
        _obj(
            {
                "id": _s("Tournament id (default: the most recent)."),
                "timeout": _i("Seconds to allow (default 180)."),
            }
        ),
        tournament_crosstable,
    )

    registry._add(
        "tournament_games",
        "One row per game played: colours, result, how it ended, length.",
        _obj({"id": _s("Tournament id (default: the most recent).")}),
        tournament_games,
    )

    registry._add(
        "tournament_game_pgn",
        "The PGN of one game, with the engines' own evaluations, depths and "
        "times in the move comments.",
        _obj(
            {
                "id": _s("Tournament id (default: the most recent)."),
                "number": _i("Game number, 1-based, as tournament_games gives."),
            },
            ["number"],
        ),
        tournament_game_pgn,
    )

    registry._add(
        "tournament_stop",
        "Stop a running tournament. It finishes the game in flight first, so "
        "the PGN and the crosstable stay consistent.",
        _obj({"id": _s("Tournament id (default: the most recent).")}),
        tournament_stop,
    )

    registry._add(
        "tournament_open",
        "Open the desktop app on a tournament — Engine Tournament mode with "
        "its crosstable and games list, where clicking a game opens it in the "
        "PGN Viewer. Writes a request the app honours whether it is running "
        "now or started later.",
        _obj(
            {
                "id": _s("Tournament id (default: the most recent)."),
                "launch": _s(
                    'When to start the app: "auto" (default), "always", '
                    '"never".'
                ),
            }
        ),
        tournament_open,
    )

    registry._add(
        "tournament_engines",
        "Engines available to tournaments: the bundled Stockfish plus any "
        "binary added with tournament_add_engine.",
        _obj({}),
        tournament_engines,
    )

    registry._add(
        "tournament_add_engine",
        "Check a UCI binary and add it to the tournament engine list. The "
        "check is the real thing — it starts the process, requires \"uciok\" "
        "and \"readyok\", and requires a legal move from the starting "
        "position — so a wrapper script, an XBoard engine or the wrong "
        "architecture is reported rather than discovered mid-match. Nothing "
        "is added unless it passes.",
        _obj(
            {
                "path": _s("Absolute path to the engine binary."),
                "name": _s("Display name (default: the engine's own id)."),
                "hash_mb": _i("Hash table size in MB (default 128)."),
                "threads": _i("Search threads (default 1)."),
                "timeout": _i("Seconds to allow (default 180)."),
            },
            ["path"],
        ),
        tournament_add_engine,
    )


def _split_games(text: str) -> list[str]:
    """Split a PGN collection on the blank line before each `[Event`."""
    games: list[str] = []
    current: list[str] = []
    for line in text.splitlines():
        if line.startswith("[Event ") and current and any(c.strip() for c in current):
            games.append("\n".join(current).strip())
            current = []
        current.append(line)
    if any(c.strip() for c in current):
        games.append("\n".join(current).strip())
    return games
