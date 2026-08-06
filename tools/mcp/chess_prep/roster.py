"""The shared roster: model, entry-list parser, and disk persistence.

Wire-compatible with `lib/features/tournament/models/roster_entry.dart` — the
JSON this writes is what the Flutter app loads, so field names are the Dart
ones and must not drift.

The parser carries the same real-world traps the Dart one does, learned from
an actual US Chess event page: FIDE ID sits *before* USCF ID and both are 7-9
digits, FIDE rating before USCF rating, ratings read `Unr` or carry `[EQ]`,
and the name column smuggles in `(WCM)` and `(Withdrawn)`.
"""

from __future__ import annotations

import csv
import io
import json
import os
import re
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .paths import roster_path

# ── Header recognition ──────────────────────────────────────────────────────

_NAME_ALIASES = {
    "name",
    "player",
    "playername",
    "playersname",  # "Player's Name" — US Chess event pages
    "fullname",
    "participant",
    "entrant",
}
_USCF_ALIASES = {"uscf", "uscfid", "id", "memberid", "uscfno", "uscfnumber", "member"}
_RATING_ALIASES = {
    "rating",
    "elo",
    "uscfrating",
    "rtg",
    "pre",
    "prerating",
    "regrating",
    "rating1",
}
_SECTION_ALIASES = {"section", "sect", "sec", "division"}
_TITLE_ALIASES = {"title", "ttl"}
_CHESSCOM_ALIASES = {"chesscom", "chesscomusername", "chesscomhandle"}
_LICHESS_ALIASES = {"lichess", "lichessusername", "lichesshandle"}
# Provenance, written by roster_export. Reading these back is what stops a
# round trip from laundering an unconfirmed guess into a trusted identity.
_CONFIDENCE_ALIASES = {"confidence"}
_SOURCE_ALIASES = {"source"}
_EVIDENCE_ALIASES = {"evidence"}

_TITLE_TOKENS = {"GM", "IM", "FM", "CM", "NM", "WGM", "WIM", "WFM", "WCM", "LM"}

_USCF_ID = re.compile(r"^\d{7,9}$")
_RATING = re.compile(r"^(\d{3,4})\s*(?:[Pp]\d+|/\d+|\*)?$")
_BRACKET_SUFFIX = re.compile(r"\s*\[[^\]]*\]\s*")
_WITHDRAWN = re.compile(r"\(\s*withdrawn\s*\)", re.IGNORECASE)
_TITLE_PAREN = re.compile(
    r"\(\s*(GM|IM|FM|CM|NM|WGM|WIM|WFM|WCM|LM)\s*\)", re.IGNORECASE
)
_UNRATED_WORDS = {"unr", "unrated", "none", "nr", "n/a"}
_COLUMN_SPLIT = re.compile(r"\t|\s{2,}")
_SLUG_STRIP = re.compile(r"[^a-z0-9]+")


