"""The opponent list — the one file the app reads from this tooling.

Player Analysis imports it (Player Analysis → Import opponents), downloads
each opponent's games from every account listed, and shows them as ordinary
players in the picker. Keep the shape stable: the Dart parser lives in
`lib/services/opponent_list.dart` and both sides agree on ``FORMAT``.

    {
      "format": "chess-auto-prep/opponents@1",
      "event": "Spring Open 2026",
      "opponents": [
        {"name": "John Smith", "chesscom": "jsmith", "lichess": "js_li",
         "rating": 1850, "pairing_prob": 0.42,
         "pairing_prob_white": 0.20, "pairing_prob_black": 0.22,
         "most_likely_round": 2, "note": "…"}
      ]
    }

Only ``name`` and at least one username are required. Everything else is
advisory and shown to the user; nothing in it changes what the app downloads.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any

from .roster import Roster, RosterEntry

FORMAT = "chess-auto-prep/opponents@1"


def _row(entry: RosterEntry) -> dict[str, Any]:
    identity = entry.identity or {}
    row: dict[str, Any] = {"name": entry.name}
    if identity.get("chesscom_username"):
        row["chesscom"] = identity["chesscom_username"]
    if identity.get("lichess_username"):
        row["lichess"] = identity["lichess_username"]
    if entry.rating is not None:
        row["rating"] = entry.rating
    if entry.title:
        row["title"] = entry.title
    if entry.uscf_id:
        row["uscf_id"] = entry.uscf_id
    if entry.pairing:
        p = entry.pairing
        row["pairing_prob"] = p.get("prob_any")
        row["pairing_prob_white"] = p.get("prob_as_white")
        row["pairing_prob_black"] = p.get("prob_as_black")
        if p.get("most_likely_round") is not None:
            row["most_likely_round"] = p["most_likely_round"]
    if identity.get("confidence") and identity.get("source"):
        row["identity"] = {
            "confidence": identity["confidence"],
            "source": identity["source"],
            **({"evidence": identity["evidence"]} if identity.get("evidence") else {}),
        }
    return row


def opponents_document(
    roster: Roster,
    *,
    min_prob: float = 0.0,
    include_unconfirmed: bool = False,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Build the export document. Returns ``(document, skipped)`` where
    ``skipped`` lists entrants left out and why, so an agent can report what a
    confirmation or a search would unlock."""
    rows: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []

    for entry in roster.entries:
        if entry.is_me or entry.withdrawn:
            continue
        prob = (entry.pairing or {}).get("prob_any")
        if not entry.has_account:
            skipped.append({"name": entry.name, "reason": "no account"})
            continue
        if not entry.is_actionable and not include_unconfirmed:
            skipped.append(
                {"name": entry.name, "reason": "account proposed but not confirmed"}
            )
            continue
        if min_prob > 0 and (prob is None or prob < min_prob):
            skipped.append(
                {
                    "name": entry.name,
                    "reason": (
                        f"P(face) {prob:.2f} below {min_prob:.2f}"
                        if prob is not None
                        else "no pairing probability — run pairing_simulate"
                    ),
                }
            )
            continue
        rows.append(_row(entry))

    # Most likely opponents first; unsimulated ones keep roster order after.
    rows.sort(key=lambda r: -(r.get("pairing_prob") or -1.0))

    doc: dict[str, Any] = {
        "format": FORMAT,
        "event": roster.event_name,
        "rounds": roster.rounds,
        "opponents": rows,
    }
    return doc, skipped


def write_opponents(doc: dict[str, Any], path: str | Path) -> Path:
    target = Path(path).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(target.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(doc, handle, indent=2)
        os.replace(tmp, target)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return target


__all__ = ["FORMAT", "opponents_document", "write_opponents"]
