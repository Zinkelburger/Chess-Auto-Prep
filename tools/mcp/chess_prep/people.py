"""The app's players directory, `Documents/opponents/`, read and written here.

```
people.json              chess-auto-prep/people@1 — one row per person
tournaments/<id>.json    chess-auto-prep/tournament@1 — a group of people
```

The app (`lib/features/opponents/`) owns the format; this module writes the
same rows so an agent can fill the directory instead of the user typing it.
Rules that keep that safe:

* Unknown keys on a row and in the envelope survive a write, and the app
  keeps them too (`PersonRecord.extra`), so the agent's `lookup` block is
  never silently dropped by either side.
* A merge fills blanks and unions lists. It never replaces a name, rating,
  note or account the user typed, and never removes an account.
* `chesscom` / `lichess` are what the app downloads. Only trusted evidence
  (the directory's USCF-event match, or the user's say-so) goes there;
  everything else waits in `lookup.candidates`.
* Every file is written atomically (temp file + rename), under the app's
  own folder lock (`lib/storage/file_lock.dart`), and a save re-reads the
  file first: rows this store did not change are written back exactly as
  they are on disk — the app's edits since the load, rows nobody can read,
  everything — and the fields this store changed are laid over the row as
  it is now.
"""

from __future__ import annotations

import contextlib
import copy
import datetime as dt
import json
import os
import random
import re
import sqlite3
import sys
import tempfile
import time
from collections.abc import Iterator, Sequence
from pathlib import Path
from typing import Any

from .names import fold, name_match

PEOPLE_FORMAT = "chess-auto-prep/people@1"
TOURNAMENT_FORMAT = "chess-auto-prep/tournament@1"

_USER_DIRS = re.compile(r'^XDG_DOCUMENTS_DIR="?(.*?)"?\s*$')


def documents_dir() -> Path:
    """The app's Documents directory (path_provider's answer): the XDG
    documents dir on Linux, ~/Documents elsewhere."""
    home = Path.home()
    if sys.platform.startswith("linux"):
        config = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
        try:
            for line in (config / "user-dirs.dirs").read_text().splitlines():
                match = _USER_DIRS.match(line.strip())
                if match:
                    return Path(match.group(1).replace("$HOME", str(home)))
        except OSError:
            pass
    if sys.platform == "win32":
        profile = os.environ.get("USERPROFILE")
        if profile:
            return Path(profile) / "Documents"
    return home / "Documents"


def opponents_dir() -> Path:
    """Override with CHESS_PREP_PEOPLE_DIR (tests do)."""
    override = os.environ.get("CHESS_PREP_PEOPLE_DIR")
    if override:
        return Path(override).expanduser()
    return documents_dir() / "opponents"


def _now() -> str:
    return dt.datetime.now().isoformat()


def new_id() -> str:
    """Same shape as the app's `_newRecordId`: base-36 microseconds + salt."""
    stamp = _base36(int(time.time() * 1_000_000))
    salt = _base36(random.randrange(1 << 20)).rjust(4, "0")
    return stamp + salt


def _base36(n: int) -> str:
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    while True:
        n, r = divmod(n, 36)
        out = digits[r] + out
        if n == 0:
            return out


def tournament_id(name: str) -> str:
    """The app's `newTournamentId`: `Spring Open 2026` → `spring-open-2026`."""
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or f"tournament-{_base36(int(time.time() * 1000))}"


def handles(cell: str | None) -> list[str]:
    """The handles in an account cell (`a, b` → `[a, b]`)."""
    return [h.strip() for h in (cell or "").split(",") if h.strip()]


def _union_cell(existing: str | None, extra: list[str]) -> str | None:
    out = handles(existing)
    lowered = {h.lower() for h in out}
    for h in extra:
        h = h.strip()
        if h and h.lower() not in lowered:
            out.append(h)
            lowered.add(h.lower())
    return ", ".join(out) or None


