"""Shared evaluations: legal moves, budgets, profile isolation and ticket claims."""
import tempfile
import unittest
from pathlib import Path
from fastapi import HTTPException
import bughousedb as bh
import bughouse_evaluation as ev

START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1'
DUAL = START + '|' + START


class EvaluationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = bh.connect(Path(self.temp.name) / 'book.db')

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def upload(self, **changes):
        data = dict(fen=DUAL, ticket=ev.ticket(self.db, DUAL, 'test')['ticket'],
                    ours=bh.Search(q=-.4, nodes=800, best='(e2e4,pass)'),
                    theirs=bh.Search(q=-.6, nodes=800, best='(pass,d2d4)'))
        data.update(changes)
        return ev.Upload(**data)

    def test_save_read_and_position_endpoint_share_derived_evaluation(self):
        result = ev.store(self.db, self.upload(), 'test')['analysis']
        self.assertAlmostEqual(result['advantage'], .1)
        self.assertEqual(result['best']['A'], 'e4')
        self.assertTrue(result['shared'])
        self.assertEqual(result, ev.read(self.db, ev.Settings(fen=DUAL))['analysis'])
        self.assertEqual(bh.read_position(self.db, DUAL)['evaluations'][0]['analysis'], result)
        self.assertIsNone(ev.read(self.db, ev.Settings(fen=DUAL, team='black'))['analysis'])
        self.assertIsNone(ev.read(self.db, ev.Settings(fen=DUAL, nodes=3000))['analysis'])

    def test_saved_shortlist_is_preserved_and_validated(self):
        result = ev.store(self.db, self.upload(candidates=['(d2d4,pass)', '(g1f3,pass)']), 'test')['analysis']
        self.assertEqual([line['best']['A'] for line in result['lines']], ['d4', 'Nf3'])
        with self.assertRaises(HTTPException):
            ev.store(self.db, self.upload(candidates=['(e2e5,pass)']), 'test')

    def test_static_calibration_when_only_one_team_can_move(self):
        boards = bh.parse_dual(DUAL)
        moved = bh.dual_fen(bh.push(boards, 0, boards[0].parse_uci('d2d4')))
        upload = self.upload(fen=moved, team='black',
                             ticket=ev.ticket(self.db, moved, 'test')['ticket'],
                             ours=bh.Search(q=-.4, nodes=801, best='(d7d5,e2e4)'),
                             theirs=None, static_values=[-.5, -.6])
        result = ev.store(self.db, upload, 'test')['analysis']
        self.assertAlmostEqual(result['advantage'], .15)
        self.assertEqual(result['calibration']['source'], 'static')
        with self.assertRaises(HTTPException):
            ev.store(self.db, self.upload(theirs=None, static_values=[-.5, -.6]), 'test')

    def test_ticket_is_bound_to_contributor_and_single_use(self):
        upload = self.upload()
        with self.assertRaises(HTTPException): ev.store(self.db, upload, 'other')
        ev.store(self.db, upload, 'test')
        with self.assertRaises(HTTPException): ev.store(self.db, upload, 'test')

    def test_reject_illegal_wrong_team_or_missing_required_move(self):
        for move in ('(e2e5,pass)', '(e7e5,pass)', '(pass,pass)'):
            with self.subTest(move=move), self.assertRaises(HTTPException):
                ev.store(self.db, self.upload(ours=bh.Search(q=0, nodes=800, best=move)), 'test')
        with self.assertRaises(HTTPException):
            ev.store(self.db, self.upload(required='B'), 'test')

    def test_time_cap_does_not_publish_as_completed_budget(self):
        with self.assertRaises(HTTPException):
            ev.store(self.db, self.upload(ours=bh.Search(q=0, nodes=799, best='(e2e4,pass)')), 'test')

    def test_deeper_result_survives_shallower_upload(self):
        deep = self.upload(nodes=3000, ours=bh.Search(q=-.2, nodes=3000, best='(g1f3,pass)'),
                           theirs=bh.Search(q=-.8, nodes=3000, best='(pass,d2d4)'))
        ev.store(self.db, deep, 'test')
        result = ev.store(self.db, self.upload(), 'test')['analysis']
        self.assertEqual(result['best']['A'], 'Nf3')
        self.assertEqual(result['nodes'], 3000)

    def test_mate_proof_can_finish_early(self):
        result = ev.store(self.db, self.upload(ours=bh.Search(mate=3, nodes=5, best='(e2e4,pass)'), theirs=None), 'test')
        self.assertEqual(result['analysis']['mate'], 3)


if __name__ == '__main__':
    unittest.main()
