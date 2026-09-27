#!/usr/bin/env python3
"""Offline collection/search/report/export regressions. No user's files or engines."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from chess_prep.tools import Registry, ToolError

BF5 = '1.e4 c6 2.d4 d5 3.Nd2 dxe4 4.Nxe4 Bf5'
NF6 = '1.e4 c6 2.d4 d5 3.Nd2 dxe4 4.Nxe4 Nf6'


def game(moves, result='1-0', white='Karpov, Anatoly', black='Opponent', date='1982.??.??', extra=''):
    return (f'[Event "Test"]\n[White "{white}"]\n[Black "{black}"]\n'
            f'[Date "{date}"]\n[Result "{result}"]\n{extra}\n{moves} {result}\n\n')


class Collections(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = patch.dict(os.environ, {'CHESS_PREP_PGN_DIR': str(self.root / 'cache')})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.registry = Registry()
        self.addCleanup(self.registry.close)
        self.path = self.root / 'games.pgn'
        self.path.write_text(
            game(BF5 + ' 5.Ng3 {A comment} Bg6 (5...Bg4) 6.h4 $1', black='Larsen', date='1982.01.01') +
            game(BF5.replace('Nd2', 'Nc3') + ' 5.Ng3', result='1/2-1/2', black='Pomar') +
            game(BF5 + ' 5.Ng3', result='*', black='Larsen') +
            game(BF5, result='0-1', white='Other', black='Karpov, Anatoly') +
            game(NF6 + ' 5.Nxf6+ exf6', black='Smyslov') +
            game(NF6 + ' 5.Ng3', result='0-1', black='Larsen') +
            game('1.Nf3 Nf6 2.Ng1 Ng8 3.Nf3 Nf6 4.Ng1 Ng8', result='*') +
            game('1.d4 d5 (1...Nf6 2.c4)', result='*'), encoding='utf-8')
        self.opened = self.call('pgn_collection_open', path=str(self.path))
        self.cid = self.opened['collection_id']

    def call(self, name, **args):
        return self.registry.call(name, args)

    def search(self, **args):
        return self.call('pgn_games_search', collection_id=self.cid, **args)

    def test_transposition_counts_and_pagination(self):
        a = self.search(player='Karpov', color='white', moves=BF5, limit=1)
        self.assertEqual((a['games'], a['wins'], a['draws'], a['unknown_results']), (3, 1, 1, 1))
        self.assertEqual(a['score_percent'], 75)
        self.assertEqual(len(a['items']), 1)
        self.assertEqual(a['next_offset'], 1)
        b = self.search(player='Karpov', color='white', moves=BF5, limit=2, offset=1)
        self.assertEqual(a['selection_id'], b['selection_id'])
        self.assertEqual(len(b['items']), 2)
        exact = self.search(player='Karpov', color='white', moves=BF5, match='prefix')
        self.assertEqual(exact['games'], 2)
        self.assertTrue(all(g['matched_ply'] == 8 for g in b['items']))

    def test_perspective_black_and_name_tokens(self):
        result = self.search(player='Anatoly Karpov', color='black')
        self.assertEqual((result['games'], result['wins'], result['losses']), (1, 1, 0))
        self.assertEqual(self.search(player='Karp')['games'], 0)
        self.assertEqual(self.search(player='Karpov', name_match='exact')['games'], 0)
        with self.assertRaisesRegex(ToolError, 'player is required'):
            self.search(color='white')

    def test_report_exceptions_and_narrow_selection(self):
        found = self.search(player='Karpov', color='white', moves=NF6)
        report = self.call('pgn_selection_report', selection_id=found['selection_id'])
        take = next(x for x in report['continuations'] if x['moves'] == ['Nxf6+'])
        self.assertEqual(take['games'], 1)
        self.assertEqual(take['other_or_ended_games'], 1)
        exceptional = self.call('pgn_game_get', game_id=take['exception_game_ids'][0])
        self.assertEqual(exceptional['headers']['Black'], 'Larsen')
        narrowed = self.call('pgn_games_search', selection_id=found['selection_id'], player='Karpov', opponent='Larsen')
        self.assertEqual(narrowed['games'], 1)
        self.assertEqual(narrowed['items'][0]['matched_ply'], 8)
        self.assertEqual(narrowed['losses'], 1)

    def test_repetitions_and_variations_do_not_inflate(self):
        import chess
        found = self.search(fen=chess.STARTING_FEN)
        self.assertEqual(found['games'], self.opened['games'])
        self.assertTrue(all(g['matched_ply'] == 0 for g in found['items']))
        self.assertEqual(self.search(moves='1.d4 Nf6 2.c4')['games'], 0)
        report = self.call('pgn_selection_report', selection_id=found['selection_id'], depth=1)
        self.assertEqual(sum(x['games'] for x in report['continuations']), found['games'])

    def test_export_survives_registry_restart_and_source_edit(self):
        found = self.search(player='Karpov', color='white', moves=BF5, limit=1)
        self.path.write_text(game('1.d4'), encoding='utf-8')
        changed = self.call('pgn_collection_open', path=str(self.path))
        self.assertNotEqual(changed['collection_id'], self.cid)
        self.registry.close()
        self.registry = Registry()
        self.addCleanup(self.registry.close)
        out = self.root / 'export.pgn'
        result = self.call('pgn_selection_export', selection_id=found['selection_id'], path=str(out))
        self.assertTrue(result['verified'])
        self.assertEqual(result['games'], 3)
        text = out.read_text()
        self.assertIn('A comment', text)
        self.assertIn('$1', text)
        self.assertIn('5... Bg4', ' '.join(text.split()))
        self.assertEqual(len(result['game_ids']), 3)
        with self.assertRaisesRegex(ToolError, 'Output exists'):
            self.call('pgn_selection_export', selection_id=found['selection_id'], path=str(out))
        self.call('pgn_selection_export', selection_id=found['selection_id'], path=str(out),
                  overwrite=True, comments=False, variations=False)
        self.assertNotIn('A comment', out.read_text())
        self.assertNotIn('Bg4', out.read_text())
        with self.assertRaisesRegex(ToolError, 'different from the source'):
            self.call('pgn_selection_export', selection_id=found['selection_id'], path=str(self.path), overwrite=True)

    def test_date_and_unknown_result_policies(self):
        self.assertEqual(self.search(date_from='1982-01-01', date_to='1982-12-31')['games'], 1)
        self.assertEqual(self.search(year_from=1982, year_to=1982)['games'], 8)
        unknown = self.search(result='*')
        self.assertIsNone(unknown['score_percent'])
        self.assertEqual(unknown['draws'], 0)
        with self.assertRaises(ToolError):
            self.search(date_from='1982-13-01')

    def test_zip_encoding_duplicates_and_errors(self):
        source = game(BF5, black='Hübner')
        path = self.root / 'multi.zip'
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('../games.pgn', (source + source + game('1.e4 e5 2.Bh6')).encode('cp1252'))
            z.writestr('second.pgn', game('1.d4'))
        with self.assertRaisesRegex(ToolError, 'Choose member'):
            self.call('pgn_collection_open', path=str(path))
        opened = self.call('pgn_collection_open', path=str(path), member='../games.pgn')
        self.assertEqual((opened['games'], opened['excluded_games'], opened['records']), (2, 1, 3))
        self.assertEqual(opened['duplicate_group_count'], 1)
        self.assertEqual(opened['encoding'], 'cp1252')
        self.assertTrue(any(p['name'] == 'Hübner' for p in opened['players']))
        self.assertFalse((self.root.parent / 'games.pgn').exists())

    def test_validation_and_empty_export(self):
        for args in ({'moves': '1.e4 e5 2.Bh6'}, {'match': 'fuzzy'}, {'limit': 0},
                     {'typo': 'ignored'}, {'offset': -1}, {'player': ''}, {'color': False}):
            with self.subTest(args=args), self.assertRaises(ToolError):
                self.search(**args)
        found = self.search(player='Nobody')
        with self.assertRaisesRegex(ToolError, 'empty'):
            self.call('pgn_selection_export', selection_id=found['selection_id'], path=str(self.root / 'none.pgn'))
        self.assertFalse((self.root / 'none.pgn').exists())

    def test_initial_fen_and_position_identity(self):
        import chess
        board = chess.Board()
        for san in ['e4', 'c6', 'd4', 'd5', 'Nd2', 'dxe4', 'Nxe4', 'Bf5']:
            board.push_san(san)
        path = self.root / 'fen.pgn'
        path.write_text(game('5.Ng3', extra=f'[SetUp "1"]\n[FEN "{board.fen()}"]\n'))
        opened = self.call('pgn_collection_open', path=str(path))
        result = self.call('pgn_games_search', collection_id=opened['collection_id'], moves=BF5)
        self.assertEqual(result['games'], 1)
        self.assertEqual(result['items'][0]['matched_ply'], 0)
        exact = self.call('pgn_games_search', collection_id=opened['collection_id'], moves=BF5, match='prefix')
        self.assertEqual(exact['games'], 0)
        # Clocks are irrelevant, castling rights are not.
        board.halfmove_clock = 70
        self.assertEqual(self.search(fen=board.fen())['games'], 4)
        board.castling_rights = 0
        self.assertEqual(self.search(fen=board.fen())['games'], 0)

    def test_reports_do_not_merge_different_start_positions(self):
        import chess
        board = chess.Board()
        board.push_san('e4')
        board.push_san('e5')
        path = self.root / 'mixed-starts.pgn'
        path.write_text(game('1.Nf3') + game('2.Nf3',
                        extra=f'[SetUp "1"]\n[FEN "{board.fen()}"]\n'))
        opened = self.call('pgn_collection_open', path=str(path))
        found = self.call('pgn_games_search', collection_id=opened['collection_id'])
        report = self.call('pgn_selection_report', selection_id=found['selection_id'])
        nodes = report['continuations']
        self.assertEqual(len(nodes), 2)
        self.assertTrue(all(n['games'] == n['parent_games'] == 1 for n in nodes))
        self.assertNotEqual(nodes[0]['from_fen4'], nodes[1]['from_fen4'])

    def test_snapshot_integrity(self):
        found = self.search(moves=BF5)
        path = self.root / 'cache' / 'selections' / (found['selection_id'] + '.json')
        data = json.loads(path.read_text())
        data['matches'] = []
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ToolError, 'checksum'):
            self.call('pgn_selection_report', selection_id=found['selection_id'])

    def test_one_shot_helper_calls_share_selection(self):
        helper = Path(__file__).resolve().parents[2] / '.agents/skills/chess-prep-mcp/mcp_tools.py'
        def invoke(name, **args):
            result = subprocess.run([sys.executable, str(helper), 'call', name,
                                     *[f'{key}={json.dumps(value)}' for key, value in args.items()]],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            return json.loads(result.stdout)
        opened = invoke('pgn_collection_open', path=str(self.path))
        found = invoke('pgn_games_search', collection_id=opened['collection_id'],
                       player='Karpov', color='white', moves=BF5, limit=1)
        report = invoke('pgn_selection_report', selection_id=found['selection_id'])
        output = invoke('pgn_selection_export', selection_id=found['selection_id'],
                        path=str(self.root / 'stdio.pgn'))
        self.assertEqual((found['games'], report['games'], output['games']), (3, 3, 3))
        self.assertTrue(output['verified'])
        fetched = invoke('pgn_game_get', game_id=found['items'][0]['game_id'])
        self.assertIn('A comment', fetched['pgn'])

    def test_report_limits_do_not_change_totals(self):
        found = self.search(player='Karpov', moves=BF5)
        report = self.call('pgn_selection_report', selection_id=found['selection_id'],
                           limit=1, evidence_limit=1)
        self.assertEqual(report['games'], found['games'])
        self.assertTrue(report['groups_truncated'])
        self.assertTrue(report['continuations_truncated'])
        self.assertTrue(report['continuations'][0]['evidence_truncated'])
        self.assertEqual(len(report['continuations'][0]['game_ids']), 1)

    def test_source_order_and_date_sort_preserve_game_ids(self):
        path = self.root / 'dates.pgn'
        path.write_text(game('1.e4', date='2000.01.01') + game('1.d4', date='????.??.??') +
                        game('1.c4', date='1980.??.??'))
        opened = self.call('pgn_collection_open', path=str(path))
        found = self.call('pgn_games_search', collection_id=opened['collection_id'])
        ids = [row['game_id'] for row in found['items']]
        result = self.call('pgn_selection_export', selection_id=found['selection_id'],
                           path=str(self.root / 'sorted.pgn'), sort='date_asc')
        self.assertEqual(result['game_ids'], [ids[2], ids[0], ids[1]])

    def test_invalid_names_aliases_and_ambiguous_side(self):
        alias = self.search(player='Wrong Name', aliases=['Anatoly Karpov'], color='white')
        self.assertEqual(alias['games'], 7)
        path = self.root / 'same-name.pgn'
        path.write_text(game('1.e4', white='Smith, A', black='Smith, B'))
        opened = self.call('pgn_collection_open', path=str(path))
        with self.assertRaisesRegex(ToolError, 'Both players match'):
            self.call('pgn_games_search', collection_id=opened['collection_id'], player='Smith')

    def test_server_discovery_without_site_packages(self):
        code = "from chess_prep.tools import Registry; r=Registry(); assert 'pgn_collection_open' in r.tools"
        env = {**os.environ, 'PYTHONPATH': str(Path(__file__).resolve().parent)}
        result = subprocess.run([sys.executable, '-S', '-c', code], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
