#!/usr/bin/env python3
"""Tests for the expectimax MCP tools.

No engines and no builds: the chess and the search live in `tree_builder/`
and are tested there. What is tested here is what this layer actually owns —
turning a move list into the right FEN, refusing the colour mismatch that
makes "best move for Black" ambiguous, finding the run you meant, reading a
saved tree back as a ranking, and the shape of the command line.

Requires python-chess (see tools/mcp/requirements.txt).

    python tools/mcp/test_expectimax.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep import expectimax as ex  # noqa: E402
from chess_prep.tools import Registry, ToolError  # noqa: E402

LONDON = "1. d4 Nf6 2. Nf3 g6 3. Bf4 Bg7 4. e3 d6 5. h3"
LONDON_FEN = "rnbqk2r/ppp1ppbp/3p1np1/8/3P1B2/4PN1P/PPP2PP1/RN1QKB1R b KQkq - 0 5"


def _node(move: str, value: float, cp: int, kids: list | None = None) -> dict:
    node = {
        "move_san": move,
        "move_uci": "",
        "depth": 1,
        "expectimax_value": value,
        "engine_eval_cp": cp,
        "children": kids or [],
    }
    return node


def _tree(children: list) -> dict:
    return {
        "format": "tree",
        "total_nodes": 1 + len(children),
        "max_depth": 2,
        "build_complete": False,
        "tree": {
            "depth": 0,
            "expectimax_value": 0.5263,
            "children": children,
        },
    }


class PositionTest(unittest.TestCase):
    def test_move_list_becomes_a_fen(self):
        out = ex.resolve_position(LONDON)
        self.assertEqual(out["fen"], LONDON_FEN)
        self.assertEqual(out["color"], "b")
        self.assertEqual(out["ply"], 9)
        self.assertTrue(out["line"].startswith("d4 Nf6 Nf3"))

    def test_colour_defaults_to_side_to_move(self):
        self.assertEqual(ex.resolve_position("1. d4")["color"], "b")
        self.assertEqual(ex.resolve_position("1. d4 Nf6")["color"], "w")

    def test_explicit_colour_that_matches_is_fine(self):
        self.assertEqual(ex.resolve_position(LONDON, color="black")["color"], "b")

    def test_colour_mismatch_is_refused_with_the_fix(self):
        """The mistake this exists to catch: a line written out one ply too far."""
        with self.assertRaises(ToolError) as caught:
            ex.resolve_position(LONDON + " c5", color="b")
        message = str(caught.exception)
        self.assertIn("White to move", message)
        self.assertIn("c5", message)

    def test_uci_moves_are_accepted(self):
        out = ex.resolve_position(["d2d4", "g8f6"])
        self.assertEqual(out["line"], "d4 Nf6")

    def test_illegal_move_names_where_it_went_wrong(self):
        with self.assertRaises(ToolError) as caught:
            ex.resolve_position("1. d4 Nf6 2. Qh8")
        self.assertIn("Qh8", str(caught.exception))

    def test_fen_plus_moves(self):
        out = ex.resolve_position("c5", fen=LONDON_FEN)
        self.assertEqual(out["color"], "w")
        self.assertEqual(out["line"], "c5")
        self.assertEqual(out["ply"], 1)

    def test_illegal_first_move_from_a_fen_says_which_position(self):
        with self.assertRaises(ToolError) as caught:
            ex.resolve_position("h3", fen=LONDON_FEN)
        self.assertIn("the position you gave", str(caught.exception))

    def test_bad_fen_is_reported(self):
        with self.assertRaises(ToolError):
            ex.resolve_position(None, fen="not a fen")


class RootTableTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "tree.tree.json"

    def tearDown(self):
        self.dir.cleanup()

    def _write(self, data: dict) -> Path:
        self.path.write_text(json.dumps(data), encoding="utf-8")
        return self.path

    def test_ranks_by_expectimax_not_by_eval(self):
        """c5 has the worse raw eval here and must still come first."""
        path = self._write(
            _tree(
                [
                    _node("O-O", 0.5111, 22),
                    _node("c5", 0.5263, 40),
                    _node("Nc6", 0.5040, 30),
                ]
            )
        )
        table = ex.root_table(path)
        self.assertEqual(table["best"], "c5")
        self.assertEqual([r["move"] for r in table["candidates"]][0], "c5")
        self.assertAlmostEqual(table["margin_over_second"], 0.0152, places=4)

    def test_reports_how_much_each_candidate_was_searched(self):
        deep = _node("c5", 0.53, 4, [_node("c3", 0.53, 4)])
        deep["children"][0]["depth"] = 2
        path = self._write(_tree([deep, _node("a5", 0.49, 45)]))
        rows = {r["move"]: r for r in ex.root_table(path)["candidates"]}
        self.assertEqual(rows["c5"]["nodes"], 2)
        self.assertEqual(rows["c5"]["max_ply"], 2)
        self.assertEqual(rows["a5"]["nodes"], 1)
        self.assertEqual(rows["a5"]["avg_leaf_ply"], 1.0)

    def test_unscored_candidates_sort_last(self):
        path = self._write(_tree([_node("a5", None, 45), _node("c5", 0.52, 4)]))
        table = ex.root_table(path)
        self.assertEqual(table["best"], "c5")
        self.assertIsNone(table["candidates"][-1]["expectimax"])
        self.assertIsNone(table["margin_over_second"])

    def test_empty_root_says_so(self):
        with self.assertRaises(ToolError) as caught:
            ex.root_table(self._write(_tree([])))
        self.assertIn("stopped before", str(caught.exception))

    def test_missing_tree_key(self):
        with self.assertRaises(ToolError):
            ex.root_table(self._write({"format": "tree"}))


class ArgvTest(unittest.TestCase):
    def _chain(self) -> dict:
        return {
            "builder": Path("/bin/tree_builder"),
            "stockfish": Path("/bin/stockfish"),
            "maia_model": Path("/assets/maia.onnx"),
        }

    def test_defaults(self):
        argv = ex.builder_argv(
            self._chain(), Path("/runs/x/tree"), ex.resolve_position(LONDON), {}
        )
        self.assertIn("-c", argv)
        self.assertEqual(argv[argv.index("-c") + 1], "b")
        self.assertEqual(argv[argv.index("-f") + 1], LONDON_FEN)
        self.assertEqual(argv[argv.index("-d") + 1], "8")
        self.assertEqual(argv[argv.index("--our-multipv") + 1], "5")
        self.assertEqual(argv[-1], "/runs/x/tree")

    def test_overrides_reach_the_command_line(self):
        argv = ex.builder_argv(
            self._chain(),
            Path("/runs/x/tree"),
            ex.resolve_position(LONDON),
            {"plies": 10, "eval_depth": 20, "multipv": 8, "maia_elo": 1800},
        )
        self.assertEqual(argv[argv.index("-d") + 1], "10")
        self.assertEqual(argv[argv.index("-e") + 1], "20")
        self.assertEqual(argv[argv.index("--our-multipv") + 1], "8")
        self.assertEqual(argv[argv.index("--maia-elo") + 1], "1800")

    def test_name_is_optional(self):
        chain, position = self._chain(), ex.resolve_position(LONDON)
        self.assertNotIn("-n", ex.builder_argv(chain, Path("/x"), position, {}))
        argv = ex.builder_argv(chain, Path("/x"), position, {"name": "London"})
        self.assertEqual(argv[argv.index("-n") + 1], "London")


class ArgvReuseTest(unittest.TestCase):
    """Resuming re-runs the original command line rather than `--resume`.

    The builder's `--resume` restores flags from its database, and the
    database remembers `build_now` once it has seen it — so after scoring a
    partial tree, a `--resume` build would silently never build again.
    """

    ARGV = ["/bin/tree_builder", "-c", "b", "-d", "8", "-v", "/runs/x/tree"]

    def test_flags_go_before_the_base_name(self):
        out = ex.argv_with(self.ARGV, "--build-now")
        self.assertEqual(out[-1], "/runs/x/tree")
        self.assertEqual(out[-2], "--build-now")
        self.assertNotIn("--resume", out)

    def test_plies_override_replaces_the_existing_depth(self):
        out = ex.argv_with_plies(self.ARGV, 12)
        self.assertEqual(out[out.index("-d") + 1], "12")
        self.assertEqual(out.count("-d"), 1)
        self.assertEqual(out[-1], "/runs/x/tree")

    def test_plies_override_when_there_was_no_depth_flag(self):
        out = ex.argv_with_plies(["/bin/tree_builder", "-c", "b", "/x"], 6)
        self.assertEqual(out[out.index("-d") + 1], "6")
        self.assertEqual(out[-1], "/x")


class RunDirectoryTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        os.environ["CHESS_PREP_EXPECTIMAX_DIR"] = str(self.root)

    def tearDown(self):
        os.environ.pop("CHESS_PREP_EXPECTIMAX_DIR", None)
        self.dir.cleanup()

    def _run(self, name: str, pid: int = 1, tree: dict | None = None) -> Path:
        directory = self.root / name
        directory.mkdir(parents=True, exist_ok=True)
        (directory / ex.RUN_FILE).write_text(
            json.dumps(
                {
                    "pid": pid,
                    "startedAt": "2026-09-01T13:00:00",
                    "build_argv": [
                        "/bin/tree_builder",
                        "-c",
                        "b",
                        "-d",
                        "8",
                        str(directory / ex.BASE),
                    ],
                    "position": {"line": "d4 Nf6", "color": "b", "fen": LONDON_FEN},
                }
            ),
            encoding="utf-8",
        )
        if tree is not None:
            (directory / f"{ex.BASE}.tree.json").write_text(
                json.dumps(tree), encoding="utf-8"
            )
        return directory

    def test_runs_dir_honours_the_override(self):
        self.assertEqual(ex.runs_dir(), self.root)

    def test_resolve_defaults_to_the_newest(self):
        self._run("old")
        newest = self._run("new")
        os.utime(newest, (2_000_000_000, 2_000_000_000))
        self.assertEqual(ex.resolve_id(self.root, None).name, "new")

    def test_resolve_by_prefix(self):
        self._run("london-20260901-130000")
        self.assertEqual(
            ex.resolve_id(self.root, "london").name, "london-20260901-130000"
        )

    def test_ambiguous_prefix_lists_the_candidates(self):
        self._run("london-a")
        self._run("london-b")
        with self.assertRaises(ToolError) as caught:
            ex.resolve_id(self.root, "london")
        self.assertIn("london-a", str(caught.exception))

    def test_no_runs_at_all(self):
        with self.assertRaises(ToolError) as caught:
            ex.resolve_id(self.root, None)
        self.assertIn("expectimax_run", str(caught.exception))

    def test_a_dead_pid_reads_as_not_running(self):
        directory = self._run("dead", pid=999_999_999)
        self.assertFalse(ex._read_run(directory)["running"])

    def test_status_reports_the_saved_tree(self):
        self._run("x", pid=999_999_999, tree=_tree([_node("c5", 0.52, 4)]))
        registry = Registry()
        status = registry.call("expectimax_status", {})
        self.assertEqual(status["id"], "x")
        self.assertFalse(status["running"])
        self.assertEqual(status["nodes_at_last_save"], 2)
        self.assertEqual(status["line"], "d4 Nf6")

    def test_list_is_newest_first(self):
        self._run("first", pid=999_999_999)
        second = self._run("second", pid=999_999_999)
        os.utime(second, (2_000_000_000, 2_000_000_000))
        rows = Registry().call("expectimax_list", {})["runs"]
        self.assertEqual([r["id"] for r in rows], ["second", "first"])

    def test_result_refuses_to_interrupt_when_told_not_to(self):
        self._run("live", pid=os.getpid(), tree=_tree([_node("c5", 0.52, 4)]))
        with self.assertRaises(ToolError) as caught:
            Registry().call("expectimax_result", {"stop_first": False})
        self.assertIn("still building", str(caught.exception))

    def test_result_without_a_tree_says_so(self):
        self._run("bare", pid=999_999_999)
        with self.assertRaises(ToolError) as caught:
            Registry().call("expectimax_result", {})
        self.assertIn("no tree yet", str(caught.exception))

    def test_stop_on_an_already_finished_run(self):
        self._run("done", pid=999_999_999)
        out = Registry().call("expectimax_stop", {})
        self.assertFalse(out["stopped"])
        self.assertFalse(out["running"])

    def test_run_json_survives_a_round_trip(self):
        directory = self._run("x", pid=999_999_999)
        state = ex._read_run(directory)
        self.assertEqual(state["build_argv"][0], "/bin/tree_builder")
        ex._write_run(directory, state)
        self.assertNotIn("running", json.loads((directory / ex.RUN_FILE).read_text()))

    def test_resume_refuses_while_running(self):
        self._run("live", pid=os.getpid())
        with self.assertRaises(ToolError) as caught:
            Registry().call("expectimax_resume", {})
        self.assertIn("already building", str(caught.exception))


class LivenessTest(unittest.TestCase):
    """A finished build is a zombie until reaped, and this server is the
    parent — the bug this guards is a run that ended reading as still going.
    """

    def test_a_reaped_child_is_not_alive(self):
        import subprocess

        process = subprocess.Popen([sys.executable, "-c", "pass"])
        process.wait()
        self.assertFalse(ex._pid_alive(process.pid))

    def test_an_unreaped_child_is_not_alive_either(self):
        import subprocess
        import time

        process = subprocess.Popen([sys.executable, "-c", "pass"])
        for _ in range(100):
            if process.poll() is not None:
                break
            time.sleep(0.05)
        # Deliberately not calling wait(): the process is a zombie now.
        self.assertFalse(ex._pid_alive(process.pid))
        process.wait()

    def test_this_process_is_alive(self):
        self.assertTrue(ex._pid_alive(os.getpid()))


class ScoredTreeTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "tree.tree.json"

    def tearDown(self):
        self.dir.cleanup()

    def test_a_finished_run_is_recognised_as_already_scored(self):
        self.path.write_text(
            json.dumps(_tree([_node("c5", 0.52, 4)])), encoding="utf-8"
        )
        self.assertTrue(ex._has_expectimax(self.path))

    def test_an_interrupted_tree_still_needs_scoring(self):
        data = _tree([_node("c5", None, 4)])
        data["tree"].pop("expectimax_value")
        self.path.write_text(json.dumps(data), encoding="utf-8")
        self.assertFalse(ex._has_expectimax(self.path))

    def test_unreadable_tree_is_not_scored(self):
        self.path.write_text("{ not json", encoding="utf-8")
        self.assertFalse(ex._has_expectimax(self.path))


class RegistrationTest(unittest.TestCase):
    def test_all_six_tools_are_registered(self):
        names = set(Registry().tools)
        self.assertLessEqual(
            {
                "expectimax_run",
                "expectimax_result",
                "expectimax_status",
                "expectimax_list",
                "expectimax_stop",
                "expectimax_resume",
            },
            names,
        )

    def test_schemas_are_closed(self):
        registry = Registry()
        for name, tool in registry.tools.items():
            if not name.startswith("expectimax"):
                continue
            self.assertFalse(tool["inputSchema"]["additionalProperties"], name)
            self.assertTrue(tool["description"].strip(), name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
