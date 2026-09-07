#!/usr/bin/env python3
"""Tests for player lookup: `chess_prep.directory`, `chess_prep.uscf` and
`chess_prep.app_games`.

Three ways to answer "who is this player?" — the bundled USCF → chess.com
directory, the US Chess ratings API, and the user's own games database — and
one shared failure mode: confidently returning somebody else. Name
normalisation deliberately throws information away (middle names, suffixes,
punctuation) so that "Smith, John" and "John Smith" meet, which means the
tests that matter most are the ones proving two *different* people stay
apart, and that a match made on a name alone can never be acted on without a
human confirming it.

Zero dependencies (unittest only). The US Chess client is exercised through
stubs at two levels — its own `_get`, and `urllib.request.urlopen` — so the
whole file runs offline; nothing here opens a socket.

Run:
    python tools/mcp/test_directory.py
"""

from __future__ import annotations

import io
import os
import sqlite3
import sys
import tempfile
import time
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep import uscf  # noqa: E402
from chess_prep.app_games import AppGamesDb, app_games_db_path  # noqa: E402
from chess_prep.directory import (  # noqa: E402
    DirectoryEntry,
    PlayerDirectory,
    dropped_name_parts,
    parse_player_name,
    player_name_key,
)
from chess_prep.master_games import fen4_of, position_key  # noqa: E402
from chess_prep.opponents import opponents_document  # noqa: E402
from chess_prep.roster import Roster, RosterEntry  # noqa: E402
from chess_prep.tools import Registry, ToolError  # noqa: E402


def entry(uscf_id: str, name: str, username: str, **kw) -> DirectoryEntry:
    kw.setdefault("confidence", "exact")
    kw.setdefault("method", "opponent_graph")
    return DirectoryEntry(uscf_id, name, username, **kw)


# ── Name normalisation: what must meet ──────────────────────────────────────


class NameFormsThatMustMatch(unittest.TestCase):
    def assert_same(self, *forms: str) -> None:
        keys = {form: player_name_key(form) for form in forms}
        self.assertEqual(
            len(set(keys.values())), 1, f"these should be one player: {keys}"
        )

    def test_both_orderings(self):
        self.assert_same("Bernal, Andrew", "Andrew Bernal")

    def test_case_and_whitespace(self):
        self.assert_same(
            "Andrew Bernal",
            "ANDREW BERNAL",
            "andrew  bernal",
            "  Andrew   Bernal  ",
            "Bernal ,  Andrew",
        )

    def test_middle_names_are_dropped(self):
        # A roster prints middle names; chess.com profiles usually do not.
        self.assert_same(
            "Kona, Vidip Kumar", "VIDIP KUMAR KONA", "Vidip Kona", "Kona, Vidip K."
        )

    def test_generational_suffixes_are_dropped(self):
        self.assert_same(
            "Smith, John", "John Smith Jr.", "John Smith Jr", "Smith Jr, John",
            "John Smith III",
        )

    def test_punctuation_inside_a_name(self):
        self.assert_same("O'Brien, Sean", "OBrien, Sean", "Sean O'Brien")

    def test_a_hyphenated_surname_is_one_unit(self):
        self.assert_same("Smith-Jones, Alice", "Alice Smith-Jones")
        self.assertEqual(parse_player_name("Alice Smith-Jones")[1], "SMITHJONES")

    def test_a_hyphenated_given_name_splits(self):
        # `Anne-Marie` is `Anne` plus a middle name, and middle names go.
        self.assert_same("Anne-Marie Dubois", "Dubois, Anne Marie", "Dubois, Anne")

    def test_the_key_shape_is_fixed(self):
        # These exact strings are asserted on the Dart side too
        # (test/features/tournament/roster_import_test.dart); the two
        # implementations resolve one roster and must not drift apart.
        self.assertEqual(player_name_key("Van Der Berg, Jan"), "JAN|VANDERBERG")
        self.assertEqual(player_name_key("Magnus"), "|MAGNUS")
        self.assertEqual(player_name_key(""), "|")


# ── Name normalisation: what must NOT meet ──────────────────────────────────


class NameFormsThatMustNotMatch(unittest.TestCase):
    """False positives here merge two people's games. This is the direction
    that must never regress."""

    def assert_different(self, a: str, b: str) -> None:
        self.assertNotEqual(
            player_name_key(a),
            player_name_key(b),
            f"{a!r} and {b!r} are different people",
        )

    def test_different_given_names(self):
        self.assert_different("John Smith", "Jane Smith")
        self.assert_different("Smith, John", "Smith, Johnny")
        self.assert_different("Li, Wei", "Li, Wen")

    def test_different_surnames(self):
        self.assert_different("John Smith", "John Smythe")
        self.assert_different("Andrew Bernal", "Andrew Bernal-Lopez")

    def test_a_reversed_pair_is_not_the_same_person(self):
        # "Smith, John" is John Smith; "John, Smith" is Smith John.
        self.assert_different("Smith, John", "John, Smith")

    def test_a_surname_alone_is_not_a_full_name(self):
        self.assert_different("Smith", "John Smith")
        self.assert_different("Magnus", "Magnus Carlsen")

    def test_transposed_letters(self):
        self.assert_different("Kona, Vidip", "Kona, Vidpi")

    def test_the_join_character_cannot_be_smuggled_in(self):
        # A key is "FIRST|LAST"; a name containing the separator must not be
        # able to forge somebody else's key.
        self.assert_different("John|Smith", "Smith, John")


