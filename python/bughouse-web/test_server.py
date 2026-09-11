"""HTTP rules, resource limits and real engine smoke test (opt in)."""

import asyncio
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

import server

REAL_ENGINE = "--engine" in sys.argv
sys.argv = [arg for arg in sys.argv if arg != "--engine"]
START = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1"


class FakeRunner:
    busy = False

    async def run(self, payload):
        self.payload = payload
        return {"best": {"A": "e4", "B": "sit"}, "calibration": {"source": "measured"}}

    async def close(self):
        pass


class WebTests(unittest.TestCase):
    def setUp(self):
        self.runner = FakeRunner()
        self.client = TestClient(server.create_app(self.runner))

    def test_move_capture_drop_and_history(self):
        response = self.client.post("/api/bughouse/position", json={
            "moves": ["A:e4", "A:d5", "A:exd5", "B:e4"]})
        self.assertEqual(response.status_code, 200)
        state = response.json()
        self.assertEqual(state["boards"]["B"]["pockets"]["black"], "p")
        self.assertEqual(state["boards"]["A"]["pockets"]["white"], "")
        self.assertIn("P@e6", [m["uci"] for m in state["boards"]["B"]["legal_moves"]])
        self.assertEqual(state["boards"]["A"]["movetext"], "1. e4 d5 2. exd5")
        dropped = self.client.post("/api/bughouse/position", json={
            "dual_fen": state["dual_fen"], "moves": ["B:P@e6"]}).json()
        self.assertEqual(dropped["boards"]["B"]["pieces"]["e6"], "p")
        self.assertEqual(dropped["boards"]["B"]["pockets"]["black"], "")

    def test_analysis_is_canonical_bounded_and_calibrated(self):
        result = self.client.post("/api/bughouse/analyse", json={"moves": ["e4"], "team": "black"})
        self.assertEqual(result.status_code, 200)
        payload = self.runner.payload
        self.assertNotIn("moves", payload)
        self.assertIn("4P3", payload["dual_fen"])
        self.assertTrue(payload["calibrate"])
        self.assertEqual(payload["movetime_ms"], 1500)

    def test_reject_uci_injection_invalid_positions_and_unbounded_budgets(self):
        bad = [
            {"dual_fen": START + "\ngo infinite"},
            {"dual_fen": "8/8/8/8/8/8/8/8 w - - 0 1"},
            {"moves": ["e4\nquit"]}, {"moves": ["e5"]},
            {"movetime_ms": 3001}, {"movetime_ms": True}, {"movetime_ms": "1000"},
            {"nodes": 1000000000}, {"multipv": 4}, {"team": "other"},
            {"moves": ["e4"] * 257}, {"time_advantage": "false"},
        ]
        # Separate app instances so this tests validation rather than rate limits.
        for payload in bad:
            with self.subTest(payload=payload):
                response = TestClient(server.create_app(FakeRunner())).post(
                    "/api/bughouse/analyse", json=payload)
                self.assertEqual(response.status_code, 422, response.text)

    def test_require_move_on_must_be_our_turn(self):
        response = self.client.post("/api/bughouse/analyse", json={"require_move_on": "B"})
        self.assertEqual(response.status_code, 422)

    def test_valid_promotion_choices(self):
        state = self.client.post("/api/bughouse/position", json={
            "dual_fen": "7k/P7/8/8/8/8/8/7K[] w - - 0 1|" + START}).json()
        self.assertEqual(sum(m["uci"].startswith("a7a8") for m in state["boards"]["A"]["legal_moves"]), 4)

    def test_limit_body_even_without_content_length(self):
        response = self.client.post("/api/bughouse/position", content=iter([b" " * 9000, b" " * 9000]),
                                    headers={"Content-Type": "application/json"})
        self.assertEqual(response.status_code, 413)

    def test_rate_limit_ignores_spoofed_forwarded_header(self):
        for n in range(6):
            self.assertEqual(self.client.post("/api/bughouse/analyse", json={},
                             headers={"X-Forwarded-For": f"192.0.2.{n}"}).status_code, 200)
        response = self.client.post("/api/bughouse/analyse", json={})
        self.assertEqual(response.status_code, 429)
        self.assertEqual(response.headers["Retry-After"], "60")

    def test_cors_allows_only_configured_sites(self):
        for origin, allowed in [("https://chessautoprep.com", True), ("https://andrewbernal.com", True),
                                ("https://unrelated.example", False)]:
            response = self.client.options("/api/bughouse/position", headers={
                "Origin": origin, "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "Content-Type"})
            self.assertEqual(response.status_code, 200 if allowed else 400)

    def test_health_does_not_start_engine_or_leak_paths(self):
        result = self.client.get("/api/bughouse/health")
        self.assertEqual(result.status_code, 200)
        self.assertNotIn("/home/", result.text)
        self.assertFalse(hasattr(self.runner, "payload"))


class AdmissionTests(unittest.TestCase):
    def test_windows_expire_and_table_is_bounded(self):
        limiter = server.RateLimit(2, capacity=2)
        with patch.object(server.time, "monotonic", return_value=0):
            self.assertTrue(limiter.accept("a"))
            self.assertTrue(limiter.accept("a"))
            self.assertFalse(limiter.accept("a"))
            self.assertTrue(limiter.accept("b"))
            self.assertFalse(limiter.accept("c"))
        with patch.object(server.time, "monotonic", return_value=61):
            self.assertTrue(limiter.accept("c"))
            self.assertEqual(len(limiter.clients), 1)


class RunnerTests(unittest.IsolatedAsyncioTestCase):
    async def test_busy_rejects_without_starting_process(self):
        runner = server.SearchRunner()
        runner.busy = True
        with self.assertRaises(server.HTTPException) as caught:
            await runner.run({})
        self.assertEqual(caught.exception.status_code, 429)

    async def test_timeout_reaps_worker_and_recovers(self):
        runner = server.SearchRunner()
        create = asyncio.create_subprocess_exec
        started = []

        async def sleepy(*args, **kwargs):
            proc = await create(sys.executable, "-c", "import time; time.sleep(60)", **kwargs)
            started.append(proc)
            return proc

        with patch.object(server.asyncio, "create_subprocess_exec", side_effect=sleepy), \
                patch.object(server, "SEARCH_TIMEOUT", .1):
            with self.assertRaises(server.HTTPException) as caught:
                await runner.run({})
        self.assertEqual(caught.exception.status_code, 504)
        self.assertIsNotNone(started[0].returncode)
        self.assertFalse(runner.busy)
        self.assertIsNone(runner.process)

    @unittest.skipUnless(REAL_ENGINE, "pass --engine to search with real Hivemind")
    async def test_real_engine_search_and_cleanup(self):
        runner = server.SearchRunner()
        result = await runner.run({"dual_fen": START + "|" + START, "team": "white",
                                   "movetime_ms": 250, "multipv": 2, "calibrate": True})
        self.assertIsNotNone(result["best"])
        self.assertEqual(result["calibration"]["searches"], 2)
        self.assertEqual(result["calibration"]["source"], "measured")
        self.assertFalse(runner.busy)
        print("Real Hivemind:", json.dumps(result["best"]), "nodes:", result["nodes"])


if __name__ == "__main__":
    unittest.main()
