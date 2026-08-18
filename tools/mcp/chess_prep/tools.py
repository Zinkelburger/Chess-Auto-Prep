"""Tool registry for the standalone prep server.

Identity / pairing tools need no chess engine and no running app — just the
shipped directory, the US Chess API, and a roster file. Opening-tree tools
(`pgn_open`, `pgn_position`, `pgn_walk`, `pgn_eval`, `pgn_audit`) sit beside
them and need `python-chess` (and Stockfish for eval/audit).

The hand-off to the app for a tournament is a file: `opponents_export` writes
an opponent list that Player Analysis imports. Opening-tree tools query a PGN
in place so an agent can ask what a Colle (or any) repertoire plays against a
given line, including transpositions.
"""

from __future__ import annotations

from typing import Any, Callable

from . import uscf
from .directory import PlayerDirectory
from .roster import (
    Roster,
    RosterEntry,
    load_roster,
    parse_entry_list,
    roster_to_csv,
    save_roster,
)
from .opponents import opponents_document, write_opponents
from .paths import opponents_path, roster_path
from .swiss import SimulationConfig, simulate


class ToolError(Exception):
    """A bad argument or an impossible request — reported to the model as
    readable text rather than a stack trace, so it can correct itself."""


def _obj(properties: dict, required: list[str] | None = None) -> dict:
    schema: dict[str, Any] = {
        "type": "object",
        "properties": properties,
        "additionalProperties": False,
    }
    if required:
        schema["required"] = required
    return schema


def _s(description: str) -> dict:
    return {"type": "string", "description": description}


def _i(description: str) -> dict:
    return {"type": "integer", "description": description}


def _n(description: str) -> dict:
    return {"type": "number", "description": description}


def _b(description: str) -> dict:
    return {"type": "boolean", "description": description}


_CONFIDENCE_ORDER = {"exact", "high", "medium", "low", "ambiguous"}
_TRUSTED_SOURCES = {"uscf_online_event", "self_declared", "manual"}