class NameNormalisationLimits(unittest.TestCase):
    """Known misses. Each is safe (a miss, never a silent merge), and each is
    pinned so a change to the folding rules is a deliberate decision."""

    def test_accents_are_not_folded(self):
        # "Muñoz" and "Munoz" are the same person on two websites, and the
        # directory will not find them for each other. A miss, not a merge.
        self.assertNotEqual(player_name_key("Muñoz, José"), player_name_key("Jose Munoz"))
        # But accented names still normalise consistently with themselves.
        self.assertEqual(player_name_key("Muñoz, José"), player_name_key("José Muñoz"))

    def test_a_particle_surname_only_survives_the_comma_form(self):
        # "Van Der Berg, Jan" keeps the particles; "Jan Van Der Berg" cannot
        # tell a particle from a middle name and keeps only the last token.
        self.assertEqual(player_name_key("Van Der Berg, Jan"), "JAN|VANDERBERG")
        self.assertEqual(player_name_key("Jan Van Der Berg"), "JAN|BERG")

    def test_a_blank_key_is_never_a_lookup_key(self):
        # "." is a non-empty name that normalises to nothing, so this row does
        # sit in the name index under the empty key "|". Nothing may reach it:
        # otherwise every unparseable name on a roster resolves to whichever
        # unparseable row the directory happens to hold.
        directory = PlayerDirectory(
            [entry("1234567", ".", "ghost"), entry("7654321", "", "unnamed")], {}
        )
        for junk in ("", "   ", ".", ",", "-", "'", ".,-"):
            self.assertEqual(directory.by_name(junk), [], junk)
            self.assertIsNone(directory.resolve(name=junk), junk)
        # A row with no name at all is not even indexed.
        self.assertEqual(directory.by_name("unnamed"), [])


# ── The index ───────────────────────────────────────────────────────────────


def small_directory() -> PlayerDirectory:
    return PlayerDirectory(
        [
            entry("16009740", "Andrew Bernal", "andrewb"),
            entry("11111111", "John Smith", "alpha"),
            entry("22222222", "Smith, John", "beta", method="signature"),
            entry("33333333", "Jane Doe", "gamma", confidence="medium",
                  method="score_position", title="IM"),
            entry("44444444", "Maria Cruz", "delta", event_id="E1",
                  event_date="2025-03", title="WFM"),
        ],
        {"gamma": "IM", "delta": "WFM"},
        events_processed=1600,
    )


class Index(unittest.TestCase):
    def setUp(self):
        self.directory = small_directory()

    def test_counts(self):
        self.assertEqual(self.directory.player_count, 5)
        self.assertEqual(self.directory.titled_count, 2)
        self.assertEqual(self.directory.events_processed, 1600)

    def test_lookup_by_id_trims(self):
        self.assertEqual(self.directory.by_uscf_id("  11111111 ").chesscom_username, "alpha")
        self.assertIsNone(self.directory.by_uscf_id("00000000"))

    def test_an_id_is_matched_whole_not_by_prefix(self):
        self.assertIsNone(self.directory.by_uscf_id("1111111"))
        self.assertIsNone(self.directory.by_uscf_id("111111110"))

    def test_reverse_lookup_ignores_case_and_padding(self):
        self.assertEqual(self.directory.by_chesscom_username(" ALPHA ").uscf_id, "11111111")
        self.assertIsNone(self.directory.by_chesscom_username("nobody"))

    def test_titles(self):
        self.assertEqual(self.directory.title_for(" GAMMA "), "IM")
        self.assertIsNone(self.directory.title_for("alpha"))



    def test_an_unnamed_row_is_still_reachable_by_id(self):
        directory = PlayerDirectory([entry("1234567", "", "ghost")], {})
        self.assertEqual(directory.by_uscf_id("1234567").chesscom_username, "ghost")

    def test_evidence_names_the_route(self):
        evidence = self.directory.by_uscf_id("44444444").evidence
        self.assertIn("USCF 44444444", evidence)
        self.assertIn("Maria Cruz", evidence)
        self.assertIn("delta", evidence)
        self.assertIn("opponent_graph", evidence)
        self.assertIn("E1", evidence)
        self.assertIn("2025-03", evidence)

    def test_to_dict_omits_what_is_absent(self):
        self.assertEqual(
            self.directory.by_uscf_id("11111111").to_dict(),
            {
                "uscf_id": "11111111",
                "uscf_name": "John Smith",
                "chesscom_username": "alpha",
                "confidence": "exact",
                "method": "opponent_graph",
            },
        )


# ── Resolution ──────────────────────────────────────────────────────────────


