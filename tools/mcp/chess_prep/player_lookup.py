"""Find who a person is online and over the board, in a fixed order.

`player_lookup` runs one person through every local and public source this
server knows, cheapest and most certain first, and says plainly what it could
not find:

1. the players directory (`people.json`) — what the user already has;
2. the bundled USCF → chess.com directory — exact where it hits;
3. the US Chess API — their official spelling (an alias for free) and
   whether they ever played USCF-rated online;
4. the TWIC master-games database — every respelling, grouped by FIDE ID;
5. a probe of usernames built from the name on chess.com and Lichess,
   kept only when the profile's real name or title agrees.

`people_populate` does that for a whole roster and writes the answers into
the app's players directory, plus a group for the event. Nothing found by
guessing is ever put where the app downloads games from: probes and web
finds land in `lookup.candidates` until the user confirms one.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from . import uscf
from .names import handle_guesses, name_match
from .people import PeopleStore, TournamentStore, handles

#: At most this many username guesses per site per person.
MAX_GUESSES = 8

#: A TWIC identity is taken as this person when its latest FIDE Elo is
#: within this many points of the known rating (FIDE runs below USCF).
ELO_AGREEMENT = 300

_TRUSTED_SOURCES = {"uscf_online_event", "self_declared", "manual"}
_LICHESS_USERS = "https://lichess.org/api/users"


# ── Account probes ──────────────────────────────────────────────────────────


def _chesscom_profile(username: str) -> dict | None:
    from .chesscom import fetch_json

    return fetch_json(
        f"https://api.chess.com/pub/player/{urllib.parse.quote(username.lower())}"
    )


def _lichess_profiles(usernames: list[str]) -> list[dict]:
    """Every existing account among [usernames], in one request."""
    if not usernames:
        return []
    from .chesscom import USER_AGENT

    request = urllib.request.Request(
        _LICHESS_USERS,
        data=",".join(usernames).encode(),
        headers={"User-Agent": USER_AGENT, "Content-Type": "text/plain"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    return [u for u in payload if isinstance(u, dict)]


def _lichess_real_name(profile: dict) -> str:
    p = profile.get("profile") or {}
    if p.get("realName"):
        return str(p["realName"])
    return " ".join(str(p[k]) for k in ("firstName", "lastName") if p.get(k))


def _score(
    real_name: str,
    account_title: str | None,
    spellings: list[str],
    title: str | None,
    rating_signals: list[str],
) -> tuple[str, list[str]] | None:
    """Confidence and the reasons, or None when nothing but the handle
    agrees (a handle alone proves nothing)."""
    reasons: list[str] = []
    grade = None
    if real_name:
        grades = [g for s in spellings if (g := name_match(s, real_name))]
        if grades:
            grade = "exact" if "exact" in grades else grades[0]
            reasons.append(f'profile name "{real_name}" ({grade} match)')
    title_agrees = bool(title and account_title and title.upper() == account_title.upper())
    if title_agrees:
        reasons.append(f"title {account_title} matches")
    reasons += rating_signals
    if not grade and not title_agrees and not rating_signals:
        return None
    if grade == "exact" and (title_agrees or rating_signals):
        return "high", reasons
    if grade in ("exact", "spelling") or (title_agrees and rating_signals):
        return "medium", reasons
    return "low", reasons


def probe_accounts(
    spellings: list[str],
    *,
    title: str | None = None,
    rating: int | None = None,
    skip: set[tuple[str, str]] = frozenset(),
) -> dict[str, Any]:
    """Try usernames built from each spelling on chess.com and Lichess."""
    # Round-robin over spellings, so an alias gets its most likely
    # usernames tried before the first spelling's long tail.
    per_spelling = [handle_guesses(s) for s in spellings]
    guesses: list[str] = []
    for rank in range(max((len(g) for g in per_spelling), default=0)):
        for options in per_spelling:
            if rank < len(options) and options[rank] not in guesses:
                guesses.append(options[rank])
    guesses = guesses[:MAX_GUESSES]
    candidates: list[dict] = []
    rejected: list[str] = []
    errors: list[str] = []

    for username in guesses:
        if ("chesscom", username.lower()) in skip:
            continue
        try:
            profile = _chesscom_profile(username)
        except Exception as e:  # network trouble is reported, not raised
            errors.append(f"chess.com {username}: {e}")
            continue
        if not profile or "username" not in profile:
            continue
        status = str(profile.get("status") or "")
        if status.startswith("closed"):
            rejected.append(f"chess.com {profile['username']}: account {status}")
            continue
        scored = _score(
            str(profile.get("name") or ""), profile.get("title"), spellings, title, []
        )
        if scored is None:
            rejected.append(
                f"chess.com {profile['username']}: exists, but no real name or "
                "title to tie it to this person"
            )
            continue
        confidence, reasons = scored
        candidates.append(
            {
                "site": "chesscom",
                "username": profile["username"],
                "confidence": confidence,
                "evidence": "; ".join(reasons),
                "source": "handle_probe",
                "url": profile.get("url"),
            }
        )

    try:
        lichess = _lichess_profiles(
            [g for g in guesses if ("lichess", g.lower()) not in skip]
        )
    except Exception as e:
        lichess = []
        errors.append(f"lichess: {e}")
    for profile in lichess:
        name = profile.get("username") or profile.get("id")
        if profile.get("disabled") or profile.get("tosViolation"):
            rejected.append(f"lichess {name}: account closed")
            continue
        p = profile.get("profile") or {}
        rating_signals = []
        for key, label in (("uscfRating", "USCF"), ("fideRating", "FIDE")):
            value = p.get(key)
            if rating and isinstance(value, int) and abs(value - rating) <= ELO_AGREEMENT:
                rating_signals.append(f"profile {label} rating {value}")
        scored = _score(
            _lichess_real_name(profile), profile.get("title"), spellings, title,
            rating_signals,
        )
        if scored is None:
            rejected.append(
                f"lichess {name}: exists, but no real name, title or rating ties "
                "it to this person"
            )
            continue
        confidence, reasons = scored
        candidates.append(
            {
                "site": "lichess",
                "username": name,
                "confidence": confidence,
                "evidence": "; ".join(reasons),
                "source": "handle_probe",
                "url": f"https://lichess.org/@/{name}",
            }
        )
    return {
        "tried": guesses,
        "candidates": candidates,
        "rejected": rejected,
        **({"errors": errors} if errors else {}),
    }


# ── The chain ───────────────────────────────────────────────────────────────


def lookup_person(
    registry: Any,
    *,
    name: str,
    uscf_id: str | None = None,
    aliases: list[str] | None = None,
    rating: int | None = None,
    title: str | None = None,
    probe: bool = True,
    people: PeopleStore | None = None,
    master_db: Any = None,
    use_uscf: bool = True,
) -> dict[str, Any]:
    """Everything the sources say about one person, and what is still open.

    Pure reporting: writes nothing. `master_db` is an open `MasterGamesDb`,
    or None to skip TWIC.
    """
    aliases = [a for a in (aliases or []) if a and a.strip()]
    report: dict[str, Any] = {"name": name}
    if uscf_id:
        report["uscf_id"] = uscf_id
    confirmed: list[dict] = []
    candidates: list[dict] = []
    notes: list[str] = []

    # 1. What the user already has.
    row = None
    if people is not None:
        row = people.match(uscf_id=uscf_id, names=[name, *aliases])
        if row is not None:
            report["person_id"] = row["id"]
            for alias in row.get("aliases") or []:
                if alias not in aliases:
                    aliases.append(alias)
            for site in ("chesscom", "lichess"):
                for h in handles(row.get(site)):
                    confirmed.append(
                        {"site": site, "username": h, "source": "players_directory",
                         "evidence": "Already in your players directory."}
                    )
            for c in (row.get("lookup") or {}).get("candidates") or []:
                candidates.append(c)
            rating = rating or row.get("rating")
            title = title or row.get("title")
            uscf_id = uscf_id or row.get("uscf_id")

    # 2. The bundled USCF → chess.com directory.
    found = registry.directory.resolve(uscf_id=uscf_id, name=name)
    if found and found.get("chesscom_username"):
        entry = {
            "site": "chesscom",
            "username": found["chesscom_username"],
            "source": found.get("source", "directory"),
            "evidence": found.get("evidence", ""),
        }
        trusted = (
            found.get("confidence") == "exact"
            and found.get("source") in _TRUSTED_SOURCES
            and not found.get("dropped_name_parts")
        )
        if trusted:
            confirmed.append(entry)
        else:
            candidates.append({**entry, "confidence": found.get("confidence", "low")})
        if found.get("title") and not title:
            title = found["title"]

    # 3. US Chess: their own spelling, and whether online-rated at all.
    if uscf_id and use_uscf:
        try:
            member = uscf.member(uscf_id)
        except uscf.UscfError as e:
            notes.append(f"US Chess lookup failed: {e}")
        else:
            official = str(member.get("name") or "").strip()
            report["uscf"] = {
                "name": official,
                "online_rated": bool(member.get("online_ratings")),
                "otb": {k: v.get("rating") for k, v in (member.get("otb_ratings") or {}).items()},
                "online": {k: v.get("rating") for k, v in (member.get("online_ratings") or {}).items()},
            }
            if official and official.lower() != name.lower():
                display = official.title() if official.isupper() else official
                if display not in aliases:
                    aliases.append(display)
            if not rating:
                rating = (member.get("otb_ratings") or {}).get("R", {}).get("rating")

    spellings = [name, *aliases]
    report["aliases"] = aliases

    # 4. TWIC, under every spelling.
    if master_db is not None:
        identities = master_db.find_players(spellings)
        report["otb"] = _pick_otb(identities, rating)

    # 5. Username probes.
    if probe:
        skip = {(c["site"], c["username"].lower()) for c in confirmed + candidates}
        probed = probe_accounts(spellings, title=title, rating=rating, skip=skip)
        candidates += probed.pop("candidates")
        report["probe"] = probed

    known = {(c["site"], c["username"].lower()) for c in confirmed}
    deduped: list[dict] = []
    for c in candidates:
        key = (c["site"], str(c["username"]).lower())
        if key not in known:
            known.add(key)
            deduped.append(c)
    report["confirmed"] = confirmed
    report["candidates"] = deduped
    if rating:
        report["rating"] = rating
    if title:
        report["title"] = title

    otb = report.get("otb") or {}
    if confirmed:
        status = "account"
    elif deduped:
        status = "candidates"
    elif otb.get("fide_id") or otb.get("games"):
        status = "otb_only"
    else:
        status = "not_found"
    report["status"] = status
    report["next_steps"] = _next_steps(report, notes)
    return report


def _pick_otb(identities: list[dict], rating: int | None) -> dict[str, Any]:
    """The TWIC identity that is this person, when one clearly is."""
    if not identities:
        return {"games": 0}
    best_grade = identities[0]["match"]
    top = [i for i in identities if i["match"] == best_grade]
    others = [i for i in identities if i not in top][:4]

    def elo_agrees(i: dict) -> bool:
        return not rating or not i.get("latest_elo") or abs(i["latest_elo"] - rating) <= ELO_AGREEMENT

    agreeing = [i for i in top if elo_agrees(i)]
    if len(agreeing) == 1:
        pick = agreeing[0]
        basis = f"{pick['match']} name match"
        if rating and pick.get("latest_elo"):
            basis += f", FIDE {pick['latest_elo']} near rating {rating}"
        return {
            **pick,
            "basis": basis,
            **({"alternates": [i for i in identities if i is not pick][:4]} if len(identities) > 1 else {}),
        }
    return {"games": 0, "ambiguous": top[:6], **({"alternates": others} if others else {})}


def _next_steps(report: dict, notes: list[str]) -> list[str]:
    steps = list(notes)
    name = report["name"]
    status = report["status"]
    if status == "account":
        return steps
    if report.get("candidates"):
        steps.append(
            "Show the candidates to the user; people_confirm moves an approved "
            "one into the account the app downloads from."
        )
    uscf_info = report.get("uscf") or {}
    if uscf_info.get("online_rated"):
        steps.append(
            "USCF online-rated: they played USCF events on chess.com, so the "
            "account exists and the directory backfill "
            "(scripts/build_player_map.py) would find it."
        )
    spellings = [name, *report.get("aliases", [])]
    queries = [f'"{s}" chess.com' for s in spellings[:2]] + [f'"{name}" lichess']
    if report.get("title") or (report.get("otb") or {}).get("fide_id"):
        queries.append(f'"{name}" chess FIDE')
    steps.append(
        "Web search, then record finds with people_upsert candidates "
        "(quote the source): " + "; ".join(queries)
    )
    steps.append(
        "Know a rating they showed on a day? chesscom_search finds the "
        "account from rating clues."
    )
    if (report.get("otb") or {}).get("ambiguous"):
        steps.append(
            "Several TWIC players fit the name; add an alias or check the "
            "Elo to pick one (master_games {fide_id})."
        )
    return steps


def lookup_block(report: dict) -> dict:
    """The `lookup` a person row keeps: status, sources, open candidates."""
    otb = report.get("otb") or {}
    return {
        "status": report["status"],
        "checked_at": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
        "confirmed": report.get("confirmed", []),
        "candidates": report.get("candidates", []),
        **(
            {
                "otb": {
                    k: otb[k]
                    for k in ("fide_id", "names", "games", "last_date", "latest_elo", "basis")
                    if otb.get(k) is not None
                }
            }
            if otb.get("fide_id") or otb.get("names")
            else {}
        ),
        **({"uscf_online_rated": report["uscf"]["online_rated"]} if report.get("uscf") else {}),
        "next_steps": report.get("next_steps", []),
    }


def person_facts(report: dict) -> dict:
    """What a lookup lets us write into the person row itself."""
    otb = report.get("otb") or {}
    facts: dict[str, Any] = {
        "name": report["name"],
        "uscf_id": report.get("uscf_id"),
        "rating": report.get("rating"),
        "title": report.get("title"),
        "aliases": new_spellings(
            report["name"], [*report.get("aliases", []), *otb.get("names", [])]
        ),
        "lookup": lookup_block(report),
    }
    if otb.get("fide_id"):
        facts["fide_id"] = otb["fide_id"]
    for c in report.get("confirmed", []):
        facts.setdefault(c["site"], []).append(c["username"])
    return facts


def new_spellings(name: str, spellings: list[str]) -> list[str]:
    """Spellings worth keeping as aliases: not just [name] reordered or
    re-punctuated, and not a bare initial (`Shmeliov,D`)."""
    from .names import tokens

    out: list[str] = []
    for s in spellings:
        parts = tokens(s)
        if len(parts) < 2 or min(len(p) for p in parts) == 1:
            continue
        if sorted(parts) == sorted(tokens(name)):
            continue
        if any(sorted(tokens(o)) == sorted(parts) for o in out):
            continue
        out.append(s)
    return out


def merge_candidates(existing: list[dict], new: list[dict]) -> list[dict]:
    out = list(existing)
    seen = {(c.get("site"), str(c.get("username", "")).lower()) for c in out}
    for c in new:
        key = (c.get("site"), str(c.get("username", "")).lower())
        if key not in seen:
            out.append(c)
            seen.add(key)
    return out


# ── Tools ───────────────────────────────────────────────────────────────────


def _brief(row: dict) -> dict:
    lookup = row.get("lookup") or {}
    return {
        k: v
        for k, v in {
            "id": row.get("id"),
            "name": row.get("name"),
            "aliases": row.get("aliases"),
            "uscf_id": row.get("uscf_id"),
            "fide_id": row.get("fide_id"),
            "rating": row.get("rating"),
            "title": row.get("title"),
            "chesscom": row.get("chesscom"),
            "lichess": row.get("lichess"),
            "status": lookup.get("status"),
            "candidates": [
                f"{c.get('site')}:{c.get('username')} ({c.get('confidence', '?')})"
                for c in lookup.get("candidates") or []
            ]
            or None,
            "otb": lookup.get("otb"),
        }.items()
        if v not in (None, "", [])
    }


_APP_OPEN_NOTE = (
    "Written to the app's players directory. An app window that already has "
    "Players & prep loaded keeps its own copy: restart the app to see these "
    "rows, and before editing players there, or its next save replaces them."
)


def register_people_tools(registry: Any) -> None:
    from .master_games import MasterGamesDb
    from .roster import load_roster, save_roster
    from .tools import ToolError, _b, _i, _obj, _s, _text

    def _master(args: dict) -> Any:
        if args.get("twic") is False:
            return None
        try:
            return MasterGamesDb(args.get("db"))
        except ToolError:
            return None

    def _store() -> PeopleStore:
        try:
            return PeopleStore()
        except (ValueError, json.JSONDecodeError) as e:
            raise ToolError(f"Cannot read the players directory: {e}") from e

    def _strings(args: dict, key: str) -> list[str]:
        value = args.get(key) or []
        if isinstance(value, str):
            value = [v for v in value.split(",")]
        return [str(v).strip() for v in value if str(v).strip()]

    def player_lookup(args: dict) -> dict:
        name = _text(args, "name")
        if not name:
            raise ToolError("name is required.")
        db = _master(args)
        try:
            return lookup_person(
                registry,
                name=name,
                uscf_id=_text(args, "uscf_id") or None,
                aliases=_strings(args, "aliases"),
                rating=int(args["rating"]) if args.get("rating") else None,
                title=_text(args, "title") or None,
                probe=args.get("probe_handles", True) is not False,
                people=_store(),
                master_db=db,
            )
        finally:
            if db is not None:
                db.close()

    def people_list(args: dict) -> dict:
        store = _store()
        rows = store.search(_text(args, "query")) if _text(args, "query") else store.people
        limit = int(args.get("limit") or 50)
        return {
            "path": str(store.path),
            "count": len(rows),
            "people": [_brief(r) for r in rows[:limit]],
        }

    def people_get(args: dict) -> dict:
        store = _store()
        pid = _text(args, "person_id")
        row = store.get(pid) if pid else None
        if row is None and _text(args, "query"):
            hits = store.search(_text(args, "query"))
            if len(hits) > 1:
                return {"matches": [_brief(r) for r in hits[:20]]}
            row = hits[0] if hits else None
        if row is None:
            raise ToolError("No such person. people_list shows who is there.")
        return row

    def people_upsert(args: dict) -> dict:
        store = _store()
        facts: dict[str, Any] = {
            "id": _text(args, "person_id") or None,
            "name": _text(args, "name"),
            "uscf_id": _text(args, "uscf_id") or None,
            "fide_id": args.get("fide_id") or None,
            "rating": args.get("rating"),
            "title": _text(args, "title") or None,
            "notes": _text(args, "notes") or None,
            "aliases": _strings(args, "aliases"),
            "chesscom": _strings(args, "chesscom"),
            "lichess": _strings(args, "lichess"),
            "overwrite": bool(args.get("overwrite")),
        }
        if not facts["id"] and not facts["name"]:
            raise ToolError("Give person_id to edit someone, or name to add them.")
        try:
            row, status = store.upsert(facts)
        except KeyError as e:
            raise ToolError(f"No person with id {e}.") from e
        except ValueError as e:
            raise ToolError(str(e)) from e
        new = []
        for c in args.get("candidates") or []:
            site = str(c.get("site") or "").replace(".", "").lower()
            if site not in ("chesscom", "lichess") or not c.get("username"):
                raise ToolError('Each candidate needs site ("chesscom" or "lichess") and username.')
            if not str(c.get("evidence") or "").strip():
                raise ToolError("Each candidate needs evidence — quote what you saw.")
            new.append(
                {
                    "site": site,
                    "username": str(c["username"]).strip(),
                    "confidence": c.get("confidence") or "medium",
                    "evidence": str(c["evidence"]).strip(),
                    "source": c.get("source") or "agent",
                    **({"url": c["url"]} if c.get("url") else {}),
                }
            )
        if new:
            lookup = row.setdefault("lookup", {"status": "candidates"})
            lookup["candidates"] = merge_candidates(lookup.get("candidates") or [], new)
            if lookup.get("status") in (None, "not_found", "otb_only"):
                lookup["status"] = "candidates"
            status = "added" if status == "added" else "updated"
        group = None
        if _text(args, "group"):
            path, doc, _ = TournamentStore().upsert(
                _text(args, "group"),
                [{"person": row["id"], "rating": row.get("rating")}],
            )
            group = {"id": doc["id"], "path": str(path), "players": len(doc["entries"])}
        store.save()
        return {
            "status": status,
            "person": _brief(row),
            **({"group": group} if group else {}),
            "path": str(store.path),
            "note": _APP_OPEN_NOTE,
        }

    def people_confirm(args: dict) -> dict:
        store = _store()
        site = _text(args, "site").replace(".", "").lower()
        if site not in ("chesscom", "lichess"):
            raise ToolError('site must be "chesscom" or "lichess".')
        username = _text(args, "username")
        if not username:
            raise ToolError("username is required.")
        try:
            row = store.confirm(_text(args, "person_id"), site, username)
        except KeyError as e:
            raise ToolError(f"No person with id {e}.") from e
        lookup = row.get("lookup")
        if isinstance(lookup, dict):
            lookup["status"] = "account"
        store.save()
        return {"confirmed": f"{site}:{username}", "person": _brief(row), "note": _APP_OPEN_NOTE}

    def people_populate(args: dict) -> dict:
        roster = load_roster()
        if not roster.entries:
            raise ToolError("No roster loaded. Call roster_import first.")
        wanted = set(_strings(args, "player_ids"))
        entries = [
            e for e in roster.entries
            if not e.is_me and (not wanted or e.id in wanted)
        ]
        store = _store()
        db = _master(args)
        probe = args.get("probe_handles", True) is not False
        summary: dict[str, list[str]] = {
            "account": [], "candidates": [], "otb_only": [], "not_found": []
        }
        rows: list[dict] = []
        group_entries: list[dict] = []
        try:
            for entry in entries:
                identity = entry.identity or {}
                report = lookup_person(
                    registry,
                    name=entry.name,
                    uscf_id=entry.uscf_id,
                    aliases=list(entry.aliases),
                    rating=entry.rating,
                    title=entry.title or identity.get("title"),
                    probe=probe,
                    people=store,
                    master_db=db,
                    use_uscf=args.get("uscf", True) is not False,
                )
                # What the user confirmed on the roster counts as confirmed.
                if entry.is_actionable:
                    for site, key in (("chesscom", "chesscom_username"), ("lichess", "lichess_username")):
                        if identity.get(key) and not any(
                            c["site"] == site and c["username"].lower() == identity[key].lower()
                            for c in report["confirmed"]
                        ):
                            report["confirmed"].append(
                                {"site": site, "username": identity[key],
                                 "source": identity.get("source"),
                                 "evidence": identity.get("evidence", "")}
                            )
                    if report["confirmed"]:
                        report["status"] = "account"
                        report["next_steps"] = []
                elif identity.get("chesscom_username") or identity.get("lichess_username"):
                    for site, key in (("chesscom", "chesscom_username"), ("lichess", "lichess_username")):
                        if identity.get(key):
                            report["candidates"] = merge_candidates(
                                report["candidates"],
                                [{"site": site, "username": identity[key],
                                  "confidence": identity.get("confidence", "medium"),
                                  "evidence": identity.get("evidence", ""),
                                  "source": identity.get("source", "roster")}],
                            )
                    if report["status"] in ("otb_only", "not_found"):
                        report["status"] = "candidates"
                facts = person_facts(report)
                row, _ = store.upsert(facts)
                summary[report["status"]].append(entry.name)
                group_entries.append({"person": row["id"], "rating": entry.rating})
                rows.append(
                    {
                        "name": entry.name,
                        "person_id": row["id"],
                        "status": report["status"],
                        "accounts": [f"{c['site']}:{c['username']}" for c in report["confirmed"]],
                        "candidates": [
                            f"{c['site']}:{c['username']} ({c.get('confidence', '?')}) — {c.get('evidence', '')}"
                            for c in report["candidates"]
                        ],
                        "otb": {
                            k: (report.get("otb") or {}).get(k)
                            for k in ("fide_id", "names", "games", "last_date", "latest_elo", "basis")
                            if (report.get("otb") or {}).get(k) is not None
                        },
                        "aliases": row.get("aliases", []),
                        "next_steps": report["next_steps"],
                    }
                )
        finally:
            if db is not None:
                db.close()
        store.save()
        group_name = _text(args, "group") or roster.event_name
        group = None
        if group_name and args.get("make_group", True) is not False:
            path, doc, added = TournamentStore().upsert(
                group_name,
                group_entries,
                date=_text(args, "date") or None,
                rounds=roster.rounds,
            )
            group = {"id": doc["id"], "name": doc["name"], "path": str(path),
                     "players": len(doc["entries"]), "added": added}
        return {
            "people_file": str(store.path),
            **({"group": group} if group else {}),
            "summary": {k: v for k, v in summary.items()},
            "counts": {k: len(v) for k, v in summary.items()},
            "players": rows,
            "note": (
                "Only trusted matches (the directory's USCF-event match, or an "
                "account you confirmed) went into the chess.com/Lichess cells the "
                "app downloads from. Candidates wait in each row's lookup block — "
                "people_confirm promotes one after the user approves it. "
                + _APP_OPEN_NOTE
            ),
        }

    arr = lambda d: {"type": "array", "items": {"type": "string"}, "description": d}  # noqa: E731

    registry._add(
        "player_lookup",
        "Find one person online and over the board, deterministically and in a "
        "fixed order: your players directory (people.json) → the bundled USCF → "
        "chess.com directory → the US Chess API (their official spelling becomes "
        "an alias; says whether they ever played USCF-rated online) → the TWIC "
        "master-games database under every spelling, grouped by FIDE ID → a "
        "probe of usernames built from each spelling on chess.com and Lichess "
        "(~8 guesses; kept only when the profile's real name, title or rating "
        "agrees). Returns status (account / candidates / otb_only / not_found), "
        "confirmed accounts, scored candidates with evidence, the OTB identity, "
        "and next steps with ready web-search queries. Writes nothing. Takes a "
        "few seconds with probing on.",
        _obj(
            {
                "name": _s("Name as the entry list writes it"),
                "uscf_id": _s("USCF ID — the strongest key"),
                "aliases": arr("Other spellings: Denis Shmeliov for Denys Shmelov"),
                "rating": _i("Known rating; used to tell namesakes apart"),
                "title": _s("GM, IM, FM…; a matching chess.com/Lichess title counts as evidence"),
                "probe_handles": _b("Try username guesses on chess.com and Lichess (default true)"),
                "twic": _b("Search the master-games database (default true)"),
                "db": _s("Path to master_games.db (default: the app's)"),
            },
            ["name"],
        ),
        player_lookup,
    )
    registry._add(
        "people_populate",
        "Fill the app's players directory from the loaded roster in one call: "
        "runs player_lookup on every entrant (or player_ids), adds or updates one "
        "person each in Documents/opponents/people.json — aliases, USCF/FIDE ID, "
        "rating, title, trusted accounts, and a `lookup` block with candidates, "
        "the TWIC identity and next steps — and a group (tournament file) for "
        "the event with everyone in it. Existing people are matched by USCF ID, "
        "FIDE ID, handle or exact name/alias, and only have blanks filled; "
        "nothing the user typed is replaced. Only trusted matches become "
        "downloadable accounts; the rest are candidates for people_confirm. "
        "Returns found / candidates / OTB-only / not found per player. About "
        "5 s per entrant with probing (one US Chess call plus ~9 profile checks).",
        _obj(
            {
                "group": _s("Group name (default: the roster's event name; none if both empty)"),
                "date": _s("Event date YYYY-MM-DD, stored on a new group"),
                "player_ids": arr("Only these roster ids (default: everyone but you)"),
                "probe_handles": _b("Try username guesses (default true)"),
                "uscf": _b("Ask the US Chess API per entrant (default true)"),
                "make_group": _b("Write the group file (default true)"),
                "twic": _b("Search the master-games database (default true)"),
                "db": _s("Path to master_games.db (default: the app's)"),
            }
        ),
        people_populate,
    )
    registry._add(
        "people_list",
        "The app's players directory (Documents/opponents/people.json): one "
        "line per person with aliases, IDs, accounts, lookup status and open "
        "candidates. query matches every word against name, aliases, IDs and "
        "handles, accents ignored.",
        _obj({"query": _s("Words to match"), "limit": _i("Max rows (default 50)")}),
        people_list,
    )
    registry._add(
        "people_get",
        "One person's full row from the players directory, including the "
        "lookup block (evidence for every candidate, OTB identity, next steps).",
        _obj({"person_id": _s("Row id"), "query": _s("Or a name/alias/handle")}),
        people_get,
    )
    registry._add(
        "people_upsert",
        "Add a person to the app's players directory, or merge facts into one "
        "(matched by person_id, else USCF ID, FIDE ID, handle, or exact name/"
        "alias). Blanks are filled and lists unioned; a differing name becomes "
        "an alias unless overwrite. Put accounts you found by searching in "
        "`candidates` with quoted evidence — `chesscom`/`lichess` are the "
        "cells the app downloads games from and are for trusted or "
        "user-approved accounts only. `group` also adds them to that group.",
        _obj(
            {
                "person_id": _s("Edit this row"),
                "name": _s("Name (required for a new person)"),
                "aliases": arr("Other spellings of the name"),
                "uscf_id": _s("USCF ID"),
                "fide_id": _i("FIDE ID"),
                "rating": _i("Rating"),
                "title": _s("Title"),
                "notes": _s("Notes; only fills an empty note"),
                "chesscom": arr("Confirmed chess.com accounts (several allowed)"),
                "lichess": arr("Confirmed Lichess accounts (several allowed)"),
                "candidates": {
                    "type": "array",
                    "description": "Unconfirmed accounts: {site: chesscom|lichess, username, evidence, confidence: high|medium|low, url?}",
                    "items": {"type": "object"},
                },
                "group": _s("Also add them to this group (created if new)"),
                "overwrite": _b("Replace name/rating/title instead of filling blanks"),
            }
        ),
        people_upsert,
    )
    registry._add(
        "people_confirm",
        "Promote one candidate account to the account the app downloads games "
        "from. Only when the user has approved that match — a wrong account "
        "means preparing against a stranger. Several accounts per person are "
        "fine; each confirm adds one.",
        _obj(
            {
                "person_id": _s("Row id"),
                "site": _s("chesscom or lichess"),
                "username": _s("The account"),
            },
            ["person_id", "site", "username"],
        ),
        people_confirm,
    )
