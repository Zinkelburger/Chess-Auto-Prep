"""Download chessgames.com game collections as PGN.

A collection is two kinds of request:

* **The collection page** (`/perl/chesscollection?cid=N`) is plain HTML that
  links every game as `/perl/chessgame?gid=N`. It sits behind an AWS WAF that
  sometimes answers a non-browser with a challenge page — a 200 with no game
  links. When that happens the caller can save the page from a browser and
  pass the file (`html_file`), or pass the game ids directly.
* **One PGN per game** from `/njs/api/game/viewPGN/<gid>`. It needs no
  session but bans fast callers: ~2–3 s apart gets a 429 after 15–20 games,
  ~22 s apart sustained 60 in September 2026. So a 60-game collection takes
  over 20 minutes, and the download runs as a background process
  (`python3 -m chess_prep.chessgames --job DIR`) that `chessgames_status`
  polls.

Every fetched game is cached by id under `<data dir>/chessgames/games/`, so a
stopped or failed download resumes without refetching, and the output PGN is
rewritten in collection order after each game — a partial file is usable.
The app's Study import (`lib/infrastructure/studies/chessgames_collection_client.dart`)
follows the same rules.
"""

from __future__ import annotations

import argparse
import datetime as dt
import html as html_lib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable

from .paths import data_dir

SITE = "https://www.chessgames.com"
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/126.0.0.0 Safari/537.36"
)

#: Seconds between PGN requests. ~22 s sustained 60 games without a ban.
DEFAULT_DELAY = 22.0
MIN_DELAY = 10.0
#: Back-off after a throttled answer: 1, 2, 4, 8, 16 minutes, then skip.
THROTTLE_BACKOFF = (60, 120, 240, 480, 960)

JOB_FILE = "job.json"
STATUS_FILE = "status.json"
LOG_FILE = "log.txt"

#: (status code, body) — the whole of what the downloader needs from HTTP.
Fetch = Callable[[str, "str | None"], "tuple[int, str]"]


class ChessgamesError(Exception):
    """A request the tools cannot satisfy, reported as readable text."""


class Stopped(Exception):
    """Raised inside the job when it receives SIGTERM."""


# ── Paths ────────────────────────────────────────────────────────────────────


def chessgames_dir() -> Path:
    return data_dir() / "chessgames"


def games_dir() -> Path:
    return chessgames_dir() / "games"


def jobs_dir() -> Path:
    return chessgames_dir() / "jobs"


def default_out_dir() -> Path:
    return Path.home() / "Documents" / "chessgames"


# ── HTTP ─────────────────────────────────────────────────────────────────────


def fetch_url(url: str, referer_gid: str | None = None, timeout: int = 30) -> tuple[int, str]:
    """GET [url] with the headers the site's own front-end sends.

    `Accept: */*` matters: a browser-style `text/html` Accept without the rest
    of a browser makes the WAF answer a 202 challenge page instead.
    Never raises for an HTTP status; a transport failure is status 0."""
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "*/*",
        "Accept-Language": "en-US,en;q=0.9",
        "Origin": SITE,
    }
    if referer_gid:
        headers["Referer"] = f"{SITE}/perl/chessgame?gid={referer_gid}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace") if e.fp else ""
        return e.code, body
    except (urllib.error.URLError, OSError):
        return 0, ""


# ── Parsing ──────────────────────────────────────────────────────────────────


def parse_collection_id(text: str) -> str:
    """A collection URL (`...chesscollection?cid=1014220`) or a bare id."""
    text = text.strip()
    if text.isdigit():
        return text
    match = re.search(r"[?&]cid=(\d+)", text)
    if not match:
        raise ChessgamesError(
            f'"{text}" is not a chessgames.com collection URL (…chesscollection?cid=N) or id.'
        )
    return match.group(1)


def collection_url(cid: str) -> str:
    return f"{SITE}/perl/chesscollection?cid={cid}"


def pgn_url(gid: str) -> str:
    return f"{SITE}/njs/api/game/viewPGN/{gid}"


def extract_game_ids(page: str) -> list[str]:
    """Every game linked from a collection page, in page order, de-duplicated."""
    return list(dict.fromkeys(re.findall(r"chessgame\?gid=(\d+)", page)))