class Resolve(unittest.TestCase):
    def setUp(self):
        self.directory = small_directory()

    def test_an_id_hit_keeps_the_row_confidence(self):
        identity = self.directory.resolve(uscf_id="16009740")
        self.assertEqual(identity["chesscom_username"], "andrewb")
        self.assertEqual(identity["confidence"], "exact")
        self.assertEqual(identity["source"], "uscf_online_event")

    def test_an_id_hit_does_not_invent_confidence(self):
        # Jane Doe's row is only "medium"; resolving her by ID must not
        # upgrade that to "exact".
        self.assertEqual(self.directory.resolve(uscf_id="33333333")["confidence"], "medium")

    def test_an_id_hit_beats_a_conflicting_name(self):
        identity = self.directory.resolve(uscf_id="16009740", name="John Smith")
        self.assertEqual(identity["chesscom_username"], "andrewb")
        self.assertEqual(identity["confidence"], "exact")

    def test_an_id_miss_falls_through_to_the_name(self):
        identity = self.directory.resolve(uscf_id="99999999", name="Jane Doe")
        self.assertEqual(identity["chesscom_username"], "gamma")
        self.assertEqual(identity["confidence"], "medium")

    def test_a_unique_name_is_downgraded_and_says_why(self):
        identity = self.directory.resolve(name="Maria Cruz")
        self.assertEqual(identity["chesscom_username"], "delta")
        self.assertEqual(
            identity["confidence"],
            "medium",
            "the row is certain; that it is *this* entrant is not",
        )
        self.assertIn("matched on name, not USCF ID", identity["evidence"])

    def test_the_title_rides_along(self):
        self.assertEqual(self.directory.resolve(uscf_id="44444444")["title"], "WFM")
        self.assertEqual(self.directory.resolve(name="Jane Doe")["title"], "IM")
        self.assertNotIn("title", self.directory.resolve(uscf_id="11111111"))

    def test_two_rows_sharing_a_name_refuse_to_pick(self):
        identity = self.directory.resolve(name="John Smith")
        self.assertEqual(identity["confidence"], "ambiguous")
        self.assertNotIn(
            "chesscom_username",
            identity,
            "an ambiguous result must not hand back an account to act on",
        )
        self.assertEqual(len(identity["alternates"]), 2)
        self.assertEqual(
            sorted(identity["alternates"]),
            ["alpha (USCF 11111111)", "beta (USCF 22222222)"],
        )
        self.assertIn("2 directory rows", identity["evidence"])

    def test_the_ambiguity_boundary_is_exactly_one(self):
        one = PlayerDirectory([entry("1111111", "John Smith", "alpha")], {})
        self.assertEqual(one.resolve(name="John Smith")["confidence"], "medium")

        two = PlayerDirectory(
            [entry("1111111", "John Smith", "alpha"), entry("2222222", "Smith, John", "beta")],
            {},
        )
        self.assertEqual(two.resolve(name="John Smith")["confidence"], "ambiguous")

    def test_nothing_to_go_on(self):
        self.assertIsNone(self.directory.resolve())
        self.assertIsNone(self.directory.resolve(uscf_id="  ", name="  "))
        self.assertIsNone(self.directory.resolve(uscf_id="00000000"))
        self.assertIsNone(self.directory.resolve(name="Nobody Here"))

    def test_a_partial_name_match_says_what_it_dropped(self):
        # Name folding keeps one given name and a surname, so outside the
        # "Last, First" form it cannot tell a particle from a middle name:
        # "Maria de la Cruz" lands on the row for a genuinely different
        # "Maria Cruz". The folding rule is a separate design question and is
        # left alone — what is fixed here is that the hit stops looking
        # confident. It must name the parts it threw away.
        identity = self.directory.resolve(name="Maria de la Cruz")
        self.assertEqual(identity["dropped_name_parts"], ["DE", "LA"])
        self.assertIn("only part of the name matched", identity["evidence"])
        self.assertIn("Maria Cruz", identity["evidence"])

    def test_a_whole_name_match_is_not_labelled(self):
        # The label has to mean something, so a full match must not carry it.
        identity = self.directory.resolve(name="Cruz, Maria")
        self.assertEqual(identity["chesscom_username"], "delta")
        self.assertNotIn("dropped_name_parts", identity)
        self.assertNotIn("only part of the name", identity["evidence"])

    def test_a_dropped_middle_name_is_labelled_too(self):
        identity = self.directory.resolve(name="Jane Q Doe")
        self.assertEqual(identity["dropped_name_parts"], ["Q"])

    def test_a_name_only_match_can_never_be_acted_on(self):
        # The safety net under every name-shaped false positive: the hit
        # resolves to a real account, so what must hold is that it stays
        # below the actionable bar and never reaches the opponent list on
        # its own.
        identity = self.directory.resolve(name="Maria de la Cruz")
        self.assertEqual(identity["chesscom_username"], "delta")

        person = RosterEntry(id="p", name="Maria de la Cruz", identity=identity)
        self.assertTrue(person.has_account)
        self.assertFalse(person.is_actionable)

        doc, skipped = opponents_document(Roster(entries=[person]))
        self.assertEqual(doc["opponents"], [])
        self.assertIn("not confirmed", skipped[0]["reason"])

    def test_an_ambiguous_match_can_never_be_acted_on_either(self):
        person = RosterEntry(
            id="p", name="John Smith", identity=self.directory.resolve(name="John Smith")
        )
        self.assertFalse(person.has_account)
        self.assertFalse(person.is_actionable)


