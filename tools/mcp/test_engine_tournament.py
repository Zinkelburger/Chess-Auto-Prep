#!/usr/bin/env python3
"""Tests for the engine-tournament MCP tools.

Zero dependencies (unittest only) and no engines: everything here works on a
fabricated tournament directory, because the parts that need a real engine
live in Dart and are tested there. What is tested here is what this layer
actually owns — finding the tournament you meant, reading what is on disk,
the request file the app watches, and the registry write.

Run:
    python tools/mcp/test_engine_tournament.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep import engine_tournament as et  # noqa: E402
from chess_prep.tools import Registry, ToolError  # noqa: E402

FEN = "3r2k1/p4p2/7p/3pB1p1/8/P3P2P/1P3PP1/6K1 b - - 0 1"


def _game(index: int, result: str) -> dict:
    return {
        "gameIndex": index,
        "round": index + 1,
        "whiteIndex": index % 2,
        "blackIndex": 1 - index % 2,
        "whiteName": "Alpha" if index % 2 == 0 else "Beta",
        "blackName": "Beta" if index % 2 == 0 else "Alpha",
        "result": result,
        "termination": "resignAdjudication",
        "detail": "below -900cp for 4 moves",
        "plies": 60 + index,
        "startedAt": f"2026-08-22T12:{index:02d}:00",
        "durationMs": 120000,
    }


def _metadata(name: str, created: str, games: list[dict], status="completed") -> dict:
    return {
        "version": 1,
        "id": name,
        "createdAt": created,
        "status": status,
        "config": {
            "name": name,
            "engines": [
                {"id": "a", "name": "Alpha", "executablePath": "/bin/a"},
                {"id": "b", "name": "Beta", "executablePath": "/bin/b"},
            ],
            "startFen": FEN,
            "openingLabel": "Rook vs bishop",
            "timeControl": {"kind": "movetime", "movetimeMs": 2000},
            "gamesPerPairing": 4,
            "format": "roundRobin",
        },
        "games": games,
    }


PGN = """[Event "Match"]
[Round "1"]
[White "Alpha"]
[Black "Beta"]
[Result "0-1"]

1... Rc8 2. Bc3 0-1

[Event "Match"]
[Round "2"]
[White "Beta"]
[Black "Alpha"]
[Result "1-0"]