def extract_title(page: str) -> str | None:
    """The collection name from `<title>`, without site boilerplate."""
    match = re.search(r"<title>(.*?)</title>", page, re.IGNORECASE | re.DOTALL)
    if not match:
        return None
    title = re.sub(r"\s+", " ", html_lib.unescape(match.group(1))).strip()
    title = re.sub(r"^chess\s+(game\s+)?collection\s*:\s*", "", title, flags=re.IGNORECASE)
    title = re.sub(r"\s*-\s*chessgames\.com\s*$", "", title, flags=re.IGNORECASE)
    return title or None


def classify_pgn_response(status: int, body: str) -> tuple[str, str | None]:
    """`ok` with the PGN, `throttled` (back off, retry) or `failed` (skip).

    The site answers a rate limit with a 200 HTML page as often as a 429."""
    if status in (429, 403, 503):
        return "throttled", None
    text = body.strip()
    if status == 200 and text.startswith("[Event "):
        return "ok", text
    lower = text.lower()
    if any(
        phrase in lower
        for phrase in ("too many requests", "under maintenance", "temporarily unavailable", "rate limit")
    ):
        return "throttled", None
    return "failed", None


def safe_file_name(title: str) -> str:
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", title).strip().rstrip(".")
    return re.sub(r"\s+", " ", name)[:120] or "collection"


# ── Files ────────────────────────────────────────────────────────────────────


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _write_json(path: Path, payload: Any) -> None:
    _write_text(path, json.dumps(payload, indent=2))


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def cached_pgn(gid: str) -> str | None:
    try:
        return (games_dir() / f"{gid}.pgn").read_text(encoding="utf-8")
    except OSError:
        return None


def write_collection_pgn(collection: dict) -> int:
    """Rewrite the output file from every cached game, in collection order."""
    games = [pgn for pgn in (cached_pgn(g) for g in collection["gids"]) if pgn]
    _write_text(Path(collection["out"]), "\n\n".join(games) + ("\n" if games else ""))
    return len(games)


# ── The background job ───────────────────────────────────────────────────────


def run_job(
    job: Path,
    fetch: Fetch = fetch_url,
    sleep: Callable[[float], None] = time.sleep,
) -> dict:
    """Fetch every uncached game of every collection in the job, serially."""
    spec = _read_json(job / JOB_FILE) or {}
    delay = float(spec.get("delay_seconds") or DEFAULT_DELAY)
    collections: list[dict] = spec.get("collections") or []
    status: dict[str, Any] = {
        "state": "running",
        "pid": os.getpid(),
        "started": dt.datetime.now().isoformat(timespec="seconds"),
        "collections": [
            {"cid": c["cid"], "title": c["title"], "out": c["out"], "total": len(c["gids"]),
             "saved": 0, "failed": []}
            for c in collections
        ],
    }

    def tick(**fields: Any) -> None:
        status.update(fields)
        status["updated"] = dt.datetime.now().isoformat(timespec="seconds")
        _write_json(job / STATUS_FILE, status)

    first_request = True
    try:
        for collection, row in zip(collections, status["collections"]):
            row["saved"] = write_collection_pgn(collection)
            tick(current=collection["cid"])
            for gid in collection["gids"]:
                if cached_pgn(gid) is not None:
                    continue
                pgn = None
                for backoff in (*THROTTLE_BACKOFF, None):
                    if not first_request:
                        sleep(delay)
                    first_request = False
                    outcome, pgn = classify_pgn_response(*fetch(pgn_url(gid), gid))
                    if outcome != "throttled":
                        break
                    if backoff is None:
                        break
                    tick(throttled_until=(dt.datetime.now() + dt.timedelta(seconds=backoff))
                         .isoformat(timespec="seconds"))
                    sleep(backoff)
                status.pop("throttled_until", None)
                if pgn is None:
                    row["failed"].append(gid)
                else:
                    _write_text(games_dir() / f"{gid}.pgn", pgn)
                    row["saved"] = write_collection_pgn(collection)
                tick()
        tick(state="done", current=None)
    except Stopped:
        tick(state="stopped")
    except Exception as e:  # noqa: BLE001 - the job must always leave a status
        tick(state="failed", error=f"{type(e).__name__}: {e}")
        raise
    return status