class NameMatchLabelling(unittest.TestCase):
    """What the key threw away, reported so a partial hit cannot be read as a
    full one."""

    def setUp(self):
        self.directory = small_directory()

    def test_dropped_parts_are_listed_in_query_order(self):
        self.assertEqual(dropped_name_parts("Maria de la Cruz", "Maria Cruz"), ["DE", "LA"])
        self.assertEqual(dropped_name_parts("Jan Van Der Berg", "Jan Berg"), ["VAN", "DER"])
        self.assertEqual(dropped_name_parts("Kona, Vidip Kumar", "Vidip Kona"), ["KUMAR"])

    def test_nothing_is_dropped_from_a_whole_match(self):
        for query, row in (
            ("Andrew Bernal", "Bernal, Andrew"),
            ("Bernal, Andrew", "Andrew Bernal"),
            ("Van Der Berg, Jan", "Jan Van Der Berg"),
            ("john smith", "Smith, John"),
            ("Smith Jr, John", "John Smith"),
        ):
            self.assertEqual(dropped_name_parts(query, row), [], f"{query} / {row}")

    def test_a_shorter_query_drops_nothing(self):
        # Fewer parts than the row is the ordinary case and is not a warning.
        self.assertEqual(dropped_name_parts("Maria Cruz", "Maria de la Cruz"), [])

    def test_a_repeated_token_is_reported_once(self):
        self.assertEqual(dropped_name_parts("Ba Ba Cruz", "Cruz"), ["BA"])

    def test_name_matches_labels_the_row_the_search_would_hand_back(self):
        # `by_name` returns the row and nothing else, so a caller sees
        # "unique: true" over a row named for somebody else. `name_matches`
        # is the same list with that fact attached.
        (row,) = self.directory.name_matches("Maria de la Cruz")
        self.assertEqual(row["uscf_name"], "Maria Cruz")
        self.assertEqual(row["dropped_name_parts"], ["DE", "LA"])
        self.assertIn("different person", row["name_match_note"])
        self.assertIn("confirm before acting", row["name_match_note"])

    def test_name_matches_leaves_a_whole_match_unadorned(self):
        (row,) = self.directory.name_matches("Cruz, Maria")
        self.assertEqual(row, self.directory.by_uscf_id("44444444").to_dict())

    def test_name_matches_keeps_every_candidate_for_an_ambiguous_name(self):
        rows = self.directory.name_matches("John Smith")
        self.assertEqual([r["uscf_id"] for r in rows], ["11111111", "22222222"])

    def test_name_matches_is_empty_on_a_miss(self):
        self.assertEqual(self.directory.name_matches("Nobody Here"), [])
        self.assertEqual(self.directory.name_matches(""), [])


# ── Free-text search ────────────────────────────────────────────────────────


class Search(unittest.TestCase):
    def setUp(self):
        self.directory = small_directory()

    def ids(self, query: str, **kw) -> list[str]:
        return [e.uscf_id for e in self.directory.search(query, **kw)]

    def test_an_id_query(self):
        self.assertEqual(self.ids("16009740"), ["16009740"])

    def test_a_username_query_ignores_case(self):
        self.assertEqual(self.ids("ANDREWB"), ["16009740"])

    def test_a_name_query_returns_every_candidate(self):
        self.assertEqual(self.ids("John Smith"), ["11111111", "22222222"])

    def test_a_substring_query_falls_back_to_scanning(self):
        self.assertEqual(self.ids("bernal"), ["16009740"])

    def test_no_row_is_returned_twice(self):
        # "andrewb" hits the username index; "andrew" also matches the name
        # substring scan. One row, once.
        for query in ("andrewb", "andrew", "16009740"):
            found = self.ids(query)
            self.assertEqual(len(found), len(set(found)), query)

    def test_empty_query(self):
        self.assertEqual(self.directory.search(""), [])
        self.assertEqual(self.directory.search("   "), [])

    def test_a_miss_is_empty_not_everything(self):
        self.assertEqual(self.ids("zzzzzz"), [])

    def test_the_limit_is_respected(self):
        self.assertLessEqual(len(self.ids("1", limit=1)), 1)
        self.assertEqual(len(self.ids("a", limit=2)), 2)
        self.assertEqual(self.ids("John Smith", limit=1), ["11111111"])

    def test_results_are_deterministic(self):
        for query in ("a", "1", "John Smith", "smith"):
            self.assertEqual(self.ids(query), self.ids(query), query)

    def test_exact_hits_come_before_substring_hits(self):
        directory = PlayerDirectory(
            [
                entry("1111111", "Substring Match", "xx_alpha_xx"),
                entry("2222222", "Exact Match", "alpha"),
            ],
            {},
        )
        self.assertEqual(
            [e.uscf_id for e in directory.search("alpha")], ["2222222", "1111111"]
        )


# ── Through the tool registry ───────────────────────────────────────────────


