import copy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from fastapi import HTTPException
import bughousedb as bh
import bughouse_expectimax as ex

START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1'
FEN = f'{START}|{START}'


def record(board='A', nodes=1500):
    boards = bh.parse_dual(FEN)
    i = 'AB'.index(board)
    child = bh.push(boards, i, boards[i].parse_uci('e2e4'))
    return {'fen': FEN, 'board': board, 'data': {
        'model': ex.MODEL, 'perspective': 'white-on-selected-board', 'plies': 2, 'nodes': nodes,
        'rows': [{'uci': 'e2e4', 'san': 'e4', 'board': board, 'fen': bh.dual_fen(child),
                  'probability': .3, 'eval': .1, 'white': .2, 'black': -.1,
                  'coverage': .7, 'nodes': nodes, 'depth': 7, 'replies': []}],
    }}


class ExpectimaxTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name) / 'expectimax.db'
        self.addCleanup(self.folder.cleanup)

    def store(self, records):
        return ex.store(records, bh.parse_dual, bh.position_key, bh.push, self.path)

    def read(self, fen=FEN):
        boards = bh.parse_dual(fen)
        return ex.read(bh.position_key(boards), ex.canonical(boards), self.path)

    def test_same_snapshot_serves_both_colours_and_boards(self):
        self.assertEqual(self.read(), {'A': None, 'B': None})
        self.store([record('A'), record('B')])
        result = self.read()
        self.assertEqual(result['A']['rows'][0]['white'], .2)
        self.assertEqual(result['B']['rows'][0]['black'], -.1)
        self.store([record('A', 3000)])
        self.assertEqual(self.read()['A']['nodes'], 3000)

    def test_illegal_moves_wrong_child_nan_and_unknown_model_are_rejected_atomically(self):
        for mutation in ('illegal', 'child', 'nan', 'model'):
            value = copy.deepcopy(record())
            row = value['data']['rows'][0]
            if mutation == 'illegal': row['uci'] = 'e2e5'
            if mutation == 'child': row['fen'] = FEN
            if mutation == 'nan': row['white'] = float('nan')
            if mutation == 'model': value['data']['model'] = 'unknown'
            with self.assertRaises(ValueError): self.store([record('B'), value])
            self.assertEqual(self.read(), {'A': None, 'B': None})

    def test_route_requires_admin_and_ordinary_reads_need_no_key(self):
        with patch.object(bh, 'ADMIN_KEY', 'test-key'), patch.object(ex, 'DB_PATH', self.path):
            batch = bh.ExpectimaxImport(positions=[record()])
            with self.assertRaises(HTTPException): bh.import_expectimax(batch, 'wrong')
            self.assertEqual(bh.import_expectimax(batch, 'test-key')['added'], 1)
            self.assertEqual(bh.get_expectimax(FEN)['A']['rows'][0]['white'], .2)

    def test_new_position_never_reuses_root_scores(self):
        self.store([record()])
        child = record()['data']['rows'][0]['fen']
        self.assertEqual(self.read(child), {'A': None, 'B': None})


if __name__ == '__main__': unittest.main()