1... Rd7 2. Bc7 1-0
"""


class TournamentDirCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        os.environ["CHESS_PREP_TOURNAMENTS_DIR"] = str(self.root)
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "CHESS_PREP_TOURNAMENTS_DIR", None)
        self.registry = Registry()

    def write(
        self,
        name: str,
        created: str = "2026-08-22T12:00:00",
        games: list[dict] | None = None,
        status: str = "completed",
        pgn: str = PGN,
    ) -> Path:
        directory = self.root / name
        directory.mkdir(parents=True, exist_ok=True)
        (directory / et.METADATA_FILE).write_text(
            json.dumps(_metadata(name, created, games or [], status)),
            encoding="utf-8",
        )
        (directory / et.PGN_FILE).write_text(pgn, encoding="utf-8")
        return directory


class Locating(TournamentDirCase):
    def test_no_tournaments_is_a_readable_error(self):
        with self.assertRaises(ToolError) as caught:
            self.registry.call("tournament_status", {})
        self.assertIn("tournament_run", str(caught.exception))

    def test_defaults_to_the_most_recent(self):
        self.write("older", created="2026-08-01T09:00:00")
        self.write("newer", created="2026-08-20T09:00:00")
        self.assertEqual(
            self.registry.call("tournament_status", {})["id"], "newer"
        )

    def test_a_wrong_id_lists_what_exists(self):
        self.write("real-one")
        with self.assertRaises(ToolError) as caught:
            self.registry.call("tournament_status", {"id": "nope"})
        self.assertIn("real-one", str(caught.exception))

    def test_a_directory_without_metadata_is_not_a_tournament(self):
        (self.root / "stray").mkdir()
        self.write("real-one")
        listed = self.registry.call("tournament_list", {})
        self.assertEqual([t["id"] for t in listed["tournaments"]], ["real-one"])

    def test_corrupt_metadata_hides_one_row_not_the_list(self):
        self.write("good")
        bad = self.root / "bad"
        bad.mkdir()
        (bad / et.METADATA_FILE).write_text("{ not json", encoding="utf-8")
        listed = self.registry.call("tournament_list", {})
        self.assertEqual([t["id"] for t in listed["tournaments"]], ["good"])


class Reading(TournamentDirCase):
    def test_status_counts_results_and_endings(self):
        self.write(
            "match",
            games=[_game(0, "blackWins"), _game(1, "blackWins"), _game(2, "draw")],
        )
        status = self.registry.call("tournament_status", {})
        self.assertEqual(status["games_played"], 3)
        self.assertEqual(status["games_total"], 4)
        self.assertEqual(status["results"], {"blackWins": 2, "draw": 1})
        self.assertEqual(status["terminations"], {"resignAdjudication": 3})
        self.assertEqual(status["time_control"], "2s/move")
        self.assertEqual(status["start_fen"], FEN)
        self.assertFalse(status["running"])

    def test_games_are_numbered_from_one(self):
        self.write("match", games=[_game(0, "blackWins"), _game(1, "whiteWins")])
        games = self.registry.call("tournament_games", {})
        self.assertEqual([g["number"] for g in games["games"]], [1, 2])
        self.assertEqual(games["games"][0]["white"], "Alpha")
        self.assertEqual(games["games"][1]["white"], "Beta")

    def test_one_game_comes_back_whole(self):
        self.write("match")
        pgn = self.registry.call("tournament_game_pgn", {"number": 2})["pgn"]
        self.assertIn('[Round "2"]', pgn)
        self.assertIn("1-0", pgn)
        self.assertNotIn('[Round "1"]', pgn)

    def test_a_game_out_of_range_says_how_many_there_are(self):
        self.write("match")
        with self.assertRaises(ToolError) as caught:
            self.registry.call("tournament_game_pgn", {"number": 9})
        self.assertIn("2", str(caught.exception))

    def test_time_control_labels_match_the_app(self):
        self.assertEqual(
            et._time_control_label({"kind": "movetime", "movetimeMs": 2000}),
            "2s/move",
        )
        self.assertEqual(
            et._time_control_label(
                {"kind": "incremental", "baseMs": 60000, "incrementMs": 600}
            ),
            "60s+0.6s",
        )
        self.assertEqual(
            et._time_control_label(
                {
                    "kind": "incremental",
                    "baseMs": 600000,
                    "incrementMs": 10000,
                    "movesPerSession": 40,
                }
            ),
            "40/600s+10s",
        )
        self.assertEqual(
            et._time_control_label({"kind": "fixedDepth", "depth": 12}), "depth 12"
        )


class OpeningTheApp(TournamentDirCase):
    def test_writes_a_request_the_app_can_read(self):
        self.write("match")
        result = self.registry.call(
            "tournament_open", {"launch": "never"}
        )
        self.assertFalse(result["launched"])
        payload = json.loads(
            (self.root / et.OPEN_REQUEST_FILE).read_text(encoding="utf-8")
        )
        self.assertEqual(payload["tournamentId"], "match")
        self.assertIn("requestedAt", payload)

    def test_never_launches_when_told_not_to(self):
        self.write("match")
        result = self.registry.call("tournament_open", {"launch": "never"})
        self.assertFalse(result["launched"])

    def test_an_unknown_launch_mode_is_refused(self):
        self.write("match")
        with self.assertRaises(ToolError):
            self.registry.call("tournament_open", {"launch": "maybe"})


class Engines(TournamentDirCase):
    def test_the_bundled_engine_is_always_listed(self):
        listed = self.registry.call("tournament_engines", {})
        self.assertEqual(
            [e["name"] for e in listed["engines"]], ["Stockfish (bundled)"]
        )

    def test_added_engines_follow_the_bundled_one(self):
        (self.root / et.ENGINES_FILE).write_text(
            json.dumps(
                [
                    {
                        "id": "x",
                        "name": "Xiphos",
                        "executablePath": "/bin/xiphos",
                        "hashMb": 256,
                        "threads": 2,
                    }
                ]
            ),
            encoding="utf-8",
        )
        listed = self.registry.call("tournament_engines", {})
        self.assertEqual(
            [e["name"] for e in listed["engines"]],
            ["Stockfish (bundled)", "Xiphos"],
        )
        self.assertEqual(listed["engines"][1]["threads"], 2)

    def test_add_engine_needs_a_path(self):
        with self.assertRaises(ToolError):
            self.registry.call("tournament_add_engine", {})

    def test_a_rejected_binary_is_not_written_to_the_registry(self):
        calls: list[list[str]] = []

        def fake(argv, timeout):  # noqa: ANN001 - test double
            calls.append(argv)
            return {"ok": False, "message": "not a UCI engine", "transcript": []}

        original = et._dart_json
        et._dart_json = fake
        try:
            result = self.registry.call(
                "tournament_add_engine", {"path": "/bin/echo"}
            )
        finally:
            et._dart_json = original

        self.assertFalse(result["added"])
        self.assertIn("not a UCI engine", result["reason"])
        self.assertFalse((self.root / et.ENGINES_FILE).exists())
        self.assertEqual(calls[0][:2], ["--verify", "/bin/echo"])

    def test_a_verified_binary_is_added_once(self):
        def fake(argv, timeout):  # noqa: ANN001 - test double
            return {"ok": True, "name": "Toy 1.0", "author": "n", "sampleMove": "e4"}

        original = et._dart_json
        et._dart_json = fake
        try:
            first = self.registry.call(
                "tournament_add_engine", {"path": "/bin/toy"}
            )
            self.registry.call("tournament_add_engine", {"path": "/bin/toy"})
        finally:
            et._dart_json = original

        self.assertTrue(first["added"])
        self.assertEqual(first["name"], "Toy 1.0")
        entries = json.loads(
            (self.root / et.ENGINES_FILE).read_text(encoding="utf-8")
        )
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["executablePath"], "/bin/toy")


class Stopping(TournamentDirCase):
    def test_stopping_something_that_is_not_running_says_so(self):
        self.write("match")
        result = self.registry.call("tournament_stop", {})
        self.assertFalse(result["stopped"])

    def test_a_dead_pid_does_not_read_as_running(self):
        directory = self.write("match", status="running")
        # A pid that cannot exist: the file outlived the process.
        (directory / et.RUN_FILE).write_text(
            json.dumps({"pid": 2**30, "log": "/tmp/x.log"}), encoding="utf-8"
        )
        self.assertFalse(et._run_state(directory)["running"])
        self.assertFalse(self.registry.call("tournament_status", {})["running"])


class Splitting(unittest.TestCase):
    def test_a_collection_splits_on_each_event_tag(self):
        self.assertEqual(len(et._split_games(PGN)), 2)

    def test_an_empty_file_has_no_games(self):
        self.assertEqual(et._split_games(""), [])
        self.assertEqual(et._split_games("\n\n"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