def _normalize_header(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", text.lower())


def _find_column(header: list[str], aliases: set[str]) -> int:
    for i, name in enumerate(header):
        if name in aliases:
            return i
    return -1


def _is_unrated_marker(raw: str) -> bool:
    cleaned = _BRACKET_SUFFIX.sub(" ", raw).strip().lower()
    return not cleaned or cleaned in _UNRATED_WORDS


def parse_rating(raw: str) -> int | None:
    cleaned = _BRACKET_SUFFIX.sub(" ", raw).strip()
    if not cleaned or cleaned.lower() in _UNRATED_WORDS:
        return None
    match = _RATING.match(cleaned)
    if not match:
        return None
    value = int(match.group(1))
    return value if 100 <= value <= 3200 else None


def clean_uscf_id(raw: str) -> str | None:
    digits = re.sub(r"[^0-9]", "", _BRACKET_SUFFIX.sub(" ", raw))
    return digits if _USCF_ID.match(digits) else None


def parse_name_cell(raw: str) -> tuple[str, str | None, bool]:
    """Split `Tereshchenko, Eliza (WCM) (Withdrawn)` into its three facts."""
    withdrawn = bool(_WITHDRAWN.search(raw))
    title_match = _TITLE_PAREN.search(raw)
    cleaned = _WITHDRAWN.sub(" ", raw)
    cleaned = _TITLE_PAREN.sub(" ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    title = title_match.group(1).upper() if title_match else None
    return cleaned, title, withdrawn


# ── Model ───────────────────────────────────────────────────────────────────


@dataclass
class RosterEntry:
    id: str
    name: str
    uscf_id: str | None = None
    rating: int | None = None
    section: str | None = None
    title: str | None = None
    identity: dict[str, Any] | None = None
    is_me: bool = False
    attendance_prob: float = 1.0
    half_point_byes: list[int] = field(default_factory=list)
    withdrawn: bool = False

    def to_dict(self) -> dict:
        out: dict[str, Any] = {"id": self.id, "name": self.name}
        if self.uscf_id:
            out["uscf_id"] = self.uscf_id
        if self.rating is not None:
            out["rating"] = self.rating
        if self.section:
            out["section"] = self.section
        if self.title:
            out["title"] = self.title
        if self.identity:
            out["identity"] = self.identity
        if self.is_me:
            out["is_me"] = True
        if self.attendance_prob != 1.0:
            out["attendance_prob"] = self.attendance_prob
        if self.half_point_byes:
            out["half_point_byes"] = sorted(self.half_point_byes)
        if self.withdrawn:
            out["withdrawn"] = True
        return out

    @classmethod
    def from_dict(cls, data: dict) -> "RosterEntry":
        return cls(
            id=str(data.get("id") or data.get("uscf_id") or data.get("name") or ""),
            name=str(data.get("name", "")),
            uscf_id=data.get("uscf_id"),
            rating=data.get("rating"),
            section=data.get("section"),
            title=data.get("title"),
            identity=data.get("identity"),
            is_me=bool(data.get("is_me", False)),
            attendance_prob=float(data.get("attendance_prob", 1.0)),
            half_point_byes=list(data.get("half_point_byes", [])),
            withdrawn=bool(data.get("withdrawn", False)),
        )

    @property
    def has_account(self) -> bool:
        i = self.identity or {}
        return bool(i.get("chesscom_username") or i.get("lichess_username"))

    @property
    def is_actionable(self) -> bool:
        """Whether prep may run against this identity without asking."""
        i = self.identity or {}
        return (
            self.has_account
            and not i.get("alternates")
            and i.get("confidence") in {"exact", "high"}
            and i.get("source") in {"uscf_online_event", "self_declared", "manual"}
        )


@dataclass
class Roster:
    event_name: str = ""
    entries: list[RosterEntry] = field(default_factory=list)
    constraints: list[dict] = field(default_factory=list)
    rounds: int = 5
    accelerated: bool = False

    def to_dict(self) -> dict:
        out: dict[str, Any] = {
            "event_name": self.event_name,
            "rounds": self.rounds,
            "accelerated": self.accelerated,
            "entries": [e.to_dict() for e in self.entries],
        }
        if self.constraints:
            out["constraints"] = self.constraints
        return out

    @classmethod
    def from_dict(cls, data: dict) -> "Roster":
        return cls(
            event_name=str(data.get("event_name", "")),
            rounds=int(data.get("rounds", 5)),
            accelerated=bool(data.get("accelerated", False)),
            entries=[RosterEntry.from_dict(e) for e in data.get("entries", [])],
            constraints=list(data.get("constraints", [])),
        )

    def find(self, player_id: str) -> RosterEntry | None:
        for e in self.entries:
            if e.id == player_id:
                return e
        return None

    @property
    def me(self) -> RosterEntry | None:
        for e in self.entries:
            if e.is_me:
                return e
        return None

    @property
    def sections(self) -> list[str]:
        seen: list[str] = []
        for e in self.entries:
            if e.section and e.section not in seen:
                seen.append(e.section)
        return seen


# ── Persistence ─────────────────────────────────────────────────────────────


def load_roster() -> Roster:
    path = roster_path()
    if not path.exists():
        return Roster()
    try:
        return Roster.from_dict(json.loads(path.read_text()))
    except (json.JSONDecodeError, OSError, TypeError, ValueError):
        # A corrupt roster must not wedge the server; the user can re-import.
        return Roster()


def save_roster(roster: Roster) -> Path:
    """Write atomically — the app may be watching this file and must never
    observe a half-written one."""
    path = roster_path()
    path.parent.mkdir(parents=True, exist_ok=True)

    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(roster.to_dict(), handle, indent=2)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return path


# ── Entry-list parsing ──────────────────────────────────────────────────────


def parse_entry_list(
    text: str,
    event_name: str = "",
    rounds: int = 5,
    accelerated: bool = False,
    my_name: str | None = None,
    my_uscf_id: str | None = None,
) -> tuple[Roster, list[str], str]:
    """Return `(roster, warnings, format)`."""
    warnings: list[str] = []
    trimmed = text.strip()
    if not trimmed:
        return Roster(event_name=event_name, rounds=rounds), ["Entry list was empty."], "text"

    entries = _parse_csv(trimmed, warnings)
    fmt = "csv"
    if entries is None:
        entries = _parse_freeform(trimmed, warnings)
        fmt = "text"

    entries = _assign_ids(entries, warnings)
    entries = _mark_self(entries, my_name, my_uscf_id, warnings)

    if not entries:
        warnings.append("No entrants could be parsed from the input.")

    return (
        Roster(
            event_name=event_name,
            entries=entries,
            rounds=rounds,
            accelerated=accelerated,
        ),
        warnings,
        fmt,
    )


def _sniff_delimiter(text: str) -> str:
    head = text.split("\n", 1)[0]
    # Tab-separated pastes out of a web table are the common non-comma case.
    return "\t" if head.count("\t") >= head.count(",") and "\t" in head else ","


def _parse_csv(text: str, warnings: list[str]) -> list[RosterEntry] | None:
    """None when the input has no recognizable header, so the caller falls
    through to the freeform parser."""
    try:
        reader = csv.reader(
            io.StringIO(text.replace("\r\n", "\n")),
            delimiter=_sniff_delimiter(text),
        )
        rows = [r for r in reader if any(c.strip() for c in r)]
    except csv.Error:
        return None

    if len(rows) < 2:
        return None

    header = [_normalize_header(c) for c in rows[0]]
    name_col = _find_column(header, _NAME_ALIASES)
    if name_col < 0:
        return None

    uscf_col = _find_column(header, _USCF_ALIASES)
    rating_col = _find_column(header, _RATING_ALIASES)
    section_col = _find_column(header, _SECTION_ALIASES)
    title_col = _find_column(header, _TITLE_ALIASES)
    chesscom_col = _find_column(header, _CHESSCOM_ALIASES)
    lichess_col = _find_column(header, _LICHESS_ALIASES)
    confidence_col = _find_column(header, _CONFIDENCE_ALIASES)
    source_col = _find_column(header, _SOURCE_ALIASES)
    evidence_col = _find_column(header, _EVIDENCE_ALIASES)

    if rating_col < 0:
        warnings.append(
            "No rating column found — every entrant will be treated as "
            "unrated, which makes seeding and pairing simulation meaningless."
        )

    entries: list[RosterEntry] = []
    for i, row in enumerate(rows[1:], start=2):

        def cell(col: int) -> str:
            return row[col].strip() if 0 <= col < len(row) else ""

        raw_name = cell(name_col)
        if not raw_name:
            continue
        name, paren_title, withdrawn = parse_name_cell(raw_name)

        rating_raw = cell(rating_col)
        rating = parse_rating(rating_raw)
        if rating is None and not _is_unrated_marker(rating_raw):
            warnings.append(f'Row {i}: could not read rating "{rating_raw}".')

        entries.append(
            RosterEntry(
                id="",
                name=name,
                uscf_id=clean_uscf_id(cell(uscf_col)),
                rating=rating,
                section=cell(section_col) or None,
                title=cell(title_col).upper() or paren_title,
                withdrawn=withdrawn,
                identity=_identity_from_columns(
                    cell(chesscom_col),
                    cell(lichess_col),
                    cell(confidence_col),
                    cell(source_col),
                    cell(evidence_col),
                ),
            )
        )

    return entries or None


def _parse_freeform(text: str, warnings: list[str]) -> list[RosterEntry]:
    entries: list[RosterEntry] = []

    for raw_line in text.split("\n"):
        line = raw_line.strip()
        if not line:
            continue

        tokens = [t.strip() for t in _COLUMN_SPLIT.split(line) if t.strip()]
        if len(tokens) < 2:
            tokens = [t for t in line.split(" ") if t]
        if not tokens:
            continue

        # Drop a leading pair/seed number ("1", "12.").
        if len(tokens) > 2:
            head = tokens[0].replace(".", "")
            if head.isdigit() and len(head) <= 3:
                tokens = tokens[1:]

        uscf_id: str | None = None
        rating: int | None = None
        title: str | None = None
        name_tokens: list[str] = []

        for token in tokens:
            if uscf_id is None and _USCF_ID.match(token):
                uscf_id = token
                continue
            if rating is None:
                parsed = parse_rating(token)
                if parsed is not None:
                    rating = parsed
                    continue
            if title is None and token.upper() in _TITLE_TOKENS:
                title = token.upper()
                continue
            name_tokens.append(token)

        name = " ".join(name_tokens).strip()
        if not name or name.replace(" ", "").isdigit():
            continue

        name, paren_title, withdrawn = parse_name_cell(name)
        if rating is None and uscf_id is None:
            warnings.append(f'Line "{line}": no rating or USCF ID found.')

        entries.append(
            RosterEntry(
                id="",
                name=name,
                uscf_id=uscf_id,
                rating=rating,
                title=title or paren_title,
                withdrawn=withdrawn,
            )
        )

    return entries


def _identity_from_columns(
    chesscom: str, lichess: str, confidence: str, source: str, evidence: str
) -> dict | None:
    cc, li = chesscom.strip(), lichess.strip()
    if not cc and not li:
        return None

    has_provenance = bool(confidence.strip() or source.strip())
    out: dict[str, Any] = {
        "confidence": confidence.strip() if has_provenance else "exact",
        "source": source.strip() if has_provenance else "manual",
        "evidence": evidence.strip() or "Supplied on the imported entry list",
    }
    if cc:
        out["chesscom_username"] = cc
    if li:
        out["lichess_username"] = li
    return out


def _assign_ids(
    entries: list[RosterEntry], warnings: list[str]
) -> list[RosterEntry]:
    used: set[str] = set()
    for entry in entries:
        base = (entry.uscf_id or "").strip()
        if not base:
            base = _SLUG_STRIP.sub("-", entry.name.lower()).strip("-") or "player"

        candidate, n = base, 2
        while candidate in used:
            candidate = f"{base}-{n}"
            n += 1
        used.add(candidate)

        if n > 2 and entry.uscf_id:
            warnings.append(
                f"Duplicate USCF ID {entry.uscf_id} for "
                f'"{entry.name}" — kept both entrants under distinct ids.'
            )
        entry.id = candidate
    return entries


def _mark_self(
    entries: list[RosterEntry],
    my_name: str | None,
    my_uscf_id: str | None,
    warnings: list[str],
) -> list[RosterEntry]:
    want_id = (my_uscf_id or "").strip()
    want_name = (my_name or "").strip().lower()
    if not want_id and not want_name:
        return entries

    for entry in entries:
        by_id = bool(want_id) and (entry.uscf_id or "").strip() == want_id
        by_name = bool(want_name) and entry.name.lower() == want_name
        if by_id or by_name:
            entry.is_me = True
            return entries

    looked_for = f"USCF {want_id}" if want_id else f'"{my_name}"'
    warnings.append(
        f"You were not found on the entry list (looked for {looked_for}). "
        "Set yourself manually — pairing probabilities need a reference point."
    )
    return entries


# ── CSV export ──────────────────────────────────────────────────────────────

CSV_HEADER = [
    "Name",
    "USCF ID",
    "Rating",
    "Section",
    "Title",
    "chess.com",
    "lichess",
    "Confidence",
    "Source",
    "Evidence",
]


def roster_to_csv(roster: Roster) -> str:
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n")
    writer.writerow(CSV_HEADER)
    for e in roster.entries:
        i = e.identity or {}
        writer.writerow(
            [
                e.name,
                e.uscf_id or "",
                e.rating if e.rating is not None else "",
                e.section or "",
                e.title or i.get("title") or "",
                i.get("chesscom_username", ""),
                i.get("lichess_username", ""),
                i.get("confidence", ""),
                i.get("source", ""),
                i.get("evidence", ""),
            ]
        )
    return buf.getvalue()
