#!/usr/bin/env python3
"""Tests for the standalone prep MCP server.

Zero dependencies (unittest only). Network-touching tools are exercised
through a stub so the suite runs offline; the real US Chess API is only hit by
`--live`.

Run:
    python tools/mcp/test_chess_prep.py
    python tools/mcp/test_chess_prep.py --live
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep import roster as roster_mod  # noqa: E402
from chess_prep.directory import (  # noqa: E402
    DirectoryEntry,
    PlayerDirectory,
    parse_player_name,
    player_name_key,
)
from chess_prep.opponents import FORMAT, opponents_document  # noqa: E402
from chess_prep.roster import (  # noqa: E402
    Roster,
    RosterEntry,
    parse_entry_list,
    roster_to_csv,
)
from chess_prep.server import Server  # noqa: E402
from chess_prep.swiss import (  # noqa: E402
    PairingConstraint,
    SimulationConfig,
    SwissPairer,
    SwissRules,
    SwissSeed,
    simulate,
)
from chess_prep.tools import Registry, ToolError  # noqa: E402
from mcp_stdio import StdioServer  # noqa: E402

# A real US Chess event page: FIDE ID before USCF ID (both 7-9 digits), FIDE
# rating before USCF rating, `[EQ]`/`Unr`, and markers inside the name cell.
REAL_ENTRY_LIST = (
    "Player's Name\tFIDE ID\tFIDE Rating\tUSCF ID\tUSCF Rating\tState\t"
    "Section\tSchedule\tBye(s)\n"
    "Anatra, Owen Chance\t30997160 [USA]\t1807\t30379415\t1858\tCT\t"
    "Under 2100\t4 Day\t\n"
    "Bernal, Andrew\t30992060 [USA]\t1866\t16009740\t1977\tMA\t"
    "Under 2100\t3 Day\t\n"
    "Farley, Jeremiah\t11106972 [BAR]\t1835\t33132698\t1900 [EQ]\t\t"
    "Under 2100\t4 Day\t\n"
    "Grennan, Rhyan\t566023718 [USA]\tUnr\t16448236\t1907\tNY\t"
    "Under 2100\t3 Day\t\n"
    "Sandeep Kumar, Arav (Withdrawn)\t39963470 [USA]\t1646\t31425499\t1700\tNJ\t"
    "Under 2100\t4 Day\t1/2:R1\n"
    "Tereshchenko, Eliza (WCM) (Withdrawn)\t34389890 [FID]\t1924\t33203591\t"
    "2000 [EQ]\tMA\tUnder 2100\t4 Day\t\n"
)


def _fake_directory() -> PlayerDirectory:
    entries = [
        DirectoryEntry("16009740", "Andrew Bernal", "andrewb", "exact", "opponent_graph"),
        DirectoryEntry("11111111", "John Smith", "alpha", "exact", "opponent_graph"),
        DirectoryEntry("22222222", "Smith, John", "beta", "exact", "signature"),
        DirectoryEntry("33333333", "Jane Doe", "gamma", "medium", "score_position"),
    ]
    return PlayerDirectory(entries, {"gamma": "IM"}, events_processed=1600)


class TempRosterCase(unittest.TestCase):
    """Redirects the shared roster to a temp file for each test."""

    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        os.environ["CHESS_PREP_ROSTER"] = str(Path(self._dir.name) / "roster.json")
        self.registry = Registry()
        self.registry._directory = _fake_directory()

    def tearDown(self) -> None:
        self.registry.close()
        os.environ.pop("CHESS_PREP_ROSTER", None)
        self._dir.cleanup()

    def call(self, name: str, **args):
        return self.registry.call(name, args)


class NameNormalization(unittest.TestCase):
    def test_orderings_collapse(self):
        self.assertEqual(
            player_name_key("VIDIP KUMAR KONA"), player_name_key("Kona, Vidip Kumar")
        )
        self.assertEqual(
            player_name_key("Justin Weicheng Zhang"), player_name_key("Zhang, Justin")
        )

    def test_punctuation_and_suffixes(self):
        self.assertEqual(player_name_key("O'Brien, Sean"), player_name_key("Sean OBrien"))
        self.assertEqual(player_name_key("John Smith Jr."), player_name_key("Smith, John"))

    def test_hyphen_is_asymmetric(self):
        # Given names split on a hyphen; surnames absorb it.
        self.assertEqual(
            player_name_key("Anne-Marie Dubois"), player_name_key("Dubois, Anne Marie")
        )
        self.assertEqual(parse_player_name("Smith-Jones, Alice")[1], "SMITHJONES")
        self.assertEqual(parse_player_name("Alice Smith-Jones")[1], "SMITHJONES")

    def test_distinguishes_people(self):
        self.assertNotEqual(player_name_key("John Smith"), player_name_key("Jane Smith"))

    def test_matches_dart_keys(self):
        # These exact pairs are asserted in
        # test/features/tournament/roster_import_test.dart. The two
        # implementations resolve the same roster, so they must not drift.
        self.assertEqual(player_name_key("Van Der Berg, Jan"), "JAN|VANDERBERG")
        self.assertEqual(player_name_key("Magnus"), "|MAGNUS")
        self.assertEqual(player_name_key(""), "|")


class EntryListParsing(unittest.TestCase):
    def setUp(self) -> None:
        self.roster, self.warnings, self.fmt = parse_entry_list(
            REAL_ENTRY_LIST, event_name="Test Open", my_uscf_id="16009740"
        )

    def test_uses_the_header_path(self):
        self.assertEqual(self.fmt, "csv")
        self.assertEqual(len(self.roster.entries), 6)

    def test_takes_uscf_id_not_fide_id(self):
        anatra = self.roster.entries[0]
        self.assertEqual(anatra.uscf_id, "30379415")
        self.assertNotEqual(anatra.uscf_id, "30997160")

    def test_takes_uscf_rating_not_fide_rating(self):
        self.assertEqual(self.roster.entries[0].rating, 1858)

    def test_reads_eq_annotated_rating(self):
        farley = next(e for e in self.roster.entries if e.name.startswith("Farley"))
        self.assertEqual(farley.rating, 1900)

    def test_unr_does_not_leak(self):
        grennan = next(e for e in self.roster.entries if e.name.startswith("Grennan"))
        self.assertEqual(grennan.rating, 1907)

    def test_withdrawn_and_title_markers(self):
        eliza = next(
            e for e in self.roster.entries if e.name.startswith("Tereshchenko")
        )
        self.assertEqual(eliza.name, "Tereshchenko, Eliza")
        self.assertEqual(eliza.title, "WCM")
        self.assertTrue(eliza.withdrawn)
        self.assertEqual(eliza.rating, 2000)

    def test_finds_me(self):
        self.assertIsNotNone(self.roster.me)
        self.assertEqual(self.roster.me.name, "Bernal, Andrew")

    def test_no_spurious_warnings(self):
        self.assertEqual(self.warnings, [], f"warnings: {self.warnings}")

    def test_freeform_fallback(self):
        roster, _, fmt = parse_entry_list(
            "1   Smith, John        12345678   1850\n"
            "2   Doe, Jane          87654321   2010\n"
        )
        self.assertEqual(fmt, "text")
        self.assertEqual(roster.entries[1].rating, 2010)
        self.assertEqual(roster.entries[1].uscf_id, "87654321")

    def test_ids_are_stable_and_unique(self):
        roster, _, _ = parse_entry_list("Alice Brown 1700\nAlice Brown 1500\n")
        ids = [e.id for e in roster.entries]
        self.assertEqual(len(set(ids)), len(ids))


class DirectoryLookup(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = _fake_directory()

    def test_by_id(self):
        self.assertEqual(self.directory.by_uscf_id("11111111").chesscom_username, "alpha")

    def test_reverse_lookup_is_case_insensitive(self):
        self.assertEqual(self.directory.by_chesscom_username("ALPHA").uscf_id, "11111111")

    def test_ambiguous_name_returns_candidates(self):
        identity = self.directory.resolve(name="John Smith")
        self.assertEqual(identity["confidence"], "ambiguous")
        self.assertNotIn("chesscom_username", identity)
        self.assertEqual(len(identity["alternates"]), 2)

    def test_unique_name_is_downgraded(self):
        identity = self.directory.resolve(name="Jane Doe")
        self.assertEqual(identity["chesscom_username"], "gamma")
        self.assertEqual(identity["confidence"], "medium")
        self.assertIn("matched on name", identity["evidence"])

    def test_id_beats_name(self):
        identity = self.directory.resolve(uscf_id="11111111", name="John Smith")
        self.assertEqual(identity["confidence"], "exact")

    def test_miss(self):
        self.assertIsNone(self.directory.resolve(uscf_id="00000000"))


class RealAsset(unittest.TestCase):
    def test_bundled_asset_loads(self):
        directory = PlayerDirectory.load()
        self.assertGreater(directory.player_count, 3000)
        self.assertGreater(directory.titled_count, 10000)

    def test_agrees_with_the_dart_side_on_a_known_row(self):
        # Same row asserted in test/features/tournament/player_directory_test.dart.
        directory = PlayerDirectory.load()
        hit = directory.by_uscf_id("17182781")
        self.assertIsNotNone(hit)
        self.assertEqual(hit.chesscom_username, "Jianda2019")
        self.assertEqual(hit.method, "opponent_graph")
        self.assertEqual(hit.confidence, "exact")


class Tools(TempRosterCase):
    def test_every_tool_is_described(self):
        for name, tool in self.registry.tools.items():
            self.assertGreater(len(tool["description"]), 60, name)
            self.assertEqual(tool["inputSchema"]["type"], "object")

    def test_unknown_tool(self):
        with self.assertRaises(ToolError):
            self.call("nope")

    def test_directory_search_requires_a_key(self):
        with self.assertRaises(ToolError):
            self.call("directory_search")

    def test_import_saves_to_disk(self):
        result = self.call(
            "roster_import", text=REAL_ENTRY_LIST, my_uscf_id="16009740"
        )
        self.assertEqual(result["entry_count"], 6)
        self.assertTrue(Path(result["saved_to"]).exists())

        saved = json.loads(Path(result["saved_to"]).read_text())
        self.assertEqual(len(saved["entries"]), 6)

    def test_saved_roster_round_trips(self):
        self.call("roster_import", text=REAL_ENTRY_LIST, my_uscf_id="16009740")
        saved = json.loads(Path(os.environ["CHESS_PREP_ROSTER"]).read_text())

        self.assertEqual(
            set(saved) & {"event_name", "rounds", "accelerated", "entries"},
            {"event_name", "rounds", "accelerated", "entries"},
        )
        me = next(e for e in saved["entries"] if e.get("is_me"))
        self.assertEqual(me["uscf_id"], "16009740")
        self.assertIn("rating", me)

        withdrawn = next(e for e in saved["entries"] if e.get("withdrawn"))
        self.assertTrue(withdrawn["withdrawn"])

    def test_resolve_then_work_list(self):
        self.call("roster_import", text=REAL_ENTRY_LIST, my_uscf_id="16009740")
        summary = self.call("roster_resolve")

        self.assertEqual(summary["resolved"], 1)  # only Bernal is in the fake dir
        self.assertGreater(summary["unresolved"], 0)
        names = [e["name"] for e in summary["unresolved_entries"]]
        self.assertNotIn("Bernal, Andrew", names, "we are never in the work list")

    def test_propose_is_not_actionable(self):
        self.call("roster_import", text=REAL_ENTRY_LIST)
        result = self.call(
            "identity_propose",
            player_id="30379415",
            chesscom_username="guess",
            evidence="Bio mentions Connecticut and the right rating.",
            confidence="high",
        )
        self.assertFalse(result["actionable"])

        entry = roster_mod.load_roster().find("30379415")
        self.assertEqual(entry.identity["source"], "agent_proposed")
        self.assertFalse(entry.is_actionable)

    def test_propose_requires_evidence(self):
        self.call("roster_import", text=REAL_ENTRY_LIST)
        with self.assertRaises(ToolError):
            self.call("identity_propose", player_id="30379415", chesscom_username="x", evidence="  ")

    def test_propose_requires_an_account(self):
        self.call("roster_import", text=REAL_ENTRY_LIST)
        with self.assertRaises(ToolError):
            self.call("identity_propose", player_id="30379415", evidence="saw something")

    def test_confirm_makes_it_actionable_and_keeps_evidence(self):
        self.call("roster_import", text=REAL_ENTRY_LIST)
        self.call(
            "identity_propose",
            player_id="30379415",
            chesscom_username="guess",
            evidence="Profile names him.",
        )
        self.call("identity_confirm", player_id="30379415")

        entry = roster_mod.load_roster().find("30379415")
        self.assertTrue(entry.is_actionable)
        self.assertEqual(entry.identity["source"], "manual")
        self.assertIn("Profile names him.", entry.identity["evidence"])

    def test_confirm_needs_something_to_confirm(self):
        self.call("roster_import", text=REAL_ENTRY_LIST)
        with self.assertRaises(ToolError):
            self.call("identity_confirm", player_id="30379415")

    def test_resolve_does_not_clobber_a_confirmation(self):
        self.call("roster_import", text=REAL_ENTRY_LIST, my_uscf_id="16009740")
        self.call(
            "identity_propose",
            player_id="16009740",
            chesscom_username="user_says_this",
            evidence="They told me.",
        )
        self.call("identity_confirm", player_id="16009740")
        self.call("roster_resolve")

        entry = roster_mod.load_roster().find("16009740")
        self.assertEqual(entry.identity["chesscom_username"], "user_says_this")

    def test_roster_update_moves_the_me_flag(self):
        self.call("roster_import", text=REAL_ENTRY_LIST, my_uscf_id="16009740")
        self.call("roster_update", player_id="30379415", is_me=True)

        roster = roster_mod.load_roster()
        self.assertEqual(len([e for e in roster.entries if e.is_me]), 1)
        self.assertEqual(roster.me.id, "30379415")

    def test_roster_update_validates(self):
        self.call("roster_import", text=REAL_ENTRY_LIST)
        with self.assertRaises(ToolError):
            self.call("roster_update", player_id="ghost")
        with self.assertRaises(ToolError):
            self.call("roster_update", player_id="30379415", attendance_prob=5)

    def test_constraints_must_reference_real_entrants(self):
        self.call("roster_import", text=REAL_ENTRY_LIST)
        with self.assertRaises(ToolError):
            self.call("constraint_add", player_a="30379415", player_b="ghost")
        result = self.call(
            "constraint_add", player_a="30379415", player_b="16009740", reason="siblings"
        )
        self.assertEqual(result["constraints"], 1)

    def test_csv_round_trip_preserves_provenance(self):
        self.call("roster_import", text=REAL_ENTRY_LIST)
        self.call(
            "identity_propose",
            player_id="30379415",
            chesscom_username="guess",
            evidence='Bio said "USCF 30379415, CT", which matches.',
            confidence="low",
        )
        csv_text = self.call("roster_export")["content"]

        back, _, _ = parse_entry_list(csv_text)
        entry = next(e for e in back.entries if e.name.startswith("Anatra"))
        self.assertEqual(entry.identity["source"], "agent_proposed")
        self.assertEqual(entry.identity["confidence"], "low")
        self.assertFalse(
            entry.is_actionable,
            "a round trip must not launder a guess into a trusted identity",
        )

    def test_hand_made_csv_is_trusted(self):
        roster, _, _ = parse_entry_list(
            "Name,Rating,chess.com\nAlice Brown,1700,alicebrown99\n"
        )
        entry = roster.entries[0]
        self.assertEqual(entry.identity["source"], "manual")
        self.assertTrue(entry.is_actionable)

    def test_corrupt_roster_file_does_not_wedge_the_server(self):
        Path(os.environ["CHESS_PREP_ROSTER"]).write_text("{ not json")
        self.assertEqual(roster_mod.load_roster().entries, [])

    def test_coverage_report_needs_ids(self):
        with self.assertRaises(ToolError):
            self.call("uscf_coverage_report")


# ── Swiss pairing ───────────────────────────────────────────────────────────


def _seeds(count: int, base: int = 2000, step: int = 50) -> list[SwissSeed]:
    """Seeds rated base, base-step, … so the rating order is unambiguous."""
    return [SwissSeed(id=f"p{i + 1}", rating=base - i * step) for i in range(count)]


def _all_white_win(sheet) -> dict[str, float]:
    return {p.white_id: 1.0 for p in sheet.pairings}


class SwissPairing(unittest.TestCase):
    def test_round_one_splits_the_field_in_half_and_pairs_across(self):
        sheet = SwissPairer(_seeds(8)).next_round()
        self.assertEqual(len(sheet.pairings), 4)
        by_board = {p.board: {p.white_id, p.black_id} for p in sheet.pairings}
        self.assertEqual(by_board[1], {"p1", "p5"})
        self.assertEqual(by_board[2], {"p2", "p6"})
        self.assertEqual(by_board[3], {"p3", "p7"})
        self.assertEqual(by_board[4], {"p4", "p8"})

    def test_round_one_alternates_colors_down_the_boards(self):
        sheet = SwissPairer(_seeds(8)).next_round()
        self.assertEqual([p.white_id for p in sheet.pairings], ["p1", "p6", "p3", "p8"])

    def test_odd_field_gives_a_full_point_bye_to_the_lowest_rated(self):
        sheet = SwissPairer(_seeds(7)).next_round()
        self.assertEqual(len(sheet.pairings), 3)
        (bye,) = sheet.byes
        self.assertEqual((bye.player_id, bye.points, bye.requested), ("p7", 1.0, False))

    def test_never_repeats_a_pairing(self):
        pairer = SwissPairer(_seeds(16), SwissRules(rounds=5))
        seen: set[str] = set()
        for rnd in range(1, 6):
            sheet = pairer.next_round()
            for p in sheet.pairings:
                key = "|".join(sorted([p.white_id, p.black_id]))
                self.assertNotIn(key, seen, f"repeat pairing {key} in round {rnd}")
                seen.add(key)
            pairer.record_results(sheet, _all_white_win(sheet))

    def test_pairs_within_score_groups(self):
        pairer = SwissPairer(_seeds(8))
        r1 = pairer.next_round()
        pairer.record_results(r1, _all_white_win(r1))
        winners = {p.white_id for p in r1.pairings}
        for p in pairer.next_round().pairings:
            both_won = p.white_id in winners and p.black_id in winners
            both_lost = p.white_id not in winners and p.black_id not in winners
            self.assertTrue(both_won or both_lost, f"{p} crosses score groups")

    def test_equalizes_colors(self):
        pairer = SwissPairer(_seeds(8))
        for _ in range(4):
            sheet = pairer.next_round()
            pairer.record_results(sheet, {p.white_id: 0.5 for p in sheet.pairings})
        for s in pairer.standings():
            self.assertLessEqual(abs(s.color_balance), 1, s.player_id)

    def test_honors_a_withhold(self):
        rules = SwissRules(constraints=(PairingConstraint("p1", "p5", "siblings"),))
        sheet = SwissPairer(_seeds(8), rules).next_round()
        p1 = sheet.for_player("p1")
        self.assertIsNotNone(p1)
        self.assertNotEqual(p1.opponent_of("p1"), "p5")
        self.assertFalse(p1.forced)
        self.assertEqual(sheet.forced_count, 0)

    def test_marks_a_pairing_forced_when_no_legal_alternative_exists(self):
        pairer = SwissPairer(_seeds(2))
        r1 = pairer.next_round()
        pairer.record_results(r1, {r1.pairings[0].white_id: 0.5})
        (p,) = pairer.next_round().pairings
        self.assertTrue(p.forced)

    def test_respects_a_requested_half_point_bye(self):
        pairer = SwissPairer(
            [
                SwissSeed("p1", 2000, frozenset({1})),
                SwissSeed("p2", 1900),
                SwissSeed("p3", 1800),
            ]
        )
        sheet = pairer.next_round()
        self.assertIsNone(sheet.for_player("p1"))
        bye = next(b for b in sheet.byes if b.player_id == "p1")
        self.assertEqual((bye.points, bye.requested), (0.5, True))
        pairer.record_results(sheet, _all_white_win(sheet))
        self.assertEqual(pairer.score_of("p1"), 0.5)

    def test_no_player_gets_two_full_point_byes(self):
        pairer = SwissPairer(_seeds(5))
        byes: list[str] = []
        for _ in range(4):
            sheet = pairer.next_round()
            byes.extend(b.player_id for b in sheet.byes if not b.requested)
            pairer.record_results(sheet, _all_white_win(sheet))
        self.assertEqual(len(set(byes)), len(byes), byes)

    def test_accelerated_pairs_the_top_quarter_against_the_second(self):
        rules = SwissRules(accelerated=True, accelerated_rounds=2)
        sheet = SwissPairer(_seeds(16), rules).next_round()
        self.assertEqual(sheet.for_player("p1").opponent_of("p1"), "p5")
        self.assertEqual(sheet.for_player("p9").opponent_of("p9"), "p13")

    def test_is_deterministic(self):
        def run() -> list[str]:
            pairer = SwissPairer(_seeds(12))
            out = []
            for _ in range(4):
                sheet = pairer.next_round()
                out.extend(f"{p.white_id}-{p.black_id}" for p in sheet.pairings)
                pairer.record_results(sheet, _all_white_win(sheet))
            return out

        self.assertEqual(run(), run())


def _field(count: int, me_index: int = 0, rounds: int = 5, **kw) -> Roster:
    return Roster(
        event_name="Test Open",
        rounds=rounds,
        entries=[
            RosterEntry(
                id=f"p{i + 1}",
                name=f"Player {i + 1}",
                rating=2000 - i * 50,
                is_me=i == me_index,
            )
            for i in range(count)
        ],
        **kw,
    )


_FAST = SimulationConfig(trials=300)


class Simulation(unittest.TestCase):
    def test_round_one_is_near_certain(self):
        result = simulate(_field(16), _FAST)
        p9 = next(o for o in result.opponents if o.player_id == "p9")
        self.assertEqual(p9.prob_by_round[0], 1.0)
        self.assertEqual(p9.most_likely_round, 1)

    def test_later_rounds_diffuse(self):
        result = simulate(_field(16), _FAST)
        r1 = sum(1 for o in result.opponents if o.prob_by_round[0] > 0)
        r4 = sum(1 for o in result.opponents if o.prob_by_round[3] > 0)
        self.assertEqual(r1, 1)
        self.assertGreater(r4, 2)

    def test_pairing_mass_equals_rounds_played(self):
        result = simulate(_field(20), _FAST)
        mass = sum(sum(o.prob_by_round) for o in result.opponents)
        self.assertAlmostEqual(mass + result.bye_prob * 0, 5.0, delta=0.05)
        for o in result.opponents:
            self.assertLessEqual(o.prob_any, 1.0)
            self.assertAlmostEqual(o.prob_as_white + o.prob_as_black, sum(o.prob_by_round), places=6)

    def test_withhold_removes_that_opponent(self):
        roster = _field(16, constraints=[{"a": "p1", "b": "p9", "reason": "siblings"}])
        result = simulate(roster, _FAST)
        self.assertNotIn("p9", {o.player_id for o in result.opponents})

    def test_withdrawn_players_are_never_faced(self):
        roster = _field(16)
        roster.entries[8].withdrawn = True
        result = simulate(roster, _FAST)
        self.assertNotIn("p9", {o.player_id for o in result.opponents})

    def test_attendance_probability_scales_exposure(self):
        roster = _field(16)
        roster.entries[8].attendance_prob = 0.5
        result = simulate(roster, _FAST)
        p9 = next(o for o in result.opponents if o.player_id == "p9")
        self.assertGreater(p9.prob_by_round[0], 0.35)
        self.assertLess(p9.prob_by_round[0], 0.65)

    def test_sections_are_independent(self):
        roster = _field(16)
        for i, e in enumerate(roster.entries):
            e.section = "Open" if i < 8 else "U1800"
        result = simulate(roster, _FAST)
        self.assertTrue(all(int(o.player_id[1:]) <= 8 for o in result.opponents))

    def test_no_reference_player_is_reported(self):
        roster = _field(8)
        roster.entries[0].is_me = False
        result = simulate(roster, _FAST)
        self.assertEqual(result.opponents, [])
        self.assertTrue(result.notes)

    def test_reproducible_for_a_seed(self):
        a = simulate(_field(12), SimulationConfig(trials=200, seed=1)).to_dict()
        b = simulate(_field(12), SimulationConfig(trials=200, seed=1)).to_dict()
        c = simulate(_field(12), SimulationConfig(trials=200, seed=2)).to_dict()
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)


class PairingTools(TempRosterCase):
    def _load_field(self) -> None:
        self.call("roster_import", text=REAL_ENTRY_LIST, my_uscf_id="16009740")

    def test_simulate_needs_a_reference_player(self):
        self.call("roster_import", text=REAL_ENTRY_LIST)
        with self.assertRaises(ToolError):
            self.call("pairing_simulate", trials=50)

    def test_simulate_returns_named_opponents_and_persists(self):
        self._load_field()
        result = self.call("pairing_simulate", trials=100)
        self.assertGreater(len(result["opponents"]), 0)
        self.assertIn("name", result["opponents"][0])
        saved = json.loads(Path(os.environ["CHESS_PREP_ROSTER"]).read_text())
        with_pairing = [e for e in saved["entries"] if e.get("pairing")]
        self.assertEqual(len(with_pairing), len(result["opponents"]))

    def test_export_only_includes_confirmed_accounts(self):
        self._load_field()
        self.call("roster_resolve")  # andrewb is me; alpha/beta not on the list
        self.call(
            "identity_propose",
            player_id="30379415",
            chesscom_username="owen_a",
            evidence="profile says so",
        )
        out = self.call("opponents_export")
        doc = json.loads(Path(out["path"]).read_text())
        self.assertEqual(doc["format"], FORMAT)
        self.assertEqual(doc["opponents"], [])
        self.assertTrue(any("not confirmed" in s["reason"] for s in out["skipped"]))

        self.call("identity_confirm", player_id="30379415")
        out = self.call("opponents_export")
        doc = json.loads(Path(out["path"]).read_text())
        self.assertEqual([o["name"] for o in doc["opponents"]], ["Anatra, Owen Chance"])
        self.assertEqual(doc["opponents"][0]["chesscom"], "owen_a")
        self.assertNotIn("Andrew Bernal", [o["name"] for o in doc["opponents"]])

    def test_export_carries_pairing_probability_and_sorts_by_it(self):
        self._load_field()
        for pid, user in (("30379415", "owen_a"), ("33132698", "jf")):
            self.call("identity_confirm", player_id=pid, chesscom_username=user)
        self.call("pairing_simulate", trials=100)
        out = self.call("opponents_export", path=str(Path(self._dir.name) / "o.json"))
        doc = json.loads(Path(out["path"]).read_text())
        probs = [o["pairing_prob"] for o in doc["opponents"]]
        self.assertEqual(len(probs), 2)
        self.assertEqual(probs, sorted(probs, reverse=True))
        self.assertTrue(all(0 <= p <= 1 for p in probs))

    def test_export_document_skips_me_and_withdrawn(self):
        roster = _field(4)
        for e in roster.entries:
            e.identity = {"chesscom_username": e.id, "confidence": "exact", "source": "manual"}
        roster.entries[3].withdrawn = True
        doc, skipped = opponents_document(roster)
        self.assertEqual([o["name"] for o in doc["opponents"]], ["Player 2", "Player 3"])
        self.assertEqual(skipped, [])


class Protocol(TempRosterCase):
    """Drives the JSON-RPC loop directly."""

    def _run(self, messages: list[dict]) -> list[dict]:
        stdin = io.StringIO("".join(json.dumps(m) + "\n" for m in messages))
        stdout = io.StringIO()
        server = Server(stdin=stdin, stdout=stdout)
        server.registry._directory = _fake_directory()
        server.serve_forever()
        return [json.loads(line) for line in stdout.getvalue().splitlines() if line]

    def test_initialize_echoes_the_protocol_version(self):
        out = self._run(
            [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": "2025-06-18"}}]
        )
        self.assertEqual(out[0]["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(out[0]["result"]["serverInfo"]["name"], "chess-prep")

    def test_initialize_without_a_version(self):
        out = self._run([{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}])
        self.assertRegex(out[0]["result"]["protocolVersion"], r"^\d{4}-\d{2}-\d{2}$")

    def test_notifications_are_not_answered(self):
        out = self._run(
            [
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "ping"},
            ]
        )
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["id"], 2)

    def test_tools_list(self):
        out = self._run([{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])
        names = [t["name"] for t in out[0]["result"]["tools"]]
        self.assertIn("directory_search", names)
        self.assertIn("uscf_member", names)
        self.assertIn("identity_propose", names)

    def test_tools_call_returns_text_content(self):
        out = self._run(
            [
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {
                        "name": "directory_search",
                        "arguments": {"uscf_id": "11111111"},
                    },
                }
            ]
        )
        payload = json.loads(out[0]["result"]["content"][0]["text"])
        self.assertEqual(payload["entry"]["chesscom_username"], "alpha")

    def test_tool_error_is_content_not_transport(self):
        out = self._run(
            [
                {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                 "params": {"name": "directory_search", "arguments": {}}}
            ]
        )
        self.assertNotIn("error", out[0])
        self.assertTrue(out[0]["result"]["isError"])
        self.assertIn("Supply one of", out[0]["result"]["content"][0]["text"])

    def test_unknown_method(self):
        out = self._run([{"jsonrpc": "2.0", "id": 1, "method": "nonsense"}])
        self.assertEqual(out[0]["error"]["code"], -32601)

    def test_call_without_a_name(self):
        out = self._run(
            [{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {}}]
        )
        self.assertEqual(out[0]["error"]["code"], -32602)

    def test_malformed_line_does_not_stop_the_loop(self):
        stdin = io.StringIO('{not json\n{"jsonrpc":"2.0","id":2,"method":"ping"}\n')
        stdout = io.StringIO()
        Server(stdin=stdin, stdout=stdout).serve_forever()
        out = [json.loads(l) for l in stdout.getvalue().splitlines() if l]
        self.assertEqual(out[0]["error"]["code"], -32700)
        self.assertEqual(out[1]["id"], 2)

    def test_non_ascii_survives_the_wire(self):
        # The Dart bridge shipped a latin1 bug that broke exactly this.
        out = self._run([{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])
        search = next(
            t for t in out[0]["result"]["tools"] if t["name"] == "directory_search"
        )
        self.assertIn("→", search["description"])

    def test_end_of_input_closes_the_registry(self):
        class ClosingRegistry:
            closed = False

            def definitions(self):
                return []

            def call(self, name, args):
                raise AssertionError("no calls expected")

            def close(self):
                self.closed = True

        registry = ClosingRegistry()
        StdioServer(
            registry,
            name="test",
            stdin=io.StringIO(""),
            stdout=io.StringIO(),
        ).serve_forever()

        self.assertTrue(registry.closed)


class Subprocess(unittest.TestCase):
    """Proves an MCP client can actually spawn it the documented way."""

    def test_runs_as_a_module_entry_point(self):
        entry = Path(__file__).resolve().parent / "chess_prep" / "__main__.py"
        with tempfile.TemporaryDirectory() as tmp:
            env = {**os.environ, "CHESS_PREP_ROSTER": str(Path(tmp) / "r.json")}
            proc = subprocess.run(
                [sys.executable, str(entry)],
                input=json.dumps(
                    {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
                )
                + "\n",
                capture_output=True,
                text=True,
                timeout=60,
                env=env,
            )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        response = json.loads(proc.stdout.splitlines()[0])
        self.assertGreater(len(response["result"]["tools"]), 5)


class LiveUscf(unittest.TestCase):
    """Only with --live: hits the real US Chess API."""

    def test_known_member_has_online_ratings(self):
        from chess_prep import uscf

        # Verified 2026-08-06: this player holds Online-Quick ratings.
        info = uscf.member("16009740")
        self.assertEqual(info["uscf_id"], "16009740")
        self.assertTrue(info["mappable"])
        self.assertTrue(info["online_ratings"])


if __name__ == "__main__":
    live = "--live" in sys.argv
    if live:
        sys.argv.remove("--live")
    else:
        del LiveUscf.test_known_member_has_online_ratings
    unittest.main(verbosity=2)
