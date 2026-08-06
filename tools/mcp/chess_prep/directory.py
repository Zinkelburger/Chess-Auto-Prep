"""USCF → chess.com directory lookup, and the name normalization it needs.

Port of `lib/features/tournament/services/player_directory.dart` and
`player_name.dart`. The two must agree: the app and this server resolve the
same roster, and a name key that differs between them would silently produce
different identities on either side.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Iterable

from .paths import ASSET_MAP, ASSET_TITLED, SOURCE_MAP, TITLED_DIR

# ── Name normalization ──────────────────────────────────────────────────────

_SUFFIXES = {"JR", "SR", "II", "III", "IV", "V"}
# The hyphen is deliberately absent: it means opposite things on either side
# of a name and is handled per part below.
_PUNCT = re.compile(r"[.,'’_]")
_WHITESPACE = re.compile(r"\s+")

_TITLES_STRONGEST_FIRST = ["GM", "IM", "FM", "NM", "CM"]


def _raw_tokens(text: str) -> list[str]:
    cleaned = _WHITESPACE.sub(" ", _PUNCT.sub("", text.upper())).strip()
    if not cleaned:
        return []
    tokens = [t for t in cleaned.split(" ") if t]
    # Only strip a suffix when something would remain.
    while len(tokens) > 1 and tokens[-1] in _SUFFIXES:
        tokens.pop()
    return tokens


def _leading_given_name(part: str) -> str:
    """First given name only — the first whitespace- *or* hyphen-separated unit.

    `Anne-Marie` becomes `ANNE`, matching how `Anne Marie` resolves once the
    middle name is dropped.
    """
    tokens = _raw_tokens(part)
    if not tokens:
        return ""
    head = [t for t in tokens[0].split("-") if t]
    return head[0] if head else ""


def _join_surname(tokens: Iterable[str]) -> str:
    """A surname joined into one unit, hyphens absorbed (`Smith-Jones`)."""
    return "".join(tokens).replace("-", "")


def parse_player_name(raw: str) -> tuple[str, str]:
    """Return `(first, last)`, normalized. Handles both name orderings."""
    trimmed = raw.strip()
    if not trimmed:
        return "", ""

    if "," in trimmed:
        # `Van Der Berg, Jan` — everything before the comma is the surname,
        # so particles stay attached.
        last_part, first_part = trimmed.split(",", 1)
    else:
        tokens = _raw_tokens(trimmed)
        if not tokens:
            return "", ""
        if len(tokens) == 1:
            return "", _join_surname(tokens)
        last_part, first_part = tokens[-1], tokens[0]

    return _leading_given_name(first_part), _join_surname(_raw_tokens(last_part))


def player_name_key(raw: str) -> str:
    """The `FIRST|LAST` join key. Middle names are deliberately dropped."""
    first, last = parse_player_name(raw)
    return f"{first}|{last}"


# ── Directory ───────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class DirectoryEntry:
    uscf_id: str
    uscf_name: str
    chesscom_username: str
    confidence: str
    method: str
    event_id: str = ""
    event_date: str = ""
    title: str | None = None

    @property
    def evidence(self) -> str:
        parts = [
            f"USCF {self.uscf_id} ({self.uscf_name}) → {self.chesscom_username}"
        ]
        if self.method:
            parts.append(f"via {self.method}")
        if self.event_id:
            stamp = f" ({self.event_date})" if self.event_date else ""
            parts.append(f"in USCF event {self.event_id}{stamp}")
        return " ".join(parts)

    def to_dict(self) -> dict:
        out = {
            "uscf_id": self.uscf_id,
            "uscf_name": self.uscf_name,
            "chesscom_username": self.chesscom_username,
            "confidence": self.confidence,
            "method": self.method,
        }
        if self.event_id:
            out["event_id"] = self.event_id
        if self.event_date:
            out["event_date"] = self.event_date
        if self.title:
            out["title"] = self.title
        return out


class PlayerDirectory:
    """In-memory index over the shipped mapping."""

    def __init__(
        self,
        entries: Iterable[DirectoryEntry],
        titles: dict[str, str],
        events_processed: int = 0,
    ) -> None:
        self.titles = titles
        self.events_processed = events_processed
        self._by_id: dict[str, DirectoryEntry] = {}
        self._by_username: dict[str, DirectoryEntry] = {}
        self._by_name: dict[str, list[DirectoryEntry]] = {}

        for entry in entries:
            self._by_id[entry.uscf_id] = entry
            self._by_username[entry.chesscom_username.lower()] = entry
            if entry.uscf_name:
                self._by_name.setdefault(
                    player_name_key(entry.uscf_name), []
                ).append(entry)

    # ── Loading ────────────────────────────────────────────────────────────

    @classmethod
    def load(cls) -> "PlayerDirectory":
        """Prefer the bundled asset so the app and this server agree; fall
        back to the raw research output when the asset is missing."""
        titles = cls._load_titles()

        if ASSET_MAP.exists():
            raw = json.loads(ASSET_MAP.read_text())
            entries = [
                DirectoryEntry(
                    uscf_id=str(uscf_id),
                    uscf_name=row.get("n", ""),
                    chesscom_username=row.get("u", ""),
                    confidence=row.get("c", ""),
                    method=row.get("m", ""),
                    event_id=row.get("e", ""),
                    event_date=row.get("d", ""),
                    title=titles.get(row.get("u", "").lower()),
                )
                for uscf_id, row in raw.get("players", {}).items()
                if row.get("u")
            ]
            return cls(entries, titles, int(raw.get("events_processed", 0)))

        if SOURCE_MAP.exists():
            raw = json.loads(SOURCE_MAP.read_text())
            players = raw.get("players", {})
            entries = [
                DirectoryEntry(
                    uscf_id=str(uscf_id),
                    uscf_name=row.get("uscf_name", ""),
                    chesscom_username=row.get("chesscom_username", ""),
                    confidence=row.get("confidence", ""),
                    method=row.get("method", ""),
                    event_id=row.get("event_id", ""),
                    event_date=row.get("event_date", ""),
                    title=titles.get(
                        (row.get("chesscom_username") or "").lower()
                    ),
                )
                for uscf_id, row in players.items()
                if row.get("chesscom_username")
            ]
            return cls(
                entries, titles, len(raw.get("events_processed", []))
            )

        return cls([], titles, 0)

    @staticmethod
    def _load_titles() -> dict[str, str]:
        if ASSET_TITLED.exists():
            raw = json.loads(ASSET_TITLED.read_text())
            return {k.lower(): v for k, v in raw.get("titles", {}).items()}

        out: dict[str, str] = {}
        # Weakest first so stronger titles overwrite.
        for title in reversed(_TITLES_STRONGEST_FIRST):
            path = TITLED_DIR / f"titled_{title}.json"
            if path.exists():
                for username in json.loads(path.read_text()):
                    out[username.lower()] = title
        return out

    # ── Lookup ─────────────────────────────────────────────────────────────

    @property
    def player_count(self) -> int:
        return len(self._by_id)

    @property
    def titled_count(self) -> int:
        return len(self.titles)

    def by_uscf_id(self, uscf_id: str) -> DirectoryEntry | None:
        return self._by_id.get(uscf_id.strip())

    def by_chesscom_username(self, username: str) -> DirectoryEntry | None:
        return self._by_username.get(username.strip().lower())

    def title_for(self, username: str) -> str | None:
        return self.titles.get(username.strip().lower())

    def by_name(self, name: str) -> list[DirectoryEntry]:
        key = player_name_key(name)
        if key == "|":
            return []
        return list(self._by_name.get(key, []))

    def resolve(
        self, uscf_id: str | None = None, name: str | None = None
    ) -> dict | None:
        """Resolve to an identity dict, or None on a miss.

        Mirrors the Dart resolver: an ID match is exact, a unique name match is
        downgraded to medium (the row is certain, the claim that it is *this*
        entrant is not), and an ambiguous name returns candidates rather than a
        pick.
        """
        if uscf_id and uscf_id.strip():
            hit = self.by_uscf_id(uscf_id)
            if hit:
                return {
                    "chesscom_username": hit.chesscom_username,
                    "confidence": hit.confidence,
                    "source": "uscf_online_event",
                    "evidence": hit.evidence,
                    **({"title": hit.title} if hit.title else {}),
                }

        if name and name.strip():
            matches = self.by_name(name)
            if len(matches) == 1:
                hit = matches[0]
                return {
                    "chesscom_username": hit.chesscom_username,
                    "confidence": "medium",
                    "source": "uscf_online_event",
                    "evidence": f"{hit.evidence} (matched on name, not USCF ID)",
                    **({"title": hit.title} if hit.title else {}),
                }
            if len(matches) > 1:
                return {
                    "confidence": "ambiguous",
                    "source": "uscf_online_event",
                    "evidence": (
                        f"{len(matches)} directory rows share the name "
                        f'"{name}"'
                    ),
                    "alternates": [
                        f"{m.chesscom_username} (USCF {m.uscf_id})"
                        for m in matches
                    ],
                }

        return None

    def search(self, query: str, limit: int = 25) -> list[DirectoryEntry]:
        q = query.strip().lower()
        if not q:
            return []

        results: list[DirectoryEntry] = []
        seen: set[str] = set()

        def add(entry: DirectoryEntry | None) -> None:
            if entry and entry.uscf_id not in seen:
                seen.add(entry.uscf_id)
                results.append(entry)

        add(self.by_uscf_id(q))
        add(self.by_chesscom_username(q))
        for entry in self.by_name(query):
            add(entry)

        if len(results) < limit:
            for entry in self._by_id.values():
                if len(results) >= limit:
                    break
                if (
                    q in entry.uscf_name.lower()
                    or q in entry.chesscom_username.lower()
                    or q in entry.uscf_id
                ):
                    add(entry)

        return results[:limit]
