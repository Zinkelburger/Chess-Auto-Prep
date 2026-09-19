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
        self.assertEqual((e4["seat"], e4["san"], e4["answerer"]), ("A", "e4", "BD"))
        d4 = next(m for m in moves if (m["board"], m["uci"]) == ("B", "d2d4"))
        self.assertEqual((d4["seat"], d4["answerer"]), ("D", "AC"))

    def test_a_capture_goes_to_the_partner_with_its_colour(self):
        boards = bh.parse_dual(DUAL)
        for uci in ("e2e4", "d7d5", "e4d5"):
            boards = bh.push(boards, 0, boards[0].parse_uci(uci))
        self.assertEqual(str(boards[1].pockets[bh.chess.BLACK]), "p")
        self.assertEqual(str(boards[0].pockets[bh.chess.WHITE]), "")

    def test_pv_reads_as_seat_lettered_san(self):
        text = bh.render_pv(bh.parse_dual(DUAL), ["(e2e4,pass)", "(e7e5,d2d4)", "(bogus,pass)"])
        self.assertEqual(text, "A e4 · B e5 D d4")

    def test_centipawns_follow_the_lichess_curve(self):
        self.assertEqual(bh.centipawns(0.0), 0)
        self.assertEqual(bh.centipawns(0.14), 77)
        self.assertEqual(bh.centipawns(-0.55), -336)

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

    def ticket(self, age=3600.0):
        t = bh.issue_ticket(self.conn, DUAL, "tester")
        with self.conn:
            self.conn.execute("UPDATE ticket SET issued = issued - ?", (min(age, bh.TICKET_TTL - 1),))
        return t["ticket"]

    def upload(self, ticket, drop=0, bad_pv=False):
        moves = bh.legal_moves(bh.parse_dual(DUAL))[drop:]
        own = [bh.OwnUpload(team=t, ahead=a, search=searches(q=(0.0 if a else -0.58)))
               for t in ("AC", "BD") for a in (True, False)]
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
        # Even: both bits off, offset (-0.58 + -0.58)/2; BD answered with -0.5.
        self.assertAlmostEqual(e4["scores"]["even"]["q"], -(-0.5 + 0.58), places=4)
        # Ahead for A + C: BD answers with its bit off, offset (0 + -0.58)/2.
        self.assertAlmostEqual(e4["scores"]["ahead"]["q"], -(-0.5 + 0.29), places=4)
        # Behind: BD's bit is on.
        self.assertAlmostEqual(e4["scores"]["behind"]["q"], -(0.1 + 0.29), places=4)
        self.assertEqual(e4["scores"]["behind"]["pv"], "A e4 · B e5")
        self.assertEqual({p["clock"] for p in pos["picks"]}, set(bh.CLOCKS))

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

    def test_no_ticket_for_a_position_already_in_the_book(self):
        bh.store_upload(self.conn, self.upload(self.ticket()), "tester")
        with self.assertRaises(HTTPException) as e:
            bh.issue_ticket(self.conn, DUAL, "someone")
        self.assertEqual(e.exception.status_code, 409)

    def test_admin_import_checks_the_move_set(self):
        moves = bh.legal_moves(bh.parse_dual(DUAL))
        good = bh.ImportPosition(
            fen=DUAL, engine="desktop", nodes=1500, child_nodes=200,
            picks=[bh.ImportPick(clock="even", team="AC", best="A d4", q=0.0)],
            moves=[bh.ImportMove(board=m["board"], uci=m["uci"], clock=c, q=0.01)
                   for m in moves for c in bh.CLOCKS])
        bad = good.model_copy(update={"moves": good.moves[3:]})
        out = bh.store_import(self.conn, bh.ImportBatch(positions=[bad, good]))
        self.assertEqual((out["added"], len(out["errors"])), (1, 1))
        self.assertEqual(bh.store_import(self.conn, bh.ImportBatch(positions=[good]))["skipped"], 1)
        self.assertEqual(bh.read_position(self.conn, DUAL)["meta"]["source"], "desktop")


if __name__ == "__main__":
    unittest.main()