class IdentityToolsCarryTheLabel(unittest.TestCase):
    """The module-level tests above prove the label is computed; these prove
    it survives into what an agent actually reads. A partial hit that reaches
    `directory_search` as an unadorned row over `unique: true` is exactly the
    confident-looking answer the label exists to prevent."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        os.environ["CHESS_PREP_ROSTER"] = str(Path(self._dir.name) / "roster.json")
        self.addCleanup(lambda: os.environ.pop("CHESS_PREP_ROSTER", None))
        self.registry = Registry()
        self.registry._directory = small_directory()

    def call(self, tool: str, **args):
        return self.registry.call(tool, args)

    def test_directory_search_by_name_labels_a_partial_hit(self):
        result = self.call("directory_search", name="Maria de la Cruz")
        self.assertTrue(result["unique"], "still a single row — that is the danger")
        (row,) = result["entries"]
        self.assertEqual(row["uscf_name"], "Maria Cruz")
        self.assertEqual(row["dropped_name_parts"], ["DE", "LA"])
        self.assertIn("different person", row["name_match_note"])

    def test_directory_search_leaves_a_whole_hit_unadorned(self):
        (row,) = self.call("directory_search", name="Cruz, Maria")["entries"]
        self.assertNotIn("dropped_name_parts", row)
        self.assertNotIn("name_match_note", row)

    def test_directory_search_still_returns_the_row_itself(self):
        # Labelling must not cost the caller the fields it came for.
        (row,) = self.call("directory_search", name="Maria de la Cruz")["entries"]
        for key in ("uscf_id", "uscf_name", "chesscom_username", "confidence", "method"):
            self.assertIn(key, row)

    def test_directory_search_labels_every_candidate_of_an_ambiguous_name(self):
        result = self.call("directory_search", name="John Q Smith")
        self.assertFalse(result["unique"])
        self.assertEqual(len(result["entries"]), 2)
        for row in result["entries"]:
            self.assertEqual(row["dropped_name_parts"], ["Q"])

    def test_the_other_search_keys_are_untouched(self):
        by_id = self.call("directory_search", uscf_id="44444444")
        self.assertTrue(by_id["found"])
        self.assertNotIn("dropped_name_parts", by_id["entry"])
        by_user = self.call("directory_search", chesscom_username="delta")
        self.assertEqual(by_user["entry"]["uscf_id"], "44444444")
        free_text = self.call("directory_search", query="cruz")
        self.assertEqual(free_text["count"], 1)

    def test_roster_resolve_reports_which_entrants_matched_only_partly(self):
        self.call(
            "roster_import",
            text=(
                'Name,USCF ID,Rating\n'
                '"Cruz, Maria de la",,1700\n'
                '"Bernal, Andrew",16009740,1900\n'
            ),
        )
        summary = self.call("roster_resolve")
        (partial,) = summary["partial_name_matches"]
        self.assertEqual(partial["name"], "Cruz, Maria de la")
        self.assertEqual(partial["dropped_name_parts"], ["DE", "LA"])
        self.assertEqual(partial["chesscom_username"], "delta")
        self.assertIn("Maria Cruz", partial["evidence"])
        self.assertIn("someone else", summary["partial_name_match_note"])
        # Andrew matched on his USCF ID, so he is not in the list.
        self.assertNotIn(
            "Bernal, Andrew", [p["name"] for p in summary["partial_name_matches"]]
        )

    def test_roster_resolve_says_nothing_when_every_match_is_whole(self):
        self.call("roster_import", text='Name,USCF ID,Rating\n"Bernal, Andrew",16009740,1900\n')
        summary = self.call("roster_resolve")
        self.assertNotIn("partial_name_matches", summary)
        self.assertNotIn("partial_name_match_note", summary)

    def test_a_partially_matched_entrant_is_still_not_actionable(self):
        # The label is a warning, not a downgrade: the actionability gate is
        # what actually keeps the wrong account out of the opponent list.
        self.call("roster_import", text='Name,Rating\n"Cruz, Maria de la",1700\n')
        self.call("roster_resolve")
        skipped = self.call("opponents_export")["skipped"]
        self.assertEqual([s["name"] for s in skipped], ["Cruz, Maria de la"])
        self.assertIn("not confirmed", skipped[0]["reason"])


# ── US Chess member lookup (network stubbed) ────────────────────────────────


PROFILE = {
    "firstName": "Andrew",
    "lastName": "Bernal",
    "state": "MA",
    "ratings": [
        {"ratingSystem": "R", "rating": 1977, "gamesPlayed": 300, "isProvisional": False},
        {"ratingSystem": "OQ", "rating": 1800, "gamesPlayed": 20},
        {"ratingSystem": "OB", "rating": 1750, "gamesPlayed": 4, "isProvisional": True},
        {"ratingSystem": "B", "rating": None, "gamesPlayed": 0},
        {"ratingSystem": "Q", "rating": None, "gamesPlayed": 7},
    ],
}


class StubbedGet:
    """Replaces `uscf._get` and records the paths it was asked for."""

    def __init__(self, responses):
        self.responses = responses
        self.paths: list[str] = []

    def __call__(self, path: str, timeout: int = 20):
        self.paths.append(path)
        value = self.responses(path) if callable(self.responses) else self.responses
        if isinstance(value, Exception):
            raise value
        return value


class MemberLookup(unittest.TestCase):
    def setUp(self):
        self.stub = StubbedGet(PROFILE)
        patcher = mock.patch.object(uscf, "_get", self.stub)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_asks_for_the_right_member(self):
        uscf.member("  16009740  ")
        self.assertEqual(self.stub.paths, ["/members/16009740"])

    def test_the_id_is_url_escaped(self):
        # A member id is user-supplied; it must not be able to steer the path.
        uscf.member("16009740/../events")
        self.assertEqual(self.stub.paths, ["/members/16009740%2F..%2Fevents"])
        self.assertNotIn("/../", self.stub.paths[0])

    def test_online_and_over_the_board_ratings_are_separated(self):
        info = uscf.member("16009740")
        self.assertEqual(set(info["online_ratings"]), {"Online-Quick", "Online-Blitz"})
        self.assertEqual(set(info["otb_ratings"]), {"R", "Q"})

    def test_rating_rows_keep_their_numbers(self):
        info = uscf.member("16009740")
        self.assertEqual(info["otb_ratings"]["R"], {"rating": 1977, "games": 300, "provisional": False})
        self.assertEqual(
            info["online_ratings"]["Online-Quick"],
            {"rating": 1800, "games": 20, "provisional": True},
            "a row with no isProvisional flag must be assumed provisional",
        )

    def test_a_row_with_neither_a_rating_nor_a_game_is_dropped(self):
        info = uscf.member("16009740")
        self.assertNotIn("B", info["otb_ratings"])
        self.assertIn("Q", info["otb_ratings"], "games played with no rating is still a fact")

    def test_mappable_is_driven_by_the_online_ratings(self):
        info = uscf.member("16009740")
        self.assertTrue(info["mappable"])
        self.assertIn("can in principle resolve them", info["note"])

    def test_not_mappable_says_web_search_is_the_only_route(self):
        self.stub.responses = {
            "firstName": "Otto",
            "lastName": "Board",
            "ratings": [{"ratingSystem": "R", "rating": 1500, "gamesPlayed": 40}],
        }
        info = uscf.member("1234567")
        self.assertFalse(info["mappable"])
        self.assertEqual(info["online_ratings"], {})
        self.assertIn("Web search", info["note"])

    def test_a_profile_with_nothing_in_it(self):
        self.stub.responses = {}
        info = uscf.member("1234567")
        self.assertEqual(info["uscf_id"], "1234567")
        self.assertEqual(info["name"], "")
        self.assertIsNone(info["state"])
        self.assertFalse(info["mappable"])

    def test_a_null_ratings_list_is_not_a_crash(self):
        self.stub.responses = {"firstName": "A", "lastName": "B", "ratings": None}
        self.assertEqual(uscf.member("1234567")["otb_ratings"], {})

    def test_half_a_name(self):
        self.stub.responses = {"lastName": "Carlsen", "ratings": []}
        self.assertEqual(uscf.member("1234567")["name"], "Carlsen")


class CoverageReport(unittest.TestCase):
    def responses(self, path: str):
        member_id = path.rsplit("/", 1)[-1]
        if member_id == "3333333":
            return uscf.UscfError("boom")
        online = (
            {"ratingSystem": "OQ", "rating": 1800, "gamesPlayed": 20}
            if member_id == "1111111"
            else {"ratingSystem": "R", "rating": 1500, "gamesPlayed": 20}
        )
        return {"firstName": "P", "lastName": member_id, "ratings": [online]}

    def setUp(self):
        patcher = mock.patch.object(uscf, "_get", StubbedGet(self.responses))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_splits_the_field_and_reports_the_fraction(self):
        report = uscf.coverage_report(["1111111", "2222222"])
        self.assertEqual(report["checked"], 2)
        self.assertEqual(report["mappable"], 1)
        self.assertEqual(report["not_mappable"], 1)
        self.assertEqual(report["mappable_fraction"], 0.5)
        self.assertEqual([p["uscf_id"] for p in report["mappable_players"]], ["1111111"])
        self.assertEqual([p["uscf_id"] for p in report["not_mappable_players"]], ["2222222"])

    def test_a_failed_lookup_is_reported_and_not_counted(self):
        report = uscf.coverage_report(["1111111", "3333333"])
        self.assertEqual(report["checked"], 1, "an error is not a verdict")
        self.assertEqual(report["mappable_fraction"], 1.0)
        self.assertEqual(report["errors"], [{"uscf_id": "3333333", "error": "boom"}])

    def test_an_empty_field_does_not_divide_by_zero(self):
        report = uscf.coverage_report([])
        self.assertEqual(report["checked"], 0)
        self.assertEqual(report["mappable_fraction"], 0.0)

    def test_every_id_is_looked_up_once(self):
        report = uscf.coverage_report(["1111111", "1111111"])
        self.assertEqual(report["checked"], 2)


def http_response(payload: bytes):
    """Minimal stand-in for what `urlopen` yields."""
    stream = io.BytesIO(payload)
    return mock.MagicMock(
        __enter__=mock.Mock(return_value=stream), __exit__=mock.Mock(return_value=False)
    )


class Transport(unittest.TestCase):
    """`uscf._get` itself, with the socket replaced. Offline by construction:
    every test in here fails loudly rather than reaching the network, because
    `urlopen` is patched for the whole case."""

    def setUp(self):
        self._rate = uscf.RATE_LIMIT_SECONDS
        uscf.RATE_LIMIT_SECONDS = 0.0
        uscf._last_request_at = 0.0
        self.addCleanup(self.restore)

    def restore(self):
        uscf.RATE_LIMIT_SECONDS = self._rate
        uscf._last_request_at = 0.0

    def test_a_successful_call_parses_json_and_identifies_itself(self):
        with mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.return_value = http_response(b'{"ok": true}')
            self.assertEqual(uscf._get("/members/1"), {"ok": True})
            request = urlopen.call_args.args[0]
            self.assertEqual(request.full_url, f"{uscf.API}/members/1")
            self.assertIn("chess-auto-prep", request.get_header("User-agent"))

    def test_an_http_error_names_the_status(self):
        with mock.patch("urllib.request.urlopen") as urlopen:
            error = urllib.error.HTTPError("u", 404, "Not Found", {}, io.BytesIO(b""))
            self.addCleanup(error.close)
            urlopen.side_effect = error
            with self.assertRaises(uscf.UscfError) as caught:
                uscf._get("/members/1")
        self.assertIn("404", str(caught.exception))

    def test_an_unreachable_api_is_a_uscf_error_not_a_url_error(self):
        with mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.side_effect = urllib.error.URLError("no route to host")
            with self.assertRaises(uscf.UscfError) as caught:
                uscf._get("/members/1")
        self.assertIn("Could not reach", str(caught.exception))

    def test_a_timeout_is_a_uscf_error(self):
        with mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.side_effect = TimeoutError("timed out")
            with self.assertRaises(uscf.UscfError):
                uscf._get("/members/1")

    def test_unreadable_json_is_a_uscf_error(self):
        with mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.return_value = http_response(b"<html>maintenance</html>")
            with self.assertRaises(uscf.UscfError) as caught:
                uscf._get("/members/1")
        self.assertIn("unreadable JSON", str(caught.exception))

    def test_calls_are_spaced_out(self):
        # A roster sweep is dozens of requests against a public unauthenticated
        # API; back-to-back calls would look like a scrape.
        uscf.RATE_LIMIT_SECONDS = 0.15
        with mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.side_effect = lambda *a, **k: http_response(b"{}")
            started = time.monotonic()
            uscf._get("/members/1")
            uscf._get("/members/2")
        self.assertGreaterEqual(time.monotonic() - started, 0.15)

    def test_a_failed_call_still_holds_the_next_one_back(self):
        uscf.RATE_LIMIT_SECONDS = 0.15
        with mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.side_effect = urllib.error.URLError("down")
            with self.assertRaises(uscf.UscfError):
                uscf._get("/members/1")
            started = time.monotonic()
            with self.assertRaises(uscf.UscfError):
                uscf._get("/members/2")
        self.assertGreaterEqual(time.monotonic() - started, 0.15)


# ── The user's own games ────────────────────────────────────────────────────

APP_SCHEMA = """
CREATE TABLE games(id INTEGER PRIMARY KEY, collection TEXT, game_key TEXT,
  white TEXT, black TEXT, result TEXT, date TEXT, played_at INTEGER, speed TEXT,
  white_elo INTEGER, black_elo INTEGER, eco TEXT, headers_json TEXT, pgn TEXT,
  imported_at INTEGER);