class Registry:
    def __init__(self) -> None:
        self._directory: PlayerDirectory | None = None
        self.tools: dict[str, dict] = {}
        self._handlers: dict[str, Callable[[dict], Any]] = {}
        self._register_all()

    # ── Lazily loaded directory ────────────────────────────────────────────

    @property
    def directory(self) -> PlayerDirectory:
        if self._directory is None:
            self._directory = PlayerDirectory.load()
        return self._directory

    # ── Registration ───────────────────────────────────────────────────────

    def _add(
        self,
        name: str,
        description: str,
        schema: dict,
        handler: Callable[[dict], Any],
    ) -> None:
        self.tools[name] = {
            "name": name,
            "description": description,
            "inputSchema": schema,
        }
        self._handlers[name] = handler

    def definitions(self) -> list[dict]:
        return list(self.tools.values())

    def call(self, name: str, args: dict) -> Any:
        handler = self._handlers.get(name)
        if handler is None:
            raise ToolError(f'Unknown tool "{name}".')
        return handler(args or {})

    # ── Tools ──────────────────────────────────────────────────────────────

    def _register_all(self) -> None:
        self._add(
            "directory_search",
            "Look up a player in the bundled USCF → chess.com directory. The "
            "mapping was built from USCF-rated events hosted on chess.com by "
            "matching round-by-round opponents between the two crosstables, "
            "so hits are structural rather than inferred. Search by USCF ID "
            "(exact and preferred), name, or chess.com username. Coverage is "
            "partial: a miss does NOT mean the player has no account — call "
            "uscf_member to find out whether they are mappable at all.",
            _obj(
                {
                    "uscf_id": _s("Exact USCF member ID. The most reliable key."),
                    "name": _s('Name, "First Last" or "Last, First".'),
                    "chesscom_username": _s("Reverse lookup: who owns this account?"),
                    "query": _s("Free-text search across all three fields."),
                    "limit": _i("Max results for a free-text query (default 25)."),
                }
            ),
            self._directory_search,
        )

        self._add(
            "directory_stats",
            "Size and provenance of the bundled directory, and which USCF "
            "events it was built from. Check this before assuming a low hit "
            "rate is permanent — the mapping covers only the events that have "
            "been processed so far.",
            _obj({}),
            self._directory_stats,
        )

        self._add(
            "uscf_member",
            "Look up a player in the official US Chess ratings API. Returns "
            "their OTB ratings AND, crucially, whether they hold USCF *online* "
            "ratings. Online ratings mean they played USCF-rated events on "
            "chess.com, so the directory can in principle resolve them and a "
            "miss is a backfill gap. No online ratings means web search is the "
            "only route. Use this to decide where to spend effort.",
            _obj({"uscf_id": _s("USCF member ID.")}, ["uscf_id"]),
            self._uscf_member,
        )

        self._add(
            "uscf_coverage_report",
            "Run uscf_member across the whole loaded roster (or a given list) "
            "and report how many entrants are mappable in principle. This is "
            "the right first diagnostic on a new field: it separates 'the "
            "directory needs a backfill' from 'this player was never online-"
            "rated'. Makes one rate-limited API call per player, so it takes "
            "roughly a second each.",
            _obj(
                {
                    "uscf_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Defaults to every entrant on the roster.",
                    }
                }
            ),
            self._uscf_coverage,
        )

        self._add(
            "roster_import",
            "Parse a tournament entry list into the shared roster and save it. "
            "Accepts CSV/TSV with a header row, or pasted column-aligned text "
            "— paste the organizer's page contents directly. Handles US Chess "
            "event pages, where FIDE ID precedes USCF ID (both 7-9 digits) and "
            "only the header row disambiguates them. Replaces any roster "
            "currently saved.",
            _obj(
                {
                    "text": _s("The raw entry list."),
                    "event_name": _s("Event name, used in exports."),
                    "rounds": _i("Number of rounds (default 5)."),
                    "accelerated": _b(
                        "Accelerated pairings. Stated in the event "
                        "announcement; never auto-detected."
                    ),
                    "my_name": _s("Your name as it appears on the list."),
                    "my_uscf_id": _s("Your USCF ID — more reliable than the name."),
                },
                ["text"],
            ),
            self._roster_import,
        )

        self._add(
            "roster_get",
            "The shared roster as it stands, including any identities resolved "
            "so far. With unresolved_only, returns just the entrants still "
            "lacking a usable account — your work list.",
            _obj({"unresolved_only": _b("Return only the work list.")}),
            self._roster_get,
        )

        self._add(
            "roster_resolve",
            "Resolve every entrant against the bundled directory and save the "
            "result. Run this FIRST, before any web searching: it is exact "
            "where it hits and costs nothing. Identities the user confirmed "
            "manually are never overwritten.",
            _obj({}),
            self._roster_resolve,
        )

        self._add(
            "roster_update",
            "Apply a late change to one entrant: a withdrawal, an uncertain "
            "entry, a half-point bye request, a corrected rating, or marking "
            "who you are. These are the messy real-world facts that move a "
            "pairing sheet; the simulator absorbs them as parameters rather "
            "than needing certainty.",
            _obj(
                {
                    "player_id": _s("Roster id (USCF ID, or the name slug)."),
                    "withdrawn": _b("Remove from the pairing pool."),
                    "attendance_prob": _n(
                        "Probability (0-1) this entrant plays. Use for "
                        "unconfirmed entries instead of forcing a yes/no."
                    ),
                    "half_point_byes": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "description": "Rounds this player sits out.",
                    },
                    "rating": _i("Corrected rating."),
                    "is_me": _b("Mark as you (clears any previous mark)."),
                },
                ["player_id"],
            ),
            self._roster_update,
        )

        self._add(
            "identity_propose",
            "Record an online account you believe belongs to an entrant, with "
            "the evidence. This is a PROPOSAL: stored and shown to the user, "
            "but it will NOT drive prep until confirmed, because a wrong match "
            "means preparing against the wrong person. Put what you actually "
            "saw in evidence — quote the profile line or search result rather "
            "than summarising. If several accounts are plausible, list them "
            "all in alternates instead of picking one.",
            _obj(
                {
                    "player_id": _s("Roster id of the entrant."),
                    "chesscom_username": _s("Proposed chess.com account."),
                    "lichess_username": _s("Proposed lichess account."),
                    "evidence": _s("Why you believe this holds. Quote the source."),
                    "confidence": {
                        "type": "string",
                        "enum": ["high", "medium", "low"],
                        "description": (
                            'Use "high" only for a self-declared profile or an '
                            "equivalent direct statement."
                        ),
                    },
                    "alternates": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Other plausible accounts.",
                    },
                },
                ["player_id", "evidence"],
            ),
            self._identity_propose,
        )

        self._add(
            "identity_confirm",
            "Promote a proposed account to a confirmed one, making it usable "
            "for prep. Only call this when the user has explicitly approved "
            "the match — it is the single step between 'an agent thinks so' "
            "and 'games get downloaded and prepared against'.",
            _obj(
                {
                    "player_id": _s("Roster id of the entrant."),
                    "chesscom_username": _s("Account to confirm, if changing it."),
                    "lichess_username": _s("Account to confirm, if changing it."),
                },
                ["player_id"],
            ),
            self._identity_confirm,
        )

        self._add(
            "constraint_add",
            "Record that two entrants must never be paired — family members, "
            "club-mates, or a TD instruction. The pairer routes around these "
            "the same way it avoids rematches.",
            _obj(
                {
                    "player_a": _s("Roster id of the first player."),
                    "player_b": _s("Roster id of the second player."),
                    "reason": _s("Why, for the report."),
                },
                ["player_a", "player_b"],
            ),
            self._constraint_add,
        )

        self._add(
            "roster_export",
            "Render the roster as CSV, including every resolved account and "
            "its evidence. Re-importing this file preserves provenance, so an "
            "unconfirmed proposal stays unconfirmed.",
            _obj({}),
            self._roster_export,
        )

        self._add(
            "pairing_simulate",
            "Monte Carlo the whole event and return P(face) for every entrant "
            "in your section, split by the colour you would hold and by "
            "round. Does not predict the pairing sheet — it samples the event "
            "thousands of times so withdrawals, attendance doubts, byes and "
            "withholds (constraint_add) are absorbed rather than breaking it. "
            "Needs one entrant marked is_me (roster_update). Round 1 is "
            "near-deterministic; rounds 4+ diffuse toward the players near "
            "your rating, which is the honest answer.",
            _obj(
                {
                    "trials": _i("Simulated events. Default 2000."),
                    "seed": _i("RNG seed, for reproducibility."),
                    "draw_rate": _n("Draw rate between equals. Default 0.30."),
                    "unrated_rating": _i(
                        "Rating assumed for unrated entrants. Default: field median."
                    ),
                    "min_prob": _n(
                        "Omit opponents below this P(face) from the list. Default 0."
                    ),
                }
            ),
            self._pairing_simulate,
        )

        self._add(
            "opponents_export",
            "Write the opponent list the app's Player Analysis imports: one "
            "row per entrant with a usable account — name, chess.com and/or "
            "lichess username, rating, and P(face) if pairing_simulate has "
            "run. Only CONFIRMED identities are included; proposals are "
            "listed under `skipped` so the user can see what a confirmation "
            "would unlock. In the app: Player Analysis → Import opponents → "
            "pick the file (the path is returned).",
            _obj(
                {
                    "path": _s(
                        "Where to write. Default: opponents.json next to the roster."
                    ),
                    "min_prob": _n(
                        "Skip opponents below this P(face). Default 0 (everyone "
                        "with an account). Requires pairing_simulate first."
                    ),
                    "include_unconfirmed": _b(
                        "Also export agent proposals the user has NOT confirmed. "
                        "Off by default — see the trust rule."
                    ),
                }
            ),
            self._opponents_export,
        )

        from .opening import register_opening_tools

        register_opening_tools(self)

    # ── Handlers ───────────────────────────────────────────────────────────

    def _directory_search(self, args: dict) -> dict:
        directory = self.directory
        uscf_id = (args.get("uscf_id") or "").strip()
        username = (args.get("chesscom_username") or "").strip()
        name = (args.get("name") or "").strip()
        query = (args.get("query") or "").strip()

        if uscf_id:
            hit = directory.by_uscf_id(uscf_id)
            return {"found": hit is not None, **({"entry": hit.to_dict()} if hit else {})}
        if username:
            hit = directory.by_chesscom_username(username)
            return {
                "found": hit is not None,
                **({"entry": hit.to_dict()} if hit else {}),
                "title": directory.title_for(username),
            }
        if name:
            matches = directory.by_name(name)
            return {
                "found": bool(matches),
                "unique": len(matches) == 1,
                "entries": [m.to_dict() for m in matches],
            }
        if query:
            results = directory.search(query, int(args.get("limit") or 25))
            return {"count": len(results), "entries": [r.to_dict() for r in results]}

        raise ToolError("Supply one of uscf_id, name, chesscom_username, or query.")

    def _directory_stats(self, args: dict) -> dict:
        directory = self.directory
        return {
            "mapped_players": directory.player_count,
            "titled_accounts": directory.titled_count,
            "uscf_events_processed": directory.events_processed,
            "source": (
                "Opponent-graph matching over USCF-rated events hosted by "
                "CHESSCOM LLC (USCF affiliate A6044892)."
            ),
            "coverage_note": (
                "Only events already processed are represented. If a player "
                "has USCF online ratings but misses here, their events have "
                "not been processed yet — see scripts/build_player_map.py."
            ),
            "roster_file": str(roster_path()),
        }

    def _uscf_member(self, args: dict) -> dict:
        uscf_id = (args.get("uscf_id") or "").strip()
        if not uscf_id:
            raise ToolError("uscf_id is required.")
        try:
            return uscf.member(uscf_id)
        except uscf.UscfError as e:
            raise ToolError(str(e)) from e

    def _uscf_coverage(self, args: dict) -> dict:
        ids = args.get("uscf_ids")
        if not ids:
            roster = load_roster()
            ids = [e.uscf_id for e in roster.entries if e.uscf_id]
            if not ids:
                raise ToolError(
                    "No USCF IDs on the roster and none supplied. Import an "
                    "entry list first, or pass uscf_ids."
                )
        return uscf.coverage_report([str(i) for i in ids])

    def _roster_import(self, args: dict) -> dict:
        text = args.get("text") or ""
        if not text.strip():
            raise ToolError("text is required and must be non-empty.")

        roster, warnings, fmt = parse_entry_list(
            text,
            event_name=args.get("event_name") or "",
            rounds=int(args.get("rounds") or 5),
            accelerated=bool(args.get("accelerated", False)),
            my_name=args.get("my_name"),
            my_uscf_id=args.get("my_uscf_id"),
        )
        save_roster(roster)

        me = roster.me
        return {
            "format": fmt,
            "entry_count": len(roster.entries),
            "sections": roster.sections,
            "me": me.to_dict() if me else None,
            "warnings": warnings,
            "saved_to": str(roster_path()),
            "entries": [e.to_dict() for e in roster.entries],
        }

    def _roster_get(self, args: dict) -> dict:
        roster = load_roster()
        if args.get("unresolved_only"):
            return {
                "event_name": roster.event_name,
                "unresolved": [
                    {
                        "id": e.id,
                        "name": e.name,
                        **({"uscf_id": e.uscf_id} if e.uscf_id else {}),
                        **({"rating": e.rating} if e.rating is not None else {}),
                        **({"title": e.title} if e.title else {}),
                        **(
                            {"candidates": (e.identity or {}).get("alternates")}
                            if (e.identity or {}).get("alternates")
                            else {}
                        ),
                    }
                    for e in roster.entries
                    if not e.is_me and not e.is_actionable
                ],
            }
        return roster.to_dict()

    def _roster_resolve(self, args: dict) -> dict:
        roster = load_roster()
        if not roster.entries:
            raise ToolError("No roster loaded. Call roster_import first.")

        directory = self.directory
        resolved = ambiguous = unresolved = 0

        for entry in roster.entries:
            identity = entry.identity or {}
            # The user's own assertion outranks a lookup.
            if identity.get("source") == "manual" and entry.has_account:
                resolved += 1
                continue

            found = directory.resolve(uscf_id=entry.uscf_id, name=entry.name)
            if not found:
                unresolved += 1
                continue

            username = found.get("chesscom_username")
            if username and not found.get("title"):
                title = directory.title_for(username)
                if title:
                    found["title"] = title

            entry.identity = found
            if found.get("chesscom_username") or found.get("lichess_username"):
                resolved += 1
            else:
                ambiguous += 1

        save_roster(roster)
        total = resolved + ambiguous + unresolved
        return {
            "resolved": resolved,
            "ambiguous": ambiguous,
            "unresolved": unresolved,
            "hit_rate": (resolved / total) if total else 0.0,
            "unresolved_entries": self._roster_get({"unresolved_only": True})[
                "unresolved"
            ],
            "next_step": (
                "Call uscf_coverage_report to see which of the unresolved "
                "entrants are mappable in principle before web searching."
            ),
        }

    def _roster_update(self, args: dict) -> dict:
        roster = load_roster()
        player_id = (args.get("player_id") or "").strip()
        entry = roster.find(player_id)
        if entry is None:
            raise ToolError(f'No entrant with id "{player_id}" on the roster.')

        if args.get("is_me") is True:
            for other in roster.entries:
                other.is_me = False
            entry.is_me = True
        elif args.get("is_me") is False:
            entry.is_me = False

        if "withdrawn" in args:
            entry.withdrawn = bool(args["withdrawn"])
        if "attendance_prob" in args:
            prob = float(args["attendance_prob"])
            if not 0.0 <= prob <= 1.0:
                raise ToolError("attendance_prob must be between 0 and 1.")
            entry.attendance_prob = prob
        if "half_point_byes" in args:
            entry.half_point_byes = [int(r) for r in args["half_point_byes"]]
        if "rating" in args:
            entry.rating = int(args["rating"])

        save_roster(roster)
        return {"updated": player_id, "entry": entry.to_dict()}

    def _identity_propose(self, args: dict) -> dict:
        roster = load_roster()
        player_id = (args.get("player_id") or "").strip()
        entry = roster.find(player_id)
        if entry is None:
            raise ToolError(f'No entrant with id "{player_id}" on the roster.')

        evidence = (args.get("evidence") or "").strip()
        if not evidence:
            raise ToolError(
                "evidence is required — an account without a stated reason "
                "cannot be reviewed by the user."
            )

        chesscom = (args.get("chesscom_username") or "").strip()
        lichess = (args.get("lichess_username") or "").strip()
        if not chesscom and not lichess:
            raise ToolError(
                "Supply chesscom_username and/or lichess_username."
            )

        confidence = (args.get("confidence") or "medium").strip()
        if confidence not in _CONFIDENCE_ORDER:
            confidence = "medium"

        identity: dict[str, Any] = {
            "confidence": confidence,
            "source": "agent_proposed",
            "evidence": evidence,
        }
        if chesscom:
            identity["chesscom_username"] = chesscom
        if lichess:
            identity["lichess_username"] = lichess
        if args.get("alternates"):
            identity["alternates"] = [str(a) for a in args["alternates"]]

        entry.identity = identity
        save_roster(roster)

        return {
            "proposed": player_id,
            "actionable": False,
            "note": (
                "Stored as a proposal. The user must confirm it (or call "
                "identity_confirm) before prep will run against this account."
            ),
        }

    def _identity_confirm(self, args: dict) -> dict:
        roster = load_roster()
        player_id = (args.get("player_id") or "").strip()
        entry = roster.find(player_id)
        if entry is None:
            raise ToolError(f'No entrant with id "{player_id}" on the roster.')

        existing = entry.identity or {}
        chesscom = (
            args.get("chesscom_username") or existing.get("chesscom_username")
        )
        lichess = args.get("lichess_username") or existing.get("lichess_username")
        if not chesscom and not lichess:
            raise ToolError(
                "Nothing to confirm — no account is proposed for this entrant."
            )

        prior = existing.get("evidence")
        identity: dict[str, Any] = {
            "confidence": "exact",
            "source": "manual",
            "evidence": (
                f"Confirmed by the user — {prior}" if prior else "Confirmed by the user"
            ),
        }
        if chesscom:
            identity["chesscom_username"] = chesscom
        if lichess:
            identity["lichess_username"] = lichess
        if existing.get("title"):
            identity["title"] = existing["title"]

        entry.identity = identity
        save_roster(roster)
        return {"confirmed": player_id, "entry": entry.to_dict()}

    def _constraint_add(self, args: dict) -> dict:
        roster = load_roster()
        a = (args.get("player_a") or "").strip()
        b = (args.get("player_b") or "").strip()
        if not a or not b:
            raise ToolError("player_a and player_b are required.")
        for player_id in (a, b):
            if roster.find(player_id) is None:
                raise ToolError(f'No entrant with id "{player_id}" on the roster.')
        if a == b:
            raise ToolError("A player cannot be withheld from themselves.")

        constraint: dict[str, Any] = {"a": a, "b": b}
        if args.get("reason"):
            constraint["reason"] = str(args["reason"])
        roster.constraints.append(constraint)
        save_roster(roster)
        return {"constraints": len(roster.constraints)}

    def _roster_export(self, args: dict) -> dict:
        return {"format": "roster_csv", "content": roster_to_csv(load_roster())}

    def _pairing_simulate(self, args: dict) -> dict:
        roster = load_roster()
        if not roster.entries:
            raise ToolError("No roster loaded. Call roster_import first.")
        if roster.me is None:
            raise ToolError(
                "Nobody is marked as you. Call roster_update with is_me: true "
                "on your own entry first."
            )
        config = SimulationConfig(
            trials=int(args.get("trials") or 2000),
            seed=int(args.get("seed") or 20260806),
            draw_rate=float(args.get("draw_rate") or 0.30),
            unrated_rating=(
                int(args["unrated_rating"])
                if args.get("unrated_rating") is not None
                else None
            ),
        )
        result = simulate(roster, config)
        min_prob = float(args.get("min_prob") or 0.0)

        # Persist P(face) onto the roster so opponents_export can carry it
        # without the caller re-running the simulation.
        by_id = {o.player_id: o for o in result.opponents}
        for entry in roster.entries:
            o = by_id.get(entry.id)
            entry.pairing = o.to_dict() if o else None
        save_roster(roster)

        opponents = []
        for o in result.opponents:
            if o.prob_any < min_prob:
                continue
            entry = roster.find(o.player_id)
            row = o.to_dict()
            row["name"] = entry.name if entry else o.player_id
            if entry and entry.rating is not None:
                row["rating"] = entry.rating
            row["has_account"] = bool(entry and entry.is_actionable)
            opponents.append(row)

        out = result.to_dict()
        out["opponents"] = opponents
        out["omitted_below_min_prob"] = len(result.opponents) - len(opponents)
        out["next_step"] = (
            "Call opponents_export to write the list Player Analysis imports."
        )
        return out

    def _opponents_export(self, args: dict) -> dict:
        roster = load_roster()
        if not roster.entries:
            raise ToolError("No roster loaded. Call roster_import first.")
        min_prob = float(args.get("min_prob") or 0.0)
        include_unconfirmed = bool(args.get("include_unconfirmed", False))
        doc, skipped = opponents_document(
            roster, min_prob=min_prob, include_unconfirmed=include_unconfirmed
        )
        target = args.get("path")
        path = write_opponents(doc, target or opponents_path())
        return {
            "path": str(path),
            "opponents": len(doc["opponents"]),
            "skipped": skipped,
            "next_step": (
                "In the app: Player Analysis → Import opponents → choose "
                f"{path}. Each opponent becomes one player entry with games "
                "from every listed account."
            ),
        }


__all__ = ["Registry", "ToolError", "Roster", "RosterEntry"]