def _pid_alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def start_job_process(job: Path) -> int:
    package_root = Path(__file__).resolve().parent.parent
    with (job / LOG_FILE).open("ab") as log:
        process = subprocess.Popen(  # noqa: S603 - our own module
            [sys.executable, "-m", "chess_prep.chessgames", "--job", str(job)],
            stdout=log,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            cwd=str(package_root),
            start_new_session=True,
        )
    return process.pid


def job_summary(job: Path) -> dict:
    spec = _read_json(job / JOB_FILE) or {}
    status = _read_json(job / STATUS_FILE) or {"state": "starting"}
    pid = status.get("pid") or spec.get("pid")
    if status.get("state") in ("starting", "running") and not _pid_alive(pid):
        status["state"] = "died"
        status["note"] = "The process is gone; chessgames_download with the same collections resumes."
    delay = float(spec.get("delay_seconds") or DEFAULT_DELAY)
    rows = status.get("collections") or [
        {"cid": c["cid"], "title": c["title"], "out": c["out"], "total": len(c["gids"]), "saved": 0,
         "failed": []}
        for c in spec.get("collections") or []
    ]
    remaining = sum(r["total"] - r["saved"] - len(r["failed"]) for r in rows)
    summary = {"id": job.name, **status, "collections": rows}
    if summary["state"] in ("starting", "running"):
        summary["remaining_games"] = remaining
        summary["eta_minutes"] = round(remaining * delay / 60, 1)
    return summary


def running_job() -> Path | None:
    root = jobs_dir()
    if not root.is_dir():
        return None
    for job in sorted(root.iterdir(), reverse=True):
        if job_summary(job).get("state") in ("starting", "running"):
            return job
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--job", required=True, help="download job directory")
    args = parser.parse_args(argv)

    def handler(signum, frame):  # noqa: ARG001
        raise Stopped()

    signal.signal(signal.SIGTERM, handler)
    result = run_job(Path(args.job))
    return 0 if result.get("state") in ("done", "stopped") else 1


# ── Tools ────────────────────────────────────────────────────────────────────


def resolve_collection(
    source: str,
    out_dir: Path,
    fetch: Fetch = fetch_url,
    html_file: str | None = None,
) -> dict:
    """Collection id, title, game ids and output path, from the site or a saved page."""
    cid = parse_collection_id(source)
    if html_file:
        page = Path(html_file).expanduser().read_text(encoding="utf-8", errors="replace")
    else:
        code, page = fetch(collection_url(cid), None)
        if code == 0:
            raise ChessgamesError(f"Could not reach chessgames.com for collection {cid}.")
    gids = extract_game_ids(page)
    if not gids:
        raise ChessgamesError(
            f"Collection {cid}: the page has no game links (HTTP challenge page or empty "
            "collection). Open it in a browser, save the page (Ctrl+S) and pass the file as "
            "html_file."
        )
    title = extract_title(page) or f"chessgames collection {cid}"
    out = out_dir / f"{safe_file_name(title)}.pgn"
    return {"cid": cid, "title": title, "gids": gids, "out": str(out)}


