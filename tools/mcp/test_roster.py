#!/usr/bin/env python3
"""Tests for tournament-roster prep: `chess_prep.roster` and
`chess_prep.opponents`.

These are the two modules that decide *who is on the list* and *which of them
prep is allowed to run against*. The dangerous direction is a false positive —
an unconfirmed guess that quietly becomes an actionable identity, or a rating
that reads as a number when it is really junk — so most of what is pinned here
is a refusal rather than an acceptance.

Zero dependencies (unittest only), and nothing under test opens a socket.

Run:
    python tools/mcp/test_roster.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep.opponents import (  # noqa: E402
    FORMAT,
    opponents_document,
    write_opponents,
)
from chess_prep.roster import (  # noqa: E402
    CSV_HEADER,
    Roster,
    RosterEntry,
    clean_uscf_id,
    load_roster,
    parse_entry_list,
    parse_name_cell,
    parse_rating,
    roster_to_csv,
    save_roster,
)


def parse(text: str, **kw) -> Roster:
    """The roster only, for cases where the warnings are not the point."""
    return parse_entry_list(text, **kw)[0]


# ── Rating parsing ──────────────────────────────────────────────────────────


class RatingParsing(unittest.TestCase):
    def test_plain_rating(self):
        self.assertEqual(parse_rating("1850"), 1850)
        self.assertEqual(parse_rating("  1850  "), 1850)

    def test_range_boundaries_are_exact(self):
        # Below 100 and above 3200 are not ratings; the edges themselves are.
        self.assertIsNone(parse_rating("99"))
        self.assertEqual(parse_rating("100"), 100)
        self.assertEqual(parse_rating("3200"), 3200)
        self.assertIsNone(parse_rating("3201"))

    def test_wrong_digit_counts_are_rejected(self):
        self.assertIsNone(parse_rating("12345"))  # too long for the pattern
        self.assertIsNone(parse_rating("9"))

    def test_provisional_and_annotated_forms(self):
        # US Chess writes provisional ratings four different ways, and the
        # event page appends a bracketed note.
        for raw in ("1850P12", "1850p3", "1850/12", "1850*", "1850 P12"):
            self.assertEqual(parse_rating(raw), 1850, raw)
        self.assertEqual(parse_rating("2000 [EQ]"), 2000)
        self.assertEqual(parse_rating("1900 [EQ] "), 1900)

    def test_unrated_markers_read_as_no_rating(self):
        for raw in ("Unr", "unrated", "UNRATED", "none", "nr", "N/A", "", "   "):
            self.assertIsNone(parse_rating(raw), raw)

    def test_junk_is_rejected_rather_than_partially_read(self):
        # Every one of these contains digits a sloppier parser would salvage.
        for raw in ("banana", "1,850", "1850.5", "-1850", "+1850", "1850 (prov)"):
            self.assertIsNone(parse_rating(raw), raw)

    def test_a_junk_rating_warns_but_an_unrated_marker_does_not(self):
        _, junk, _ = parse_entry_list("Name,Rating\nAlice,banana\n")
        self.assertEqual(len(junk), 1)
        self.assertIn("banana", junk[0])

        _, unrated, _ = parse_entry_list("Name,Rating\nAlice,Unr\n")
        self.assertEqual(unrated, [])

        _, blank, _ = parse_entry_list("Name,Rating\nAlice,\n")
        self.assertEqual(blank, [])

    def test_a_missing_rating_column_is_called_out(self):
        _, warnings, _ = parse_entry_list("Name,Section\nAlice,Open\n")
        self.assertTrue(
            any("rating column" in w for w in warnings), warnings
        )


# ── USCF ID parsing ─────────────────────────────────────────────────────────


class UscfIdParsing(unittest.TestCase):
    def test_strips_the_federation_bracket(self):
        self.assertEqual(clean_uscf_id("30997160 [USA]"), "30997160")
        self.assertEqual(clean_uscf_id("566023718 [USA]"), "566023718")

    def test_length_gate_is_exact(self):
        self.assertIsNone(clean_uscf_id("123456"))  # 6
        self.assertEqual(clean_uscf_id("1234567"), "1234567")  # 7
        self.assertEqual(clean_uscf_id("123456789"), "123456789")  # 9
        self.assertIsNone(clean_uscf_id("1234567890"))  # 10

    def test_separators_inside_an_id_are_absorbed(self):
        self.assertEqual(clean_uscf_id("16-009-740"), "16009740")
        self.assertEqual(clean_uscf_id("  16009740  "), "16009740")

    def test_no_digits_is_no_id(self):
        for raw in ("", "   ", "abc", "[USA]", "Unr"):
            self.assertIsNone(clean_uscf_id(raw), raw)

    def test_a_cell_that_is_mostly_not_an_id_is_rejected(self):
        # Digits from a trailing expiry would run the length past 9.
        self.assertIsNone(clean_uscf_id("16009740 exp 2026-12"))

    def test_a_parenthesised_note_is_dropped_not_absorbed(self):
        # REGRESSION: sweeping up every digit in the cell turned this into
        # "12345672" — a valid-looking ID belonging to a different member,
        # which resolves at `exact` confidence from a trusted source and is
        # therefore actionable. One sloppy cell was enough to download a
        # stranger's games as an entrant's.
        self.assertEqual(clean_uscf_id("1234567 (2)"), "1234567")
        self.assertEqual(clean_uscf_id("1234567 (Withdrawn)"), "1234567")
        self.assertEqual(clean_uscf_id("(2) 1234567"), "1234567")

    def test_a_cell_holding_two_numbers_is_refused_rather_than_joined(self):
        # REGRESSION: each of these used to be concatenated into a different
        # member's ID. Refusing is the only safe answer to an ambiguous cell.
        for raw in ("1234567 8", "1234567/8", "16 009 740", "1234567 7654321"):
            self.assertIsNone(clean_uscf_id(raw), raw)

    def test_only_grouping_separators_come_out_of_the_token(self):
        # "16-009-740" is one ID written with separators; "1234567/8" is two
        # numbers. The dash and the space are grouping, the slash is not.
        self.assertEqual(clean_uscf_id("16-009-740"), "16009740")
        self.assertIsNone(clean_uscf_id("1234567/8"))
        self.assertIsNone(clean_uscf_id("1234567a"))

    def test_non_ascii_digits_are_not_a_member_id(self):
        self.assertIsNone(clean_uscf_id("１６００９７４０"))

    def test_a_fabricated_id_never_reaches_an_entry(self):
        # The end-to-end shape of the same bug: the parser must not hand this
        # entrant an id that belongs to somebody else.
        (entry,) = parse("Name,USCF ID,Rating\nAlice,1234567 8,1700\n").entries
        self.assertIsNone(entry.uscf_id)
        self.assertNotEqual(entry.id, "12345678")


# ── The name cell ───────────────────────────────────────────────────────────


class NameCellParsing(unittest.TestCase):
    def test_splits_title_and_withdrawal_out_of_the_name(self):
        self.assertEqual(
            parse_name_cell("Tereshchenko, Eliza (WCM) (Withdrawn)"),
            ("Tereshchenko, Eliza", "WCM", True),
        )

    def test_marker_order_and_case_do_not_matter(self):
        self.assertEqual(
            parse_name_cell("Smith, John (Withdrawn) (im)"),
            ("Smith, John", "IM", True),
        )
        self.assertEqual(
            parse_name_cell("(WITHDRAWN) Smith, John"),
            ("Smith, John", None, True),
        )

    def test_an_unknown_parenthetical_is_left_alone(self):
        # Better to keep a note in the name than to guess it is a title.
        self.assertEqual(
            parse_name_cell("Smith, John (X)"), ("Smith, John (X)", None, False)
        )

    def test_a_plain_name_is_untouched(self):
        self.assertEqual(parse_name_cell("Bernal, Andrew"), ("Bernal, Andrew", None, False))

    def test_markers_survive_the_entry_list(self):
        roster = parse(
            "Player's Name\tUSCF ID\tUSCF Rating\n"
            "Tereshchenko, Eliza (WCM) (Withdrawn)\t33203591\t2000 [EQ]\n"
        )
        (entry,) = roster.entries
        self.assertEqual(entry.name, "Tereshchenko, Eliza")
        self.assertEqual(entry.title, "WCM")
        self.assertTrue(entry.withdrawn)
        self.assertEqual(entry.rating, 2000)


# ── Degenerate input ────────────────────────────────────────────────────────


class DegenerateInput(unittest.TestCase):
    def test_empty_input(self):
        for text in ("", "   ", "\n\n\t\n"):
            roster, warnings, fmt = parse_entry_list(text)
            self.assertEqual(roster.entries, [], text)
            self.assertEqual(warnings, ["Entry list was empty."], text)
            self.assertEqual(fmt, "text")

    def test_one_player(self):
        roster = parse("Name,Rating\nAlice Brown,1700\n")
        self.assertEqual(len(roster.entries), 1)
        self.assertEqual(roster.entries[0].rating, 1700)
        self.assertIsNone(roster.me)
        self.assertEqual(roster.sections, [])

    def test_rows_with_no_name_are_dropped_without_inventing_an_entrant(self):
        roster = parse("Name,Rating\nAlice,1700\n,1800\n  ,1900\n")
        self.assertEqual([e.name for e in roster.entries], ["Alice"])

    def test_a_roster_with_no_reference_player_has_no_me(self):
        roster = parse("Name,Rating\nAlice,1700\nBob,1600\n")
        self.assertIsNone(roster.me)

    def test_find_misses_cleanly(self):
        roster = parse("Name,Rating\nAlice,1700\n")
        self.assertIsNone(roster.find("nobody"))
        self.assertIsNone(roster.find(""))

    def test_sections_are_listed_once_in_first_seen_order(self):
        roster = parse(
            "Name,Section,Rating\nA,Open,1900\nB,U1800,1700\nC,Open,1600\n"
        )
        self.assertEqual(roster.sections, ["Open", "U1800"])


# ── Ids: dedup, stability, determinism ──────────────────────────────────────


class EntryIds(unittest.TestCase):
    def test_roster_order_is_input_order(self):
        roster = parse("Name,Rating\nZed,1000\nAmy,2000\nBob,1500\n")
        self.assertEqual([e.name for e in roster.entries], ["Zed", "Amy", "Bob"])

    def test_two_entrants_with_the_same_name_keep_distinct_ids(self):
        roster = parse("Alice Brown 1700\nAlice Brown 1500\n")
        ids = [e.id for e in roster.entries]
        self.assertEqual(len(set(ids)), 2, ids)
        # Both survive: an entry list really can hold two people of one name.
        self.assertEqual([e.rating for e in roster.entries], [1700, 1500])

    def test_a_duplicated_uscf_id_is_kept_and_warned_about(self):
        roster, warnings, _ = parse_entry_list(
            "Name,USCF ID,Rating\nAlice,12345678,1700\nBob,12345678,1800\n"
        )
        ids = [e.id for e in roster.entries]
        self.assertEqual(len(set(ids)), 2, ids)
        self.assertEqual(ids[0], "12345678")
        self.assertTrue(any("12345678" in w for w in warnings), warnings)
        # Both entrants still carry the real USCF ID they were listed under.
        self.assertEqual([e.uscf_id for e in roster.entries], ["12345678"] * 2)

    def test_no_warning_when_ids_are_distinct(self):
        _, warnings, _ = parse_entry_list(
            "Name,USCF ID,Rating\nAlice,12345678,1700\nBob,87654321,1800\n"
        )
        self.assertEqual(warnings, [])

    def test_names_with_no_ascii_still_get_unique_ids(self):
        roster = parse("Name,Rating\nСмирнов Иван,1800\nПетров Пётр,1700\n")
        ids = [e.id for e in roster.entries]
        self.assertEqual(len(set(ids)), 2, ids)
        self.assertTrue(all(i for i in ids), ids)

    def test_parsing_is_deterministic(self):
        text = "Name,USCF ID,Rating\nZed,,1000\nAmy,12345678,2000\nZed,,1500\n"
        first = parse(text).to_dict()
        second = parse(text).to_dict()
        self.assertEqual(first, second)


# ── Marking the user ────────────────────────────────────────────────────────


class SelfMarking(unittest.TestCase):
    LIST = 'Name,USCF ID,Rating\n"Bernal, Andrew",16009740,1977\nAlice,11111111,1700\n'

    def test_by_uscf_id(self):
        roster, warnings, _ = parse_entry_list(self.LIST, my_uscf_id="16009740")
        self.assertEqual(roster.me.name, "Bernal, Andrew")
        self.assertEqual(warnings, [])

    def test_by_name_ignoring_case_and_padding(self):
        roster = parse(self.LIST, my_name="  bernal, ANDREW ")
        self.assertEqual(roster.me.uscf_id, "16009740")

    def test_exactly_one_entrant_is_marked(self):
        roster = parse(self.LIST, my_uscf_id="16009740")
        self.assertEqual([e.is_me for e in roster.entries].count(True), 1)

    def test_the_name_may_be_given_in_either_ordering(self):
        # REGRESSION: this compared raw strings, so the natural spelling of
        # your own name missed the entry list's "Last, First" and left the
        # roster with no reference point for any pairing probability.
        for spelling in ("Andrew Bernal", "andrew  bernal", "Andrew Bernal Jr."):
            roster, warnings, _ = parse_entry_list(self.LIST, my_name=spelling)
            self.assertIsNotNone(roster.me, spelling)
            self.assertEqual(roster.me.uscf_id, "16009740", spelling)
            self.assertEqual(warnings, [], spelling)

    def test_a_given_name_alone_is_not_enough_to_claim_an_entrant(self):
        # The fallback normalizes, it does not guess: "Andrew" keys as a
        # surname and must not seize "Bernal, Andrew".
        roster, warnings, _ = parse_entry_list(self.LIST, my_name="Andrew")
        self.assertIsNone(roster.me)
        self.assertTrue(warnings)

    def test_a_miss_warns_and_marks_nobody(self):
        roster, warnings, _ = parse_entry_list(self.LIST, my_uscf_id="99999999")
        self.assertIsNone(roster.me)
        self.assertTrue(any("99999999" in w for w in warnings), warnings)

    def test_a_near_miss_does_not_grab_the_wrong_person(self):
        # "Alice" is on the list; "Alicia" is not, and must not be mistaken
        # for her — being wrong about which entrant is you poisons every
        # pairing probability that follows.
        roster, warnings, _ = parse_entry_list(self.LIST, my_name="Alicia")
        self.assertIsNone(roster.me)
        self.assertTrue(warnings)

    def test_no_reference_player_asked_for_means_no_warning(self):
        _, warnings, _ = parse_entry_list(self.LIST)
        self.assertEqual(warnings, [])


# ── Actionability: the gate that protects the export ────────────────────────


def entry_with(identity: dict | None) -> RosterEntry:
    return RosterEntry(id="p", name="P", identity=identity)


class Actionability(unittest.TestCase):
    def test_an_account_is_needed(self):
        self.assertFalse(entry_with(None).has_account)
        self.assertFalse(entry_with({}).has_account)
        self.assertFalse(entry_with({"chesscom_username": ""}).has_account)
        self.assertTrue(entry_with({"chesscom_username": "u"}).has_account)
        self.assertTrue(entry_with({"lichess_username": "u"}).has_account)

    def test_only_exact_and_high_confidence_are_actionable(self):
        for confidence, expected in (
            ("exact", True),
            ("high", True),
            ("medium", False),
            ("low", False),
            ("ambiguous", False),
            ("", False),
        ):
            entry = entry_with(
                {
                    "chesscom_username": "u",
                    "confidence": confidence,
                    "source": "manual",
                }
            )
            self.assertIs(entry.is_actionable, expected, confidence)

    def test_only_trusted_sources_are_actionable(self):
        for source, expected in (
            ("uscf_online_event", True),
            ("self_declared", True),
            ("manual", True),
            ("agent_proposed", False),
            ("web_search", False),
            ("", False),
        ):
            entry = entry_with(
                {"chesscom_username": "u", "confidence": "exact", "source": source}
            )
            self.assertIs(entry.is_actionable, expected, source)

    def test_alternates_veto_even_a_perfect_looking_identity(self):
        entry = entry_with(
            {
                "chesscom_username": "u",
                "confidence": "exact",
                "source": "manual",
                "alternates": ["someone_else"],
            }
        )
        self.assertTrue(entry.has_account)
        self.assertFalse(entry.is_actionable)

    def test_an_account_alone_is_not_enough(self):
        self.assertFalse(entry_with({"chesscom_username": "u"}).is_actionable)


class IdentityColumns(unittest.TestCase):
    """A username column with no provenance is the user's own assertion; one
    that carries provenance is whatever that provenance says it is."""

    def test_a_hand_made_list_is_trusted(self):
        (entry,) = parse("Name,chess.com\nAlice,ali\n").entries
        self.assertEqual(entry.identity["chesscom_username"], "ali")
        self.assertEqual(entry.identity["source"], "manual")
        self.assertEqual(entry.identity["confidence"], "exact")
        self.assertTrue(entry.is_actionable)

    def test_lichess_alone_works_the_same_way(self):
        (entry,) = parse("Name,lichess\nAlice,ali_li\n").entries
        self.assertEqual(entry.identity["lichess_username"], "ali_li")
        self.assertNotIn("chesscom_username", entry.identity)
        self.assertTrue(entry.is_actionable)

    def test_no_username_means_no_identity_at_all(self):
        (entry,) = parse("Name,chess.com,lichess\nAlice,,\n").entries
        self.assertIsNone(entry.identity)

    def test_stated_provenance_wins_over_the_trusting_default(self):
        (entry,) = parse(
            "Name,chess.com,Confidence,Source,Evidence\n"
            "Alice,ali,low,agent_proposed,a hunch\n"
        ).entries
        self.assertEqual(entry.identity["confidence"], "low")
        self.assertEqual(entry.identity["source"], "agent_proposed")
        self.assertEqual(entry.identity["evidence"], "a hunch")
        self.assertFalse(entry.is_actionable)

    def test_half_a_provenance_cannot_launder_a_guess(self):
        # Supplying only one of the two columns must not leave the other on
        # its trusting default — that would be a one-column laundry.
        confidence_only = parse(
            "Name,chess.com,Confidence\nAlice,ali,exact\n"
        ).entries[0]
        self.assertEqual(confidence_only.identity["source"], "")
        self.assertFalse(confidence_only.is_actionable)

        source_only = parse("Name,chess.com,Source\nAlice,ali,manual\n").entries[0]
        self.assertEqual(source_only.identity["confidence"], "")
        self.assertFalse(source_only.is_actionable)


# ── CSV export ──────────────────────────────────────────────────────────────


class CsvExport(unittest.TestCase):
    def test_header_is_the_documented_one(self):
        text = roster_to_csv(Roster())
        self.assertEqual(text.splitlines()[0].split(","), CSV_HEADER)

    def test_a_name_containing_a_comma_survives_a_round_trip(self):
        roster = parse('Name,USCF ID,Rating\n"Bernal, Andrew",16009740,1977\n')
        back = parse(roster_to_csv(roster))
        (entry,) = back.entries
        self.assertEqual(entry.name, "Bernal, Andrew")
        self.assertEqual(entry.uscf_id, "16009740")
        self.assertEqual(entry.rating, 1977)

    def test_an_unrated_entrant_round_trips_without_a_warning(self):
        roster = parse("Name,Rating\nAlice,\n")
        back, warnings, _ = parse_entry_list(roster_to_csv(roster))
        self.assertIsNone(back.entries[0].rating)
        self.assertEqual(warnings, [])

    def test_section_and_title_survive(self):
        roster = parse("Name,Section,Title,Rating\nAlice,Open,WIM,1700\n")
        (entry,) = parse(roster_to_csv(roster)).entries
        self.assertEqual(entry.section, "Open")
        self.assertEqual(entry.title, "WIM")

    def test_a_guess_stays_a_guess(self):
        roster = Roster(
            entries=[
                RosterEntry(
                    id="p",
                    name="Alice",
                    identity={
                        "chesscom_username": "ali",
                        "confidence": "low",
                        "source": "agent_proposed",
                        "evidence": 'Bio said "CT", which matches.',
                    },
                )
            ]
        )
        (entry,) = parse(roster_to_csv(roster)).entries
        self.assertEqual(entry.identity["source"], "agent_proposed")
        self.assertEqual(entry.identity["confidence"], "low")
        self.assertIn("CT", entry.identity["evidence"])
        self.assertFalse(
            entry.is_actionable,
            "a round trip must not launder a guess into a trusted identity",
        )

    def test_a_confirmed_identity_stays_confirmed(self):
        roster = Roster(
            entries=[
                RosterEntry(
                    id="p",
                    name="Alice",
                    identity={
                        "chesscom_username": "ali",
                        "confidence": "exact",
                        "source": "manual",
                        "evidence": "Confirmed by the user",
                    },
                )
            ]
        )
        (entry,) = parse(roster_to_csv(roster)).entries
        self.assertTrue(entry.is_actionable)

    def test_an_empty_roster_exports_just_the_header(self):
        self.assertEqual(roster_to_csv(Roster()).splitlines(), [",".join(CSV_HEADER)])


# ── Model serialization ─────────────────────────────────────────────────────


class Serialization(unittest.TestCase):
    def test_defaults_are_omitted(self):
        self.assertEqual(RosterEntry(id="x", name="X").to_dict(), {"id": "x", "name": "X"})

    def test_non_defaults_are_written_and_byes_are_sorted(self):
        out = RosterEntry(
            id="x", name="X", attendance_prob=0.5, half_point_byes=[3, 1], withdrawn=True
        ).to_dict()
        self.assertEqual(out["attendance_prob"], 0.5)
        self.assertEqual(out["half_point_byes"], [1, 3])
        self.assertTrue(out["withdrawn"])

    def test_id_falls_back_to_the_uscf_id_then_the_name(self):
        self.assertEqual(RosterEntry.from_dict({"uscf_id": "123", "name": "N"}).id, "123")
        self.assertEqual(RosterEntry.from_dict({"name": "N"}).id, "N")
        self.assertEqual(RosterEntry.from_dict({}).id, "")

    def test_roster_defaults(self):
        roster = Roster.from_dict({})
        self.assertEqual(roster.rounds, 5)
        self.assertFalse(roster.accelerated)
        self.assertEqual(roster.entries, [])

    def test_round_trip_is_lossless(self):
        roster = parse(
            "Name,USCF ID,Rating,Section,chess.com\n"
            "Alice,12345678,1700,Open,ali\n"
            "Bob,,,U1800,\n",
            event_name="Spring Open",
            rounds=7,
            accelerated=True,
        )
        self.assertEqual(Roster.from_dict(roster.to_dict()).to_dict(), roster.to_dict())


class Persistence(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        os.environ["CHESS_PREP_ROSTER"] = str(self.root / "nested" / "roster.json")

    def tearDown(self):
        os.environ.pop("CHESS_PREP_ROSTER", None)
        self._dir.cleanup()

    def test_missing_file_loads_as_an_empty_roster(self):
        self.assertEqual(load_roster().to_dict(), Roster().to_dict())

    def test_save_creates_the_directory_and_round_trips(self):
        roster = parse("Name,Rating\nAlice,1700\n", event_name="Spring Open", rounds=9)
        path = save_roster(roster)
        self.assertTrue(path.exists())
        self.assertEqual(load_roster().to_dict(), roster.to_dict())
        self.assertEqual(load_roster().event_name, "Spring Open")
        self.assertEqual(load_roster().rounds, 9)

    def test_no_temporary_file_is_left_behind(self):
        save_roster(parse("Name,Rating\nAlice,1700\n"))
        leftovers = [p.name for p in (self.root / "nested").iterdir() if p.suffix == ".tmp"]
        self.assertEqual(leftovers, [])

    def test_a_corrupt_roster_does_not_wedge_the_server(self):
        path = Path(os.environ["CHESS_PREP_ROSTER"])
        path.parent.mkdir(parents=True, exist_ok=True)
        for junk in ("{ not json", "", "   ", '{"entries": 3}', '{"rounds": "many"}'):
            path.write_text(junk)
            self.assertEqual(load_roster().entries, [], junk)

    def test_valid_json_that_is_not_a_roster_does_not_wedge_it_either(self):
        # REGRESSION: these parse as JSON, so they got past the decode guard
        # and blew up on `.get` — an AttributeError out of load_roster takes
        # every roster tool with it, which is exactly what the guard exists
        # to prevent.
        path = Path(os.environ["CHESS_PREP_ROSTER"])
        path.parent.mkdir(parents=True, exist_ok=True)
        for junk in ("[]", "null", "3", '"hi"', "[1, 2]", "true"):
            path.write_text(junk)
            self.assertEqual(load_roster().to_dict(), Roster().to_dict(), junk)

    def test_a_roster_whose_entries_are_not_objects(self):
        path = Path(os.environ["CHESS_PREP_ROSTER"])
        path.parent.mkdir(parents=True, exist_ok=True)
        for junk in ('{"entries": ["x"]}', '{"entries": [null]}', '{"entries": "abc"}'):
            path.write_text(junk)
            self.assertEqual(load_roster().entries, [], junk)

    def test_a_good_roster_still_loads_after_all_that(self):
        saved = parse("Name,Rating\nAlice,1700\n")
        save_roster(saved)
        self.assertEqual([e.name for e in load_roster().entries], ["Alice"])

    def test_a_second_save_replaces_rather_than_appends(self):
        save_roster(parse("Name,Rating\nAlice,1700\nBob,1600\n"))
        save_roster(parse("Name,Rating\nCarol,1500\n"))
        loaded = load_roster()
        self.assertEqual([e.name for e in loaded.entries], ["Carol"])


# ── The opponent list ───────────────────────────────────────────────────────

CONFIRMED = {"chesscom_username": "u", "confidence": "exact", "source": "manual"}


def opponent(name: str, **kw) -> RosterEntry:
    kw.setdefault("identity", dict(CONFIRMED))
    return RosterEntry(id=name, name=name, **kw)


class OpponentsExport(unittest.TestCase):
    def test_document_shape(self):
        doc, _ = opponents_document(
            Roster(event_name="Spring Open", rounds=7, entries=[opponent("A")])
        )
        self.assertEqual(doc["format"], FORMAT)
        self.assertEqual(doc["event"], "Spring Open")
        self.assertEqual(doc["rounds"], 7)
        self.assertEqual([o["name"] for o in doc["opponents"]], ["A"])

    def test_an_empty_roster_exports_an_empty_list_not_an_error(self):
        doc, skipped = opponents_document(Roster())
        self.assertEqual(doc["opponents"], [])
        self.assertEqual(skipped, [])

    def test_a_row_carries_only_the_facts_it_has(self):
        (row,) = opponents_document(
            Roster(entries=[opponent("A", rating=1900, uscf_id="12345678", title="FM")])
        )[0]["opponents"]
        self.assertEqual(
            row,
            {
                "name": "A",
                "chesscom": "u",
                "rating": 1900,
                "title": "FM",
                "uscf_id": "12345678",
                "identity": {"confidence": "exact", "source": "manual"},
            },
        )

    def test_me_and_the_withdrawn_are_dropped_silently(self):
        roster = Roster(
            entries=[
                opponent("me", is_me=True),
                opponent("gone", withdrawn=True),
                opponent("real"),
            ]
        )
        doc, skipped = opponents_document(roster)
        self.assertEqual([o["name"] for o in doc["opponents"]], ["real"])
        self.assertEqual(skipped, [], "these two are not a problem to report")

    def test_missing_and_unconfirmed_accounts_are_reported_with_a_reason(self):
        roster = Roster(
            entries=[
                opponent("no_account", identity=None),
                opponent(
                    "guessed",
                    identity={
                        "chesscom_username": "g",
                        "confidence": "medium",
                        "source": "uscf_online_event",
                    },
                ),
            ]
        )
        doc, skipped = opponents_document(roster)
        self.assertEqual(doc["opponents"], [])
        reasons = {s["name"]: s["reason"] for s in skipped}
        self.assertIn("no account", reasons["no_account"])
        self.assertIn("not confirmed", reasons["guessed"])

    def test_include_unconfirmed_lets_the_guess_through_but_not_the_missing(self):
        roster = Roster(
            entries=[
                opponent("no_account", identity=None),
                opponent(
                    "guessed",
                    identity={
                        "chesscom_username": "g",
                        "confidence": "medium",
                        "source": "uscf_online_event",
                    },
                ),
            ]
        )
        doc, skipped = opponents_document(roster, include_unconfirmed=True)
        self.assertEqual([o["name"] for o in doc["opponents"]], ["guessed"])
        self.assertEqual([s["name"] for s in skipped], ["no_account"])

    def test_sorted_by_pairing_probability_descending(self):
        roster = Roster(
            entries=[
                opponent("low", pairing={"prob_any": 0.1}),
                opponent("high", pairing={"prob_any": 0.9}),
                opponent("mid", pairing={"prob_any": 0.5}),
            ]
        )
        doc, _ = opponents_document(roster)
        self.assertEqual([o["name"] for o in doc["opponents"]], ["high", "mid", "low"])

    def test_unsimulated_entrants_go_last_in_roster_order(self):
        roster = Roster(
            entries=[
                opponent("none_a"),
                opponent("simulated", pairing={"prob_any": 0.2}),
                opponent("none_b"),
            ]
        )
        doc, _ = opponents_document(roster)
        self.assertEqual(
            [o["name"] for o in doc["opponents"]], ["simulated", "none_a", "none_b"]
        )

    def test_ordering_is_stable_for_ties(self):
        roster = Roster(
            entries=[opponent(n, pairing={"prob_any": 0.4}) for n in ("c", "a", "b")]
        )
        doc, _ = opponents_document(roster)
        self.assertEqual([o["name"] for o in doc["opponents"]], ["c", "a", "b"])

    def test_min_prob_is_inclusive_at_the_threshold(self):
        roster = Roster(
            entries=[
                opponent("at", pairing={"prob_any": 0.50}),
                opponent("under", pairing={"prob_any": 0.49}),
                opponent("over", pairing={"prob_any": 0.51}),
            ]
        )
        doc, skipped = opponents_document(roster, min_prob=0.5)
        self.assertEqual([o["name"] for o in doc["opponents"]], ["over", "at"])
        self.assertEqual([s["name"] for s in skipped], ["under"])
        self.assertIn("0.49", skipped[0]["reason"])

    def test_min_prob_names_the_unsimulated_separately(self):
        roster = Roster(entries=[opponent("nosim")])
        _, skipped = opponents_document(roster, min_prob=0.5)
        self.assertIn("pairing_simulate", skipped[0]["reason"])

    def test_min_prob_zero_keeps_everything_including_a_zero(self):
        roster = Roster(entries=[opponent("zero", pairing={"prob_any": 0.0})])
        doc, skipped = opponents_document(roster, min_prob=0.0)
        self.assertEqual([o["name"] for o in doc["opponents"]], ["zero"])
        self.assertEqual(skipped, [])

    def test_pairing_split_is_carried_through(self):
        roster = Roster(
            entries=[
                opponent(
                    "A",
                    pairing={
                        "prob_any": 0.4,
                        "prob_as_white": 0.25,
                        "prob_as_black": 0.15,
                        "most_likely_round": 3,
                    },
                )
            ]
        )
        (row,) = opponents_document(roster)[0]["opponents"]
        self.assertEqual(row["pairing_prob"], 0.4)
        self.assertEqual(row["pairing_prob_white"], 0.25)
        self.assertEqual(row["pairing_prob_black"], 0.15)
        self.assertEqual(row["most_likely_round"], 3)

    def test_write_is_atomic_json_and_leaves_no_temporary(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "nested" / "opponents.json"
            doc, _ = opponents_document(Roster(event_name="E", entries=[opponent("A")]))
            written = write_opponents(doc, target)
            self.assertEqual(written, target)
            self.assertEqual(json.loads(target.read_text()), doc)
            self.assertEqual([p.name for p in target.parent.iterdir()], ["opponents.json"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