CREATE TABLE positions(pos INTEGER, game_id INTEGER, ply INTEGER,
  PRIMARY KEY(pos, game_id)) WITHOUT ROWID;
CREATE TABLE collections(collection TEXT PRIMARY KEY, updated_at INTEGER,
  meta_json TEXT);
"""

START = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
AFTER_E4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"


def make_app_db(path: Path) -> None:
    """Two collections, an opponent whose name is a prefix of another, and a
    game whose headers_json is unusable."""
    rows = [
        # id, collection, key, white, black, result, date, played_at, speed,
        # welo, belo, eco, headers_json, pgn, imported_at
        (1, "analysis:chesscom_me", "k1", "MyName", "Carlsen", "1-0", "2025.01.01",
         1_000, "blitz", 1900, 2800, "C60", '{"White": "MyName"}', "1. e4 e5", 0),
        (2, "analysis:chesscom_me", "k2", "Carlsenator", "MyName", "0-1", "2025.02.01",
         2_000, "rapid", 2000, 1900, "B01", None, "1. e4 c6", 0),
        (3, "library:chesscom_me", "k3", "MyName", "Nobody", "1/2-1/2", "2025.03.01",
         3_000, "bullet", 1900, 1700, "A00", "not json at all", "1. d4", 0),
        (4, "library:chesscom_me", "k4", "Tied", "AlsoTied", "1-0", "2025.03.01",
         3_000, "bullet", 1, 2, "A00", "{}", "1. d4", 0),
        (5, "analysis:chesscom_me", "k5", "Extra", "Other", "1-0", "2024.01.01",
         500, "blitz", 1500, 1500, "A00", "{}", "1. c4", 0),
        # Two accounts one LIKE wildcard apart, and a name that is nothing but
        # wildcards. "tactics" ties with "library:chesscom_me" on game count.
        (6, "tactics", "k6", "under_score", "Rival", "1-0", "2024.02.01",
         600, "blitz", 1500, 1500, "A00", "{}", "1. e4", 0),
        (7, "tactics", "k7", "underxscore", "Rival", "0-1", "2024.03.01",
         700, "blitz", 1500, 1500, "A00", "{}", "1. e4", 0),
    ]
    conn = sqlite3.connect(path)
    try:
        conn.executescript(APP_SCHEMA)
        conn.executemany("INSERT INTO games VALUES(" + ",".join("?" * 15) + ")", rows)
        conn.execute("INSERT INTO positions VALUES(?,1,1)", (position_key(fen4_of(AFTER_E4)),))
        conn.execute("INSERT INTO positions VALUES(?,2,1)", (position_key(fen4_of(AFTER_E4)),))
        conn.execute("INSERT INTO collections VALUES('analysis:chesscom_me', 42, '{}')")
        conn.commit()
    finally:
        conn.close()


class OwnGames(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.path = Path(self._dir.name) / "app_games.db"
        make_app_db(self.path)
        self.db = AppGamesDb(self.path)
        self.addCleanup(self.db.close)

    def test_a_missing_database_is_a_readable_tool_error(self):
        with self.assertRaises(ToolError) as caught:
            AppGamesDb(Path(self._dir.name) / "nope.db")
        self.assertIn("CHESS_PREP_APP_GAMES_DB", str(caught.exception))

    def test_it_is_opened_read_only(self):
        # The app owns this file; the server must not be able to damage it.
        with self.assertRaises(sqlite3.OperationalError):
            self.db._conn.execute("DELETE FROM games")

    def test_the_path_can_be_overridden(self):
        with mock.patch.dict("os.environ", {"CHESS_PREP_APP_GAMES_DB": "~/x/app.db"}):
            self.assertEqual(app_games_db_path(), Path.home() / "x" / "app.db")

    def test_collections_are_counted_biggest_first(self):
        self.assertEqual(
            self.db.collections(),
            [
                {"collection": "analysis:chesscom_me", "games": 3, "updated_at": 42},
                {"collection": "library:chesscom_me", "games": 2, "updated_at": None},
                {"collection": "tactics", "games": 2, "updated_at": None},
            ],
        )

    def test_collections_of_equal_size_have_a_fixed_order(self):
        # REGRESSION: ordering was by count alone, so two collections holding
        # the same number of games swapped places at SQLite's discretion.
        # "library:chesscom_me" and "tactics" both hold 2.
        names = [c["collection"] for c in self.db.collections()]
        self.assertEqual(names.index("library:chesscom_me") + 1, names.index("tactics"))
        for _ in range(3):
            self.assertEqual([c["collection"] for c in self.db.collections()], names)

    def test_by_player_matches_either_colour(self):
        self.assertEqual([g["id"] for g in self.db.by_player("Carlsen")], [2, 1])

    def test_by_player_ignores_case(self):
        self.assertEqual(
            [g["id"] for g in self.db.by_player("carlsenator")],
            [g["id"] for g in self.db.by_player("CARLSENATOR")],
        )

    def test_by_player_is_a_prefix_not_a_substring(self):
        # "sen" appears inside both Carlsen names and must not match either;
        # otherwise every short query drags in unrelated players' games.
        self.assertEqual(self.db.by_player("sen"), [])
        self.assertEqual(self.db.by_player("arlsen"), [])

    def test_a_longer_name_is_not_confused_with_a_shorter_one(self):
        # "Carlsenator" is a different account from "Carlsen".
        self.assertEqual([g["id"] for g in self.db.by_player("Carlsenator")], [2])
        self.assertNotIn(1, [g["id"] for g in self.db.by_player("Carlsenator")])

    def test_newest_first_with_a_deterministic_tiebreak(self):
        # Games 3 and 4 share played_at; the higher id must come first.
        self.assertEqual(
            [g["id"] for g in self.db.by_player("", collection="library:chesscom_me")],
            [4, 3],
        )

    def test_the_collection_filter_narrows(self):
        self.assertEqual(
            [g["id"] for g in self.db.by_player("MyName", collection="library:chesscom_me")],
            [3],
        )
        self.assertEqual([g["id"] for g in self.db.by_player("MyName")], [3, 2, 1])

    def test_the_limit_is_respected(self):
        self.assertEqual([g["id"] for g in self.db.by_player("MyName", limit=2)], [3, 2])
        self.assertEqual(self.db.by_player("MyName", limit=0), [])

    def test_a_miss(self):
        self.assertEqual(self.db.by_player("Kasparov"), [])

    def test_an_underscore_in_a_username_is_a_letter_not_a_wildcard(self):
        # REGRESSION: LIKE reads "_" as "any character", so a search for
        # "under_score" also returned "underxscore" — a different account's
        # games, silently mixed into the answer. Chess.com usernames are full
        # of underscores, so this was the common case, not an exotic one.
        self.assertEqual([g["id"] for g in self.db.by_player("under_score")], [6])
        self.assertEqual([g["id"] for g in self.db.by_player("underxscore")], [7])
        self.assertEqual([g["id"] for g in self.db.by_player("under_")], [6])

    def test_a_percent_matches_nothing_rather_than_everything(self):
        # REGRESSION: "%" was a match-all, so one stray character returned the
        # user's entire database as though it were one player's games.
        self.assertEqual(self.db.by_player("%"), [])
        self.assertEqual(self.db.by_player("%Name"), [])
        self.assertEqual(self.db.by_player("_"), [])

    def test_a_backslash_is_matched_literally(self):
        # The escape character itself must not leak into the pattern.
        self.assertEqual(self.db.by_player("\\"), [])
        self.assertEqual(self.db.by_player("\\%"), [])

    def test_escaping_does_not_break_ordinary_names(self):
        self.assertEqual([g["id"] for g in self.db.by_player("MyName")], [3, 2, 1])

    def test_games_at_a_position(self):
        after_e4 = [g["id"] for g in self.db.games_at(AFTER_E4)]
        self.assertEqual(after_e4, [2, 1], "newest first")
        self.assertEqual(self.db.games_at(START), [], "no game is indexed at the start")

    def test_games_at_respects_the_collection_and_the_limit(self):
        self.assertEqual(
            [g["id"] for g in self.db.games_at(AFTER_E4, collection="library:chesscom_me")],
            [],
        )
        self.assertEqual([g["id"] for g in self.db.games_at(AFTER_E4, limit=1)], [2])

    def test_a_position_key_ignores_the_move_counters(self):
        # The index is keyed on four FEN fields, so the same position reached
        # by a different move order still matches.
        shuffled = AFTER_E4.replace(" 0 1", " 7 30")
        self.assertEqual([g["id"] for g in self.db.games_at(shuffled)], [2, 1])

    def test_headers_are_decoded_and_the_raw_column_is_gone(self):
        game = self.db.game(1)
        self.assertEqual(game["headers"], {"White": "MyName"})
        self.assertNotIn("headers_json", game)
        self.assertEqual(game["pgn"], "1. e4 e5")

    def test_unusable_headers_degrade_to_empty(self):
        self.assertEqual(self.db.game(2)["headers"], {}, "NULL headers_json")
        self.assertEqual(self.db.game(3)["headers"], {}, "malformed headers_json")

    def test_an_unknown_game_id(self):
        self.assertIsNone(self.db.game(999))
        self.assertIsNone(self.db.game(0))


if __name__ == "__main__":
    unittest.main(verbosity=2)