def register_chessgames_tools(registry: Any) -> None:
    from .tools import ToolError, _n, _obj, _s

    def download(args: dict) -> dict:
        sources = args.get("collections") or []
        if isinstance(sources, str):
            sources = [s for s in re.split(r"[\s,]+", sources) if s]
        if not sources:
            raise ToolError("collections is required: chessgames.com collection URLs or ids.")
        html_file = args.get("html_file")
        if html_file and len(sources) != 1:
            raise ToolError("html_file goes with exactly one collection.")
        delay = float(args.get("delay_seconds") or DEFAULT_DELAY)
        if delay < MIN_DELAY:
            raise ToolError(f"delay_seconds below {MIN_DELAY:g} gets the IP banned.")
        busy = running_job()
        if busy is not None:
            raise ToolError(
                f"Download {busy.name} is still running; one at a time keeps the site from "
                "banning the IP. Poll chessgames_status or stop it first."
            )
        out_dir = Path(args.get("out_dir") or default_out_dir()).expanduser()
        try:
            collections = [resolve_collection(s, out_dir, html_file=html_file) for s in sources]
        except (ChessgamesError, OSError) as e:
            raise ToolError(str(e)) from None

        job = jobs_dir() / dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        job.mkdir(parents=True, exist_ok=True)
        _write_json(job / JOB_FILE, {"delay_seconds": delay, "collections": collections})
        spec = _read_json(job / JOB_FILE)
        spec["pid"] = start_job_process(job)
        _write_json(job / JOB_FILE, spec)
        uncached = sum(1 for c in collections for g in c["gids"] if cached_pgn(g) is None)
        return {
            "id": job.name,
            "collections": [
                {"cid": c["cid"], "title": c["title"], "games": len(c["gids"]), "out": c["out"]}
                for c in collections
            ],
            "to_download": uncached,
            "eta_minutes": round(uncached * delay / 60, 1),
            "note": "Runs in the background; poll chessgames_status. The output files fill in "
            "collection order as games arrive.",
        }

    def status(args: dict) -> dict:
        job_id = (args.get("id") or "").strip()
        if job_id:
            job = jobs_dir() / job_id
            if not (job / JOB_FILE).is_file():
                raise ToolError(f"No chessgames download {job_id}.")
            return job_summary(job)
        root = jobs_dir()
        jobs = sorted(root.iterdir(), reverse=True)[:10] if root.is_dir() else []
        return {
            "downloads": [
                {k: v for k, v in job_summary(j).items() if k in ("id", "state", "collections", "eta_minutes")}
                for j in jobs
            ],
            "cached_games": len(list(games_dir().glob("*.pgn"))) if games_dir().is_dir() else 0,
        }

    def stop(args: dict) -> dict:
        job_id = (args.get("id") or "").strip()
        job = jobs_dir() / job_id if job_id else running_job()
        if job is None or not (job / JOB_FILE).is_file():
            raise ToolError("No running chessgames download.")
        summary = job_summary(job)
        pid = summary.get("pid")
        if summary.get("state") in ("starting", "running") and _pid_alive(pid):
            os.kill(pid, signal.SIGTERM)
            return {"id": job.name, "stopped": True,
                    "note": "Fetched games stay cached; the same collections resume."}
        return {"id": job.name, "stopped": False, "state": summary.get("state")}

    registry._add(
        "chessgames_download",
        "Download chessgames.com game collections (…/perl/chesscollection?cid=N) as one PGN "
        "file per collection, games in collection order, named after the collection "
        "(default folder ~/Documents/chessgames). Reads each collection page now and returns "
        "titles, game counts, output paths and an ETA; the PGNs are then fetched by a "
        "background process one game every delay_seconds (default 22 — faster gets the IP "
        "banned), so 60 games take ~22 minutes. Poll chessgames_status. Games are cached by id, "
        "so repeating the call resumes a stopped or failed download. Only one download runs at "
        "a time. If a collection page comes back without game links (a browser challenge), ask "
        "the user to save the page from their browser and pass it as html_file.",
        _obj(
            {
                "collections": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Collection URLs or cid numbers.",
                },
                "out_dir": _s("Folder for the PGN files (default ~/Documents/chessgames)."),
                "html_file": _s("Saved collection page to read game ids from instead of the "
                                "site; exactly one collection."),
                "delay_seconds": _n("Seconds between game requests (default 22, minimum 10)."),
            },
            ["collections"],
        ),
        download,
    )
    registry._add(
        "chessgames_status",
        "Progress of a chessgames_download: state (running, done, stopped, failed, died), per "
        "collection games saved / total / failed ids and output path, remaining games and ETA, "
        "and throttled_until while backing off from a rate limit. With no id: the recent "
        "downloads and how many games are cached.",
        _obj({"id": _s("Download id from chessgames_download (omit to list).")}),
        status,
    )
    registry._add(
        "chessgames_stop",
        "Stop a running chessgames_download (the running one when id is omitted). Fetched games "
        "stay cached and the output files keep them; the same call to chessgames_download "
        "resumes.",
        _obj({"id": _s("Download id.")}),
        stop,
    )


if __name__ == "__main__":  # pragma: no cover - background entry point
    sys.exit(main())
