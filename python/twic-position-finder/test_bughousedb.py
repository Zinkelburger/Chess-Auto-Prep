"""BughouseDB: positions, the upload checks and the score arithmetic."""

import sqlite3
import tempfile
import unittest
from pathlib import Path

from fastapi import HTTPException

import bughousedb as bh

START = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1"
DUAL = f"{START}|{START}"


def searches(q=0.0, pv=("(e7e5,pass)",)):
    return bh.Search(q=q, pv=list(pv), best=pv[0] if pv else None, nodes=100)


class PositionTests(unittest.TestCase):
    def test_key_is_the_desktop_book_key(self):
        # tools/bughouse_db/poskey.py on the same position
        self.assertEqual(bh.position_key(bh.parse_dual(DUAL)), -1476275556734231047)

    def test_both_boards_list_their_moves_and_who_answers(self):
        moves = bh.legal_moves(bh.parse_dual(DUAL))
        self.assertEqual(len(moves), 40)
        e4 = next(m for m in moves if (m["board"], m["uci"]) == ("A", "e2e4"))
        self.assertEqual((e4["seat"], e4["san"], e4["answerer"]), ("A", "e4", "CD"))
        d4 = next(m for m in moves if (m["board"], m["uci"]) == ("B", "d2d4"))
        self.assertEqual((d4["seat"], d4["answerer"]), ("D", "AB"))

    def test_a_capture_goes_to_the_partner_with_its_colour(self):
        boards = bh.parse_dual(DUAL)
        for uci in ("e2e4", "d7d5", "e4d5"):
            boards = bh.push(boards, 0, boards[0].parse_uci(uci))
        self.assertEqual(str(boards[1].pockets[bh.chess.BLACK]), "p")
        self.assertEqual(str(boards[0].pockets[bh.chess.WHITE]), "")

    def test_pv_reads_as_seat_lettered_san(self):
        text = bh.render_pv(bh.parse_dual(DUAL), ["(e2e4,pass)", "(e7e5,d2d4)", "(bogus,pass)"])
        self.assertEqual(text, "A e4 · C e5 D d4")

    def test_centipawns_follow_the_lichess_curve(self):
        self.assertEqual(bh.centipawns(0.0), 0)
        self.assertEqual(bh.centipawns(0.14), 77)
        self.assertEqual(bh.centipawns(-0.55), -336)

    def test_a_line_is_replayed_with_captures_crossing(self):
        boards = bh.play_line(bh.parse_dual(DUAL), "A:e2e4 A:d7d5 A:e4d5 B:e2e4 B:P@e6")
        self.assertEqual(boards[1].piece_at(bh.chess.E6).symbol(), "p")
        with self.assertRaises(bh.BadPosition):
            # Without the capture on board A, board B has no pawn to drop.
            bh.play_line(bh.parse_dual(DUAL), "A:e2e4 A:d7d5 B:e2e4 B:P@e6")

    def test_bad_positions_are_refused(self):
        for fen in ("", START, "8/8/8/8/8/8/8/8 w - - 0 1|" + START):
            with self.assertRaises(bh.BadPosition):
                bh.parse_dual(fen)


class UploadTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.conn = bh.connect(Path(self._tmp.name) / "b.db")

    def tearDown(self):
        self.conn.close()
        self._tmp.cleanup()

    def ticket(self, age=3600.0, contributor="tester"):
        t = bh.issue_ticket(self.conn, DUAL, contributor)
        with self.conn:
            self.conn.execute("UPDATE ticket SET issued = issued - ? WHERE id=?",
                              (min(age, bh.TICKET_TTL - 1), t["ticket"]))
        return t["ticket"]

    def upload(self, ticket, drop=0, bad_pv=False):
        moves = bh.legal_moves(bh.parse_dual(DUAL))[drop:]
        own = [bh.OwnUpload(team=t, ahead=a, search=searches(q=(0.0 if a else -0.58)))
               for t in ("AB", "CD") for a in (True, False)]
        pv = ["(e7e5" if bad_pv else "(e7e5,pass)"]
        return bh.PositionUpload(
            ticket=ticket, fen=DUAL, engine="test", nodes=800, child_nodes=100, own=own,
            moves=[bh.MoveUpload(board=m["board"], uci=m["uci"],
                                 on=searches(0.1, pv) if not bad_pv else bh.Search(q=0.1, pv=pv),
                                 off=searches(-0.5))
                   for m in moves])

    def test_a_complete_upload_is_stored_and_read_back(self):
        result = bh.store_upload(self.conn, self.upload(self.ticket()), "tester")
        self.assertEqual(result["moves"], 40)
        pos = bh.read_position(self.conn, DUAL)
        self.assertTrue(pos["found"])
        e4 = next(m for m in pos["moves"] if m["uci"] == "e2e4" and m["board"] == "A")
        # Even: both bits off, offset (-0.58 + -0.58)/2; C + D answered with -0.5.
        self.assertAlmostEqual(e4["scores"]["even"]["q"], -(-0.5 + 0.58), places=4)
        # Ahead for A + B: C + D answers with its bit off, offset (0 + -0.58)/2.
        self.assertAlmostEqual(e4["scores"]["ahead"]["q"], -(-0.5 + 0.29), places=4)
        # Behind: C + D's bit is on.
        self.assertAlmostEqual(e4["scores"]["behind"]["q"], -(0.1 + 0.29), places=4)
        self.assertEqual(e4["scores"]["behind"]["pv"], "A e4 · C e5")
        # Both: C + D answers with its bit on, read against (0 + 0)/2.
        self.assertAlmostEqual(e4["scores"]["both"]["q"], -0.1, places=4)
        self.assertEqual({p["clock"] for p in pos["picks"]}, set(bh.CLOCKS))

    def test_unscored_moves_are_stored_without_a_score(self):
        up = self.upload(self.ticket())
        for m in up.moves:
            if m.uci not in ("e2e4", "d2d4"):
                m.on = m.off = None
        bh.store_upload(self.conn, up, "tester")
        moves = bh.read_position(self.conn, DUAL)["moves"]
        scored = {m["uci"] for m in moves if m["scores"]["even"]["q"] is not None}
        self.assertEqual(scored, {"e2e4", "d2d4"})
        self.assertEqual(len(moves), 40)

    def test_the_minimum_time_counts_only_the_searches_sent(self):
        up = self.upload(self.ticket(age=1.0))
        for m in up.moves[2:]:
            m.on = m.off = None
        bh.store_upload(self.conn, up, "tester")  # 4 own + 4 move searches fit in 1 s

    def test_the_move_set_must_be_exactly_the_legal_moves(self):
        with self.assertRaises(HTTPException) as e:
            bh.store_upload(self.conn, self.upload(self.ticket(), drop=1), "tester")
        self.assertEqual(e.exception.status_code, 422)

    def test_a_ticket_works_once(self):
        ticket = self.ticket()
        bh.store_upload(self.conn, self.upload(ticket), "tester")
        with self.assertRaises(HTTPException) as e:
            bh.store_upload(self.conn, self.upload(ticket), "tester")
        self.assertEqual(e.exception.status_code, 403)

    def test_no_ticket_no_upload(self):
        with self.assertRaises(HTTPException) as e:
            bh.store_upload(self.conn, self.upload("made-up"), "tester")
        self.assertEqual(e.exception.status_code, 403)

    def test_an_impossibly_fast_upload_is_refused(self):
        with self.assertRaises(HTTPException) as e:
            bh.store_upload(self.conn, self.upload(self.ticket(age=0)), "tester")
        self.assertEqual(e.exception.status_code, 429)

    def test_malformed_pv_is_refused(self):
        with self.assertRaises(HTTPException) as e:
            bh.store_upload(self.conn, self.upload(self.ticket(), bad_pv=True), "tester")
        self.assertEqual(e.exception.status_code, 422)

    def test_text_in_the_best_move_is_refused(self):
        up = self.upload(self.ticket())
        up.own[0].search.best = "(visit-my-site,pass)"
        with self.assertRaises(HTTPException) as e:
            bh.store_upload(self.conn, up, "tester")
        self.assertEqual(e.exception.status_code, 422)

    def test_an_illegal_best_move_is_not_shown(self):
        boards = bh.parse_dual(DUAL)
        self.assertEqual(bh.joint_text(boards, "(e2e5,pass)", "AB"), "")
        self.assertEqual(bh.joint_text(boards, "(e2e4,pass)", "AB"), "A e4")

    def test_the_contributor_ip_ignores_forwarded_for(self):
        from starlette.requests import Request
        def request(headers):
            return Request({"type": "http", "client": ("10.0.0.9", 1),
                            "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()]})
        self.assertEqual(bh.client_ip(request({"X-Forwarded-For": "1.2.3.4"})), "10.0.0.9")
        self.assertEqual(bh.client_ip(request({"CF-Connecting-IP": "5.6.7.8"})), "5.6.7.8")

    def test_another_computer_confirms_a_stored_position(self):
        bh.store_upload(self.conn, self.upload(self.ticket()), "tester")
        self.assertEqual(bh.read_position(self.conn, DUAL)["meta"]["computers"], 1)
        second = self.upload(self.ticket(contributor="someone"))
        for m in second.moves:
            m.off = searches(0.9)  # a disagreeing confirmation does not change the book
        self.assertEqual(bh.store_upload(self.conn, second, "someone")["computers"], 2)
        pos = bh.read_position(self.conn, DUAL)
        self.assertEqual(pos["meta"]["computers"], 2)
        e4 = next(m for m in pos["moves"] if m["uci"] == "e2e4" and m["board"] == "A")
        self.assertAlmostEqual(e4["scores"]["even"]["q"], -(-0.5 + 0.58), places=4)

    def test_one_computer_counts_once(self):
        first = self.ticket()
        spare = self.ticket()  # taken before the first upload landed
        bh.store_upload(self.conn, self.upload(first), "tester")
        with self.assertRaises(HTTPException) as e:
            bh.issue_ticket(self.conn, DUAL, "tester")
        self.assertEqual(e.exception.status_code, 409)
        with self.assertRaises(HTTPException) as e:
            bh.store_upload(self.conn, self.upload(spare), "tester")
        self.assertEqual(e.exception.status_code, 409)

    def test_positions_stored_before_counting_have_their_uploader(self):
        bh.store_upload(self.conn, self.upload(self.ticket()), "tester")
        with self.conn:
            self.conn.execute("DELETE FROM submission")
            self.conn.execute("DELETE FROM meta WHERE key='submissions'")
        bh.record_first_submissions(self.conn)
        self.assertEqual(bh.read_position(self.conn, DUAL)["meta"]["computers"], 1)

    def test_admin_import_checks_the_move_set(self):
        moves = bh.legal_moves(bh.parse_dual(DUAL))
        good = bh.ImportPosition(
            fen=DUAL, engine="desktop", nodes=1500, child_nodes=200,
            picks=[bh.ImportPick(clock="even", team="AB", best="A d4", q=0.0)],
            moves=[bh.ImportMove(board=m["board"], uci=m["uci"], clock=c, q=0.01)
                   for m in moves for c in bh.CLOCKS])
        bad = good.model_copy(update={"moves": good.moves[len(bh.CLOCKS):]})  # one move short
        out = bh.store_import(self.conn, bh.ImportBatch(positions=[bad, good]))
        self.assertEqual((out["added"], len(out["errors"])), (1, 1))
        self.assertEqual(bh.store_import(self.conn, bh.ImportBatch(positions=[good]))["skipped"], 1)
        self.assertEqual(bh.read_position(self.conn, DUAL)["meta"]["source"], "desktop")


if __name__ == "__main__":
    unittest.main()