def _write_atomic(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _lock_name(key: str) -> str:
    """The app's lock file name for a folder: FNV-1a of its path, printed as
    Dart prints a signed 64-bit int in hex (`_stablePathHash`)."""
    value = 0xCBF29CE484222325
    for byte in key.encode("utf-8"):
        value ^= byte
        value = (value * 0x100000001B3) & ((1 << 64) - 1)
    text = "-" + format((1 << 64) - value, "x") if value >= 1 << 63 else format(value, "x")
    return text.rjust(16, "0")


@contextlib.contextmanager
def directory_lock(directory: Path, timeout: float = 120.0) -> Iterator[None]:
    """The folder lock the app takes around every players-file edit
    (`withDirectoryLock`): an open `BEGIN IMMEDIATE` on a shared, empty
    SQLite file named after the folder, which the system releases if this
    process dies. Without it an app save could land between this side's
    read and its write, and be lost."""
    directory.mkdir(parents=True, exist_ok=True)
    key = os.path.normpath(os.path.realpath(directory))
    locks = Path(tempfile.gettempdir()) / "chess-auto-prep-file-locks"
    locks.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(locks / f"{_lock_name(key)}.sqlite3"), timeout=0, isolation_level=None)
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                db.execute("BEGIN IMMEDIATE")
                break
            except sqlite3.OperationalError as e:
                if "locked" not in str(e) and "busy" not in str(e):
                    raise
                if time.monotonic() > deadline:
                    raise TimeoutError(f"{directory} stayed locked for {timeout:.0f} s") from e
                time.sleep(0.01)
        try:
            yield
        finally:
            db.execute("ROLLBACK")
    finally:
        db.close()


def _row_id(row: Any) -> str | None:
    rid = row.get("id") if isinstance(row, dict) else None
    return rid if isinstance(rid, str) and rid else None


