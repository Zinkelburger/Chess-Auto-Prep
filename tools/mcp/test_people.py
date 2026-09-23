#!/usr/bin/env python3
"""Tests for name spellings, the players directory and player lookup.

    python tools/mcp/test_people.py

Offline: US Chess and the account probes are stubbed, TWIC is a tiny
SQLite file with the app's schema, and the players directory lives in a
temp dir (CHESS_PREP_PEOPLE_DIR).
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep import player_lookup, uscf
from chess_prep.master_games import MasterGamesDb
from chess_prep.names import handle_guesses, name_match, same_person_name, twic_forms
from chess_prep.people import PeopleStore, TournamentStore
from chess_prep.tools import Registry, ToolError

_SCHEMA = """
CREATE TABLE games(id INTEGER PRIMARY KEY, twic INTEGER, event TEXT, site TEXT,
  date TEXT, round TEXT, white TEXT, black TEXT, result TEXT, white_elo INTEGER,
  black_elo INTEGER, white_fide INTEGER, black_fide INTEGER, eco TEXT,
  ply_count INTEGER, movetext BLOB);
CREATE TABLE meta(key TEXT PRIMARY KEY, value BLOB NOT NULL);
CREATE TABLE twic_issues(issue INTEGER PRIMARY KEY, games INTEGER, imported_at INTEGER);
"""


def _make_twic(path: Path) -> None:
    c = sqlite3.connect(path)
    c.executescript(_SCHEMA)
    rows = [
        # (white, black, date, welo, belo, wfide, bfide)
        ("Shmeliov,D", "Erenburg,S", "2026.06.29", 2338, 2600, 14115433, 2000001),
        ("Kaidanov,G", "Shmeliov,D", "2025.03.01", 2550, 2350, 2000002, 14115433),
        ("Shmeliov,Denis", "Kaidanov,G", "2022.01.01", 2360, 2550, 14115433, 2000002),
        ("Zhou Jianchao", "Harikrishnan,A", "2026.09.07", 2574, 2690, 8603537, 5007003),
        ("Zhou,Jingyi", "Someone,X", "2026.08.01", 1876, 1900, 8615322, 2000003),
        ("Zhu,Jiner", "Someone,X", "2026.09.21", 2550, 1900, 8608059, 2000003),
        ("Winter,Sven", "Someone,X", "2026.05.15", 2084, 1900, 1092375, 2000003),
    ]
    for i, (w, b, d, we, be, wf, bf) in enumerate(rows, 1):
        c.execute(
            "INSERT INTO games VALUES(?,1600,'Ev','Site',?,'1',?,?,'1-0',?,?,?,?,'B90',2,?)",
            (i, d, w, b, we, be, wf, bf, zlib.compress(b"1. e4 c5")),
        )
    c.commit()
    c.close()


class Spellings(unittest.TestCase):
    def test_respelling_and_initial(self):
        self.assertEqual(name_match("Denys Shmelov", "Denis Shmeliov"), "spelling")
        self.assertEqual(name_match("Denys Shmelov", "Shmeliov,D"), "initial")
        self.assertEqual(name_match("Shmelov, Denys", "Denys Shmelov"), "exact")

    def test_surname_first_names(self):
        self.assertEqual(name_match("Jianchao Zhou", "Zhou Jianchao"), "exact")
        self.assertIsNone(name_match("Jianchao Zhou", "Zhou,Jingyi"))

    def test_short_surnames_do_not_drift(self):
        self.assertIsNone(name_match("Jianchao Zhou", "Zhu,Jiner"))

    def test_different_given_names_are_different_people(self):
        self.assertIsNone(name_match("Shea Winter", "Winter,Sven"))
        self.assertIsNone(name_match("William Schiminger", "Williams,Si"))
        self.assertFalse(same_person_name("Denys Shmelov", "Shykyravyi,Denys"))

    def test_accents_and_titles(self):
        self.assertEqual(name_match("Jianchao Zhou (GM)", "Zhou, Jianchao"), "exact")
        self.assertEqual(name_match("José Martínez", "Martinez,Jose"), "exact")

    def test_handle_guesses_and_twic_forms(self):
        self.assertEqual(handle_guesses("Derek Zhang")[:2], ["derekzhang", "zhangderek"])
        self.assertIn("Zhou,Jianchao", twic_forms("Jianchao Zhou"))
        self.assertIn("Jianchao Zhou", twic_forms("Jianchao Zhou"))


class TwicSearch(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.path = Path(self._dir.name) / "master_games.db"
        _make_twic(self.path)
        self.db = MasterGamesDb(self.path)

    def tearDown(self):
        self.db.close()
        self._dir.cleanup()

    def test_groups_every_spelling_under_one_fide_id(self):
        found = self.db.find_players(["Denys Shmelov"])
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["fide_id"], 14115433)
        self.assertEqual(sorted(found[0]["names"]), ["Shmeliov,D", "Shmeliov,Denis"])
        self.assertEqual(found[0]["games"], 3)
        self.assertEqual(found[0]["latest_elo"], 2338)

    def test_better_grades_rank_first(self):
        found = self.db.find_players(["Denys Shmelov", "Denis Shmeliov"])
        self.assertEqual(found[0]["match"], "exact")

    def test_games_by_fide_catches_all_spellings(self):
        self.assertEqual(len(self.db.games_by_fide(14115433)), 3)

    def test_master_games_tries_twic_forms(self):
        registry = Registry()
        try:
            out = registry.call(
                "master_games", {"player": "Zhou, Jianchao", "db": str(self.path)}
            )
            self.assertEqual(out["count"], 1)
            out = registry.call("master_games", {"fide_id": 14115433, "db": str(self.path)})
            self.assertEqual(out["count"], 3)
            out = registry.call(
                "master_player_search", {"name": "Denys Shmelov", "db": str(self.path)}
            )
            self.assertEqual(out["identities"][0]["fide_id"], 14115433)
        finally:
            registry.close()


class PeopleFile(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)

    def tearDown(self):
        self._dir.cleanup()

    def test_upsert_fills_blanks_and_keeps_what_the_user_typed(self):
        (self.root / "people.json").write_text(
            json.dumps(
                {
                    "format": "chess-auto-prep/people@1",
                    "saved_accounts_imported": True,
                    "people": [
                        {
                            "id": "p1",
                            "name": "Denis Shmeliov",
                            "rating": 2400,
                            "chesscom": "typed_by_user",
                            "notes": "mine",
                            "game_sets": ["k"],
                            "studies": [],
                            "future_field": 1,
                        }
                    ],
                }
            )
        )
        store = PeopleStore(self.root)
        row, status = store.upsert(
            {"name": "Denys Shmelov", "uscf_id": "13433622", "rating": 2439,
             "notes": "agent", "chesscom": ["second_account", "TYPED_BY_USER"],
             "aliases": ["Denis Shmeliov"]}
        )
        self.assertEqual(row["id"], "p1", "the alias is the user's spelling of the name")
        self.assertEqual(status, "updated")
        self.assertEqual(row["name"], "Denis Shmeliov")
        self.assertEqual(row["aliases"], ["Denys Shmelov"])
        self.assertEqual(row["rating"], 2400)
        self.assertEqual(row["notes"], "mine")
        self.assertEqual(row["chesscom"], "typed_by_user, second_account")
        self.assertEqual(row["uscf_id"], "13433622")
        store.save()

        saved = json.loads((self.root / "people.json").read_text())
        self.assertTrue(saved["saved_accounts_imported"])
        p1 = next(p for p in saved["people"] if p["id"] == "p1")
        self.assertEqual(p1["future_field"], 1)
        self.assertEqual(p1["game_sets"], ["k"])

    def test_matches_by_alias_and_fide(self):
        store = PeopleStore(self.root)
        row, _ = store.upsert({"name": "Denys Shmelov", "aliases": ["Denis Shmeliov"], "fide_id": 14115433})
        self.assertIs(store.match(names=["Shmeliov, Denis"]), row)
        self.assertIs(store.match(fide_id=14115433), row)
        self.assertEqual(store.upsert({"name": "Denys Shmelov"})[1], "unchanged")
        self.assertEqual([p["id"] for p in store.search("shmeliov")], [row["id"]])

    def test_group_keeps_prepared_ticks(self):
        groups = TournamentStore(self.root)
        path, doc, added = groups.upsert("Test Open", [{"person": "a", "rating": 2000}], rounds=5)
        self.assertEqual((doc["id"], added, doc["rounds"]), ("test-open", 1, 5))
        doc["entries"][0]["prepared"] = True
        path.write_text(json.dumps(doc))
        _, doc, added = groups.upsert("Test Open", [{"person": "a"}, {"person": "b"}])
        self.assertEqual(added, 1)
        self.assertTrue(doc["entries"][0]["prepared"])
        self.assertEqual(doc["format"], "chess-auto-prep/tournament@1")


def _fake_member(uscf_id: str) -> dict:
    names = {
        "13433622": ("Denys K Shmelov", {}),
        "14081435": ("DEREK ZHANG", {"Online-Blitz": {"rating": 2216}}),
        "30855496": ("Will Schiminger", {}),
    }
    name, online = names[uscf_id]
    return {"name": name, "online_ratings": online, "otb_ratings": {"R": {"rating": 2400}}}


def _fake_probe(spellings, *, title=None, rating=None, skip=frozenset()):
    candidates = []
    if any("Zhang" in s for s in spellings):
        candidates.append(
            {"site": "chesscom", "username": "derek_zhang", "confidence": "medium",
             "evidence": 'profile name "Derek Zhang" (exact match)', "source": "handle_probe"}
        )
    return {"tried": [], "candidates": candidates, "rejected": []}


class Populate(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        root = Path(self._dir.name)
        self.people_dir = root / "opponents"
        self.twic = root / "master_games.db"
        _make_twic(self.twic)
        self._env = mock.patch.dict(
            os.environ,
            {"CHESS_PREP_PEOPLE_DIR": str(self.people_dir),
             "CHESS_PREP_ROSTER": str(root / "roster.json")},
        )
        self._env.start()
        self._patches = [
            mock.patch.object(uscf, "member", side_effect=_fake_member),
            mock.patch.object(player_lookup, "probe_accounts", side_effect=_fake_probe),
        ]
        for p in self._patches:
            p.start()
        self.registry = Registry()
        self.registry.call(
            "roster_import",
            {
                "text": "Name\tRating\tUSCF ID\n"
                "Denys Shmelov (IM)\t2439\t13433622\n"
                "Derek Zhang\t2329\t14081435\n"
                "William Schiminger\t2052\t30855496\n",
                "event_name": "Test Open",
            },
        )

    def tearDown(self):
        self.registry.close()
        for p in self._patches:
            p.stop()
        self._env.stop()
        self._dir.cleanup()

    def test_fills_the_directory_and_says_who_is_missing(self):
        self.registry.call("roster_update", {"player_id": 13433622, "aliases": ["Denis Shmeliov"]})
        out = self.registry.call("people_populate", {"db": str(self.twic)})
        self.assertEqual(out["summary"]["account"], ["Derek Zhang"])
        self.assertEqual(out["summary"]["otb_only"], ["Denys Shmelov"])
        self.assertEqual(out["summary"]["not_found"], ["William Schiminger"])
        self.assertEqual(out["group"]["players"], 3)

        people = {p["name"]: p for p in json.loads(Path(out["people_file"]).read_text())["people"]}
        denys = people["Denys Shmelov"]
        self.assertEqual(denys["fide_id"], 14115433)
        self.assertIn("Denis Shmeliov", denys["aliases"])
        self.assertNotIn("chesscom", denys)
        derek = people["Derek Zhang"]
        self.assertEqual(derek["chesscom"], "Dare-Dare", "the directory's USCF-event match is trusted")
        self.assertEqual(
            [c["username"] for c in derek["lookup"]["candidates"]], ["derek_zhang"],
            "a probe hit waits as a candidate",
        )
        self.assertIn("Will Schiminger", people["William Schiminger"]["aliases"])

        again = self.registry.call("people_populate", {"db": str(self.twic)})
        self.assertEqual(again["group"]["added"], 0)
        self.assertEqual(len(json.loads(Path(out["people_file"]).read_text())["people"]), 3)

    def test_confirm_moves_a_candidate_into_the_downloaded_accounts(self):
        self.registry.call("people_populate", {"db": str(self.twic)})
        derek = self.registry.call("people_get", {"query": "Derek Zhang"})
        out = self.registry.call(
            "people_confirm",
            {"person_id": derek["id"], "site": "chesscom", "username": "derek_zhang"},
        )
        self.assertEqual(out["person"]["chesscom"], "Dare-Dare, derek_zhang")
        self.assertIsNone(out["person"].get("candidates"))

    def test_upsert_candidates_need_evidence(self):
        with self.assertRaises(ToolError):
            self.registry.call(
                "people_upsert",
                {"name": "Shea Winter", "candidates": [{"site": "lichess", "username": "x"}]},
            )
        out = self.registry.call(
            "people_upsert",
            {"name": "Shea Winter", "group": "Test Open",
             "candidates": [{"site": "lichess", "username": "sheaw",
                             "evidence": "Lichess bio: 'Shea Winter, Boston'"}]},
        )
        self.assertEqual(out["person"]["status"], "candidates")
        self.assertEqual(out["group"]["players"], 1)

    def test_uscf_member_accepts_a_numeric_id(self):
        out = self.registry.call("uscf_member", {"uscf_id": 30855496})
        self.assertEqual(out["name"], "Will Schiminger")


if __name__ == "__main__":
    unittest.main()
