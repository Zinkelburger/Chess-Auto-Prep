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
* Every file is written atomically (temp file + rename).
"""

from __future__ import annotations

import datetime as dt
import json
import os
import random
import re
import sys
import tempfile
import time
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


class PeopleStore:
    """One load of `people.json`, edited in memory, saved whole."""

    def __init__(self, root: Path | None = None) -> None:
        self.root = root or opponents_dir()
        self.path = self.root / "people.json"
        self.envelope: dict[str, Any] = {"format": PEOPLE_FORMAT}
        self.people: list[dict[str, Any]] = []
        if self.path.exists():
            raw = json.loads(self.path.read_text(encoding="utf-8") or "null")
            if isinstance(raw, dict):
                fmt = raw.get("format")
                if fmt and fmt != PEOPLE_FORMAT:
                    raise ValueError(f'{self.path} has unknown format "{fmt}".')
                self.envelope = {k: v for k, v in raw.items() if k != "people"}
                rows = raw.get("people") or []
            else:
                rows = raw or []
            self.people = [r for r in rows if isinstance(r, dict)]

    def save(self) -> Path:
        self.envelope["format"] = PEOPLE_FORMAT
        self.people.sort(key=lambda r: str(r.get("name", "")).lower())
        _write_atomic(self.path, {**self.envelope, "people": self.people})
        return self.path

    # ── Lookup ──────────────────────────────────────────────────────

    def get(self, person_id: str) -> dict | None:
        return next((p for p in self.people if p.get("id") == person_id), None)

    def match(
        self,
        *,
        uscf_id: str | None = None,
        fide_id: int | None = None,
        chesscom: list[str] = (),
        lichess: list[str] = (),
        names: list[str] = (),
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