class PeopleStore:
    """One load of `people.json`, edited in memory, merged back on save."""

    def __init__(self, root: Path | None = None) -> None:
        self.root = root or opponents_dir()
        self.path = self.root / "people.json"
        self.envelope, rows = self._read()
        self.people: list[dict[str, Any]] = [r for r in rows if isinstance(r, dict)]
        #: Each readable row as loaded, to tell this store's edits from the
        #: file's own changes at save time.
        self._loaded = {
            rid: copy.deepcopy(r) for r in self.people if (rid := _row_id(r)) is not None
        }

    def _read(self) -> tuple[dict[str, Any], list[Any]]:
        """The envelope and every row of the file as it is now.

        Rows that are not a list are no rows this side may write over (the
        app refuses them too), so that raises rather than reading as empty.
        """
        if not self.path.exists():
            return {"format": PEOPLE_FORMAT}, []
        raw = json.loads(self.path.read_text(encoding="utf-8") or "null")
        if isinstance(raw, dict):
            fmt = raw.get("format")
            if fmt and fmt != PEOPLE_FORMAT:
                raise ValueError(f'{self.path} has unknown format "{fmt}".')
            rows = raw.get("people")
            envelope = {k: v for k, v in raw.items() if k != "people"}
        else:
            rows, envelope = raw, {"format": PEOPLE_FORMAT}
        if rows is None:
            rows = []
        if not isinstance(rows, list):
            raise ValueError(f"The people in {self.path} are not a list; it is left as it is.")
        return envelope, rows

    def save(self) -> Path:
        """Write this store's added and edited rows into the file as it is
        now. Every other row — the app's edits since the load, rows this
        side cannot read — goes back exactly as it is on disk."""
        with directory_lock(self.root):
            envelope, current = self._read()
            mine: dict[str, dict] = {}
            for row in self.people:
                rid = _row_id(row)
                if rid is not None and row != self._loaded.get(rid):
                    mine.setdefault(rid, row)
            rows: list[Any] = []
            for row in current:
                rid = _row_id(row)
                if rid is None or rid not in mine:
                    rows.append(row)
                    continue
                ours = mine.pop(rid)
                before = self._loaded.get(rid)
                if before is None or row == before:
                    rows.append(ours)
                else:
                    # The file changed this row too: keep its version and
                    # lay over only the fields this store changed.
                    rows.append(
                        {**row, **{k: v for k, v in ours.items() if before.get(k) != v}}
                    )
            # New rows. A loaded row that is gone from the file was removed
            # in the app meanwhile, and stays removed.
            rows += [row for rid, row in mine.items() if rid not in self._loaded]
            _write_atomic(self.path, {**envelope, "format": PEOPLE_FORMAT, "people": rows})
        self.envelope = envelope
        self.people = [r for r in rows if isinstance(r, dict)]
        self._loaded = {
            rid: copy.deepcopy(r) for r in self.people if (rid := _row_id(r)) is not None
        }
        return self.path

    # ── Lookup ──────────────────────────────────────────────────────

    def get(self, person_id: str) -> dict | None:
        return next((p for p in self.people if p.get("id") == person_id), None)

    def match(
        self,
        *,
        uscf_id: str | None = None,
        fide_id: int | None = None,
        chesscom: Sequence[str] = (),
        lichess: Sequence[str] = (),
        names: Sequence[str] = (),
    ) -> dict | None:
        """The row these facts describe, strongest key first — USCF ID, FIDE
        ID, a handle, then an exact name or alias (the app's order, plus
        FIDE and aliases). A namesake under another ID is somebody else."""
        if uscf_id:
            for p in self.people:
                if str(p.get("uscf_id") or "") == uscf_id:
                    return p
        if fide_id:
            for p in self.people:
                if p.get("fide_id") == fide_id:
                    return p
        wanted = {
            "chesscom": {h.lower() for h in chesscom},
            "lichess": {h.lower() for h in lichess},
        }
        for p in self.people:
            for site, want in wanted.items():
                if want & {h.lower() for h in handles(p.get(site))}:
                    return p
        for p in self.people:
            if uscf_id and p.get("uscf_id"):
                continue
            spellings = [p.get("name") or ""] + list(p.get("aliases") or [])
            if any(
                name_match(n, s) == "exact" for n in names for s in spellings if n and s
            ):
                return p
        return None

    def search(self, query: str) -> list[dict]:
        """Rows whose name, aliases, IDs or handles contain every word."""
        words = [w for w in fold(query).split() if w]
        out = []
        for p in self.people:
            hay = fold(
                " ".join(
                    [
                        str(p.get("name") or ""),
                        " ".join(p.get("aliases") or []),
                        str(p.get("uscf_id") or ""),
                        str(p.get("fide_id") or ""),
                        str(p.get("chesscom") or ""),
                        str(p.get("lichess") or ""),
                    ]
                )
            )
            if all(w in hay for w in words):
                out.append(p)
        return out

    # ── Edits ───────────────────────────────────────────────────────

    def upsert(self, facts: dict[str, Any]) -> tuple[dict, str]:
        """Merge [facts] into the matching row, or add one.

        Returns `(row, "added" | "updated" | "unchanged")`. Scalars fill
        blanks only (pass `overwrite: true` to replace name/rating/title);
        aliases and accounts are unioned; `lookup` is replaced wholesale
        because it is the agent's own report, re-derived on every run.
        """
        name = str(facts.get("name") or "").strip()
        uscf_id = str(facts.get("uscf_id") or "").strip() or None
        fide_id = int(facts["fide_id"]) if facts.get("fide_id") else None
        chesscom = [h for h in facts.get("chesscom") or [] if h]
        lichess = [h for h in facts.get("lichess") or [] if h]
        aliases = [a.strip() for a in facts.get("aliases") or [] if a and a.strip()]

        row = self.get(facts["id"]) if facts.get("id") else None
        if facts.get("id") and row is None:
            raise KeyError(facts["id"])
        if row is None:
            row = self.match(
                uscf_id=uscf_id,
                fide_id=fide_id,
                chesscom=chesscom,
                lichess=lichess,
                names=[name, *aliases],
            )
        status = "updated"
        if row is None:
            if not name:
                raise ValueError("A new person needs a name.")
            now = _now()
            row = {
                "id": new_id(),
                "name": name,
                "game_sets": [],
                "studies": [],
                "created_at": now,
                "updated_at": now,
            }
            self.people.append(row)
            status = "added"
        before = json.dumps(row, sort_keys=True)

        overwrite = bool(facts.get("overwrite"))
        if name and (overwrite or not row.get("name")):
            row["name"] = name
        elif name and fold(name) != fold(row.get("name") or ""):
            aliases.append(name)
        for key, value in (
            ("uscf_id", uscf_id),
            ("fide_id", fide_id),
            ("rating", facts.get("rating")),
            ("title", facts.get("title")),
        ):
            if value in (None, ""):
                continue
            if overwrite or row.get(key) in (None, ""):
                row[key] = value
        if facts.get("notes") and not row.get("notes"):
            row["notes"] = str(facts["notes"])

        known = {fold(row.get("name") or "")} | {fold(a) for a in row.get("aliases") or []}
        merged = list(row.get("aliases") or [])
        for alias in aliases:
            if fold(alias) not in known:
                merged.append(alias)
                known.add(fold(alias))
        if merged:
            row["aliases"] = merged

        for site, extra in (("chesscom", chesscom), ("lichess", lichess)):
            cell = _union_cell(row.get(site), extra)
            if cell:
                row[site] = cell
        if "lookup" in facts and facts["lookup"] is not None:
            row["lookup"] = facts["lookup"]

        if status == "updated" and json.dumps(row, sort_keys=True) == before:
            return row, "unchanged"
        row["updated_at"] = _now()
        return row, status

    def confirm(self, person_id: str, site: str, username: str) -> dict:
        """Move a candidate into the account cell the app downloads from."""
        row = self.get(person_id)
        if row is None:
            raise KeyError(person_id)
        row[site] = _union_cell(row.get(site), [username])
        lookup = row.get("lookup")
        if isinstance(lookup, dict):
            lookup["candidates"] = [
                c
                for c in lookup.get("candidates") or []
                if not (c.get("site") == site and str(c.get("username", "")).lower() == username.lower())
            ]
            confirmed = lookup.setdefault("confirmed", [])
            confirmed.append(
                {"site": site, "username": username, "source": "user", "at": _now()}
            )
        row["updated_at"] = _now()
        return row


