"""Name spellings: one person, many ways of writing them down.

A US Chess entry list says `Denys Shmelov`, TWIC says `Shmeliov,D`, ChessBase
says `Denis Shmeliov`, and a Chinese name arrives as `Jianchao Zhou` or
`Zhou Jianchao`. Everything here is pure and deterministic, so a lookup that
fails today fails the same way tomorrow and the reason can be read off.
"""

from __future__ import annotations

import re
import unicodedata

_TITLE_PAREN = re.compile(r"\((?:GM|IM|FM|CM|NM|WGM|WIM|WFM|WCM|LM)\)", re.IGNORECASE)
_NON_LETTER = re.compile(r"[^a-z\s-]")
_SPACES = re.compile(r"\s+")


def fold(text: str) -> str:
    """Lower case, accents dropped, punctuation gone: `Šmeļov` → `smelov`."""
    decomposed = unicodedata.normalize("NFKD", text)
    ascii_only = "".join(c for c in decomposed if not unicodedata.combining(c))
    return ascii_only.lower()


def tokens(name: str) -> list[str]:
    """Name parts in the written order, titles and punctuation removed.

    `Last, First` is turned round to `First Last` so every form reads the
    same way; hyphenated parts stay one token.
    """
    text = _TITLE_PAREN.sub(" ", name or "")
    if "," in text:
        last, first = text.split(",", 1)
        text = f"{first} {last}"
    cleaned = _SPACES.sub(" ", _NON_LETTER.sub(" ", fold(text))).strip()
    return [t for t in cleaned.split(" ") if t.strip("-")]


def _orderings(name: str) -> list[tuple[str, list[str]]]:
    """`(surname, given names)` readings of a name.

    A comma fixes the surname (`Shmeliov,D`). Without one the surname is
    the last part, and a two-part name may also be surname-first
    (`Zhou Jianchao`); that reading is marked by listing it second.
    """
    parts = tokens(name)
    if not parts:
        return []
    if len(parts) == 1:
        return [(parts[0], [])]
    readings = [(parts[-1], parts[:-1])]
    if len(parts) == 2 and "," not in (name or ""):
        readings.append((parts[0], parts[1:]))
    return readings


def surname_candidates(name: str) -> list[str]:
    """Which token might be the surname: the last one, and for a two-part
    name without a comma also the first (`Zhou Jianchao`)."""
    return [surname for surname, _ in _orderings(name)]


def levenshtein(a: str, b: str, cap: int = 3) -> int:
    """Edit distance, stopping early once it exceeds [cap]."""
    if a == b:
        return 0
    if abs(len(a) - len(b)) > cap:
        return cap + 1
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(
                min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb))
            )
        if min(current) > cap:
            return cap + 1
        previous = current
    return previous[-1]


def surname_distance_cap(surname: str) -> int:
    """How far a spelling may drift and still be the same surname: none for
    short names (Zhou/Zhu are different people), one edit from five letters,
    two from eight (Shmelov/Shmeliov/Chmeliov)."""
    if len(surname) < 5:
        return 0
    return 1 if len(surname) < 8 else 2


def _close(a: str, b: str) -> bool:
    cap = surname_distance_cap(max(a, b, key=len))
    return levenshtein(a, b, cap) <= cap


#: How closely two spellings agree, best first.
MATCH_GRADES = ("exact", "spelling", "initial")


def name_match(a: str, b: str) -> str | None:
    """How plausibly two spellings name one person, or None.

    `exact`: same surname and first given name once accents, case, order
    and punctuation are gone. `spelling`: within the surname edit cap and a
    close given name (`Denys Shmelov` / `Denis Shmeliov`). `initial`: one
    side gives only an initial, or no given name at all (`Shmeliov,D`) —
    possibly somebody else.

    A surname-first reading (`Zhou Jianchao`) needs a close given name, so
    `William Schiminger` never reads as `Williams, S…`.
    """
    best: str | None = None
    for ia, (sa, ga) in enumerate(_orderings(a)):
        for ib, (sb, gb) in enumerate(_orderings(b)):
            if not _close(sa, sb):
                continue
            reversed_reading = bool(ia or ib)
            if not ga or not gb:
                grade = None if reversed_reading else "initial"
            elif sa == sb and ga[0] == gb[0]:
                grade = "exact"
            elif _close(ga[0], gb[0]) and min(len(ga[0]), len(gb[0])) > 1:
                grade = "spelling"
            elif (
                not reversed_reading
                and min(len(ga[0]), len(gb[0])) == 1
                and ga[0][0] == gb[0][0]
            ):
                # Only when one side *is* an initial: Shmeliov,D fits Denys,
                # but Winter,Sven is not Shea.
                grade = "initial"
            else:
                grade = None
            if grade and (best is None or MATCH_GRADES.index(grade) < MATCH_GRADES.index(best)):
                best = grade
    return best


def same_person_name(a: str, b: str) -> bool:
    """Whether two spellings plausibly name one person (any grade)."""
    return name_match(a, b) is not None


def handle_guesses(name: str) -> list[str]:
    """Usernames people commonly build from their name, most common first.

    Only a probe list: an account existing under one of these proves nothing
    by itself (the probe of `jianchaozhou` finds a closed account in China).
    """
    parts = [p.replace("-", "") for p in tokens(name)]
    if len(parts) < 2:
        return parts[:1]
    first, last = parts[0], parts[-1]
    guesses = [
        f"{first}{last}",
        f"{last}{first}",
        f"{first}_{last}",
        f"{first[0]}{last}",
        f"{first}-{last}",
        f"{last}_{first}",
    ]
    seen: set[str] = set()
    return [g for g in guesses if not (g in seen or seen.add(g))]


def twic_forms(name: str) -> list[str]:
    """How TWIC might have written this name, for a prefix search:
    `Surname,Given`, `Surname,G` and `Surname Given` (Chinese names)."""
    out: list[str] = []
    parts = tokens(name)
    if not parts:
        return out
    for surname in surname_candidates(name):
        given = [t for t in parts if t != surname]
        cap = surname.capitalize()
        if given:
            g = given[0].capitalize()
            out += [f"{cap},{g}", f"{cap}, {g}", f"{cap} {g}", f"{cap},{g[0]}"]
        else:
            out.append(cap)
    seen: set[str] = set()
    return [f for f in out if not (f.lower() in seen or seen.add(f.lower()))]