class TournamentStore:
    """`tournaments/<id>.json`: a named group of people."""

    def __init__(self, root: Path | None = None) -> None:
        self.dir = (root or opponents_dir()) / "tournaments"

    def load(self, tid: str) -> dict | None:
        path = self.dir / f"{tid}.json"
        if not path.exists():
            return None
        return json.loads(path.read_text(encoding="utf-8"))

    def upsert(
        self,
        name: str,
        entries: list[dict[str, Any]],
        *,
        date: str | None = None,
        rounds: int | None = None,
    ) -> tuple[Path, dict, int]:
        """Add [entries] (`person`, optional `rating`) to the group called
        [name], creating it. Existing entries keep `prepared` and odds; a
        new rating fills only a blank. Returns (path, doc, entries added)."""
        with directory_lock(self.dir):
            return self._upsert(name, entries, date=date, rounds=rounds)

    def _upsert(
        self,
        name: str,
        entries: list[dict[str, Any]],
        *,
        date: str | None,
        rounds: int | None,
    ) -> tuple[Path, dict, int]:
        tid = tournament_id(name)
        doc = self.load(tid)
        now = _now()
        if doc is None:
            doc = {
                "format": TOURNAMENT_FORMAT,
                "id": tid,
                "name": name,
                "created_at": now,
                "entries": [],
            }
        if date and not doc.get("date"):
            doc["date"] = date
        if rounds and not doc.get("rounds"):
            doc["rounds"] = rounds
        existing = {e.get("person"): e for e in doc.get("entries") or []}
        added = 0
        for entry in entries:
            current = existing.get(entry["person"])
            if current is None:
                row = {"person": entry["person"]}
                if entry.get("rating") is not None:
                    row["rating"] = entry["rating"]
                doc.setdefault("entries", []).append(row)
                existing[entry["person"]] = row
                added += 1
            elif current.get("rating") is None and entry.get("rating") is not None:
                current["rating"] = entry["rating"]
        doc["updated_at"] = now
        path = self.dir / f"{tid}.json"
        _write_atomic(path, doc)
        return path, doc, added
