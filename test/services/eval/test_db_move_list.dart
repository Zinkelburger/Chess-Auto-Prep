/// Parsing ChessDB's two move-list wire formats, and the ordering the book
/// builder depends on.
library;

import 'package:chess_auto_prep/services/eval/cdbdirect_parse.dart';
import 'package:chess_auto_prep/services/eval/chessdb_api_provider.dart';
import 'package:chess_auto_prep/services/eval/chessdb_score.dart';
import 'package:chess_auto_prep/services/eval/db_move_list.dart';
import 'package:chess_auto_prep/utils/eval_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCdbDirectMoveList', () {
    test('verbose records keep every move, best first', () {
      final moves = parseCdbDirectMoveList(
        'move:d2d4,score:25,rank:1,note:,winrate:0.512|'
        'move:e2e4,score:30,rank:0,note:!,winrate:0.515|'
        'move:g1f3,score:22,rank:1,note:,winrate:0.510',
      );

      expect(moves.map((m) => m.uci), ['e2e4', 'd2d4', 'g1f3']);
      expect(moves.first.stmCp, 30);
      // Carried through, but it decides nothing.
      expect(moves.first.rank, 0);
      expect(moves.first.note, '!');
      // An empty note is absence, not an annotation.
      expect(moves[1].note, isNull);
    });

    test('compact pairs parse and sort', () {
      final moves = parseCdbDirectMoveList('d2d4:25|e2e4:30');
      expect(moves.map((m) => m.uci), ['e2e4', 'd2d4']);
      expect(moves.map((m) => m.stmCp), [30, 25]);
    });

    test('bookkeeping segments are not moves', () {
      final moves = parseCdbDirectMoveList('ply:12|e2e4:30');
      expect(moves.map((m) => m.uci), ['e2e4']);
    });

    test('a promotion is a move', () {
      final moves = parseCdbDirectMoveList('e7e8q:900');
      expect(moves.single.uci, 'e7e8q');
    });

    test('misses and score-only responses carry no moves', () {
      expect(parseCdbDirectMoveList(null), isEmpty);
      expect(parseCdbDirectMoveList(''), isEmpty);
      expect(parseCdbDirectMoveList('unknown'), isEmpty);
      expect(parseCdbDirectMoveList('eval:42'), isEmpty);
    });

    test('the single-eval parser still answers the same responses', () {
      // The move list is additive: nothing about the eval path moved.
      final r = parseCdbDirectResponse('e2e4:30|d2d4:25');
      expect(r?.cp, 30);
      expect(r?.bestMove, 'e2e4');
    });
  });

  group('parseChessDbQueryAllBody', () {
    test('reads uci, san, score, rank and note', () {
      final moves = parseChessDbQueryAllBody(
        '{"status":"ok","moves":['
        '{"uci":"d2d4","san":"d4","score":25,"rank":1,"note":"! (25-00)"},'
        '{"uci":"e2e4","san":"e4","score":30,"rank":2,"note":""}'
        ']}',
      );

      // Ordered on score, not on the rank field, which runs the other way
      // on this endpoint: d2d4's rank of 1 does not lift it over e2e4.
      expect(moves.map((m) => m.uci), ['e2e4', 'd2d4']);
      expect(moves.first.san, 'e4');
      expect(moves.first.stmCp, 30);
      expect(moves[1].note, '! (25-00)');
    });

    test('a non-ok status is a miss, not an empty position', () {
      expect(parseChessDbQueryAllBody('{"status":"unknown"}'), isEmpty);
      expect(parseChessDbQueryAllBody('{"status":"invalid board"}'), isEmpty);
    });

    test('garbage is a miss rather than a throw', () {
      expect(parseChessDbQueryAllBody(''), isEmpty);
      expect(parseChessDbQueryAllBody('rate limit exceeded'), isEmpty);
      expect(parseChessDbQueryAllBody('{"status":"ok"}'), isEmpty);
      expect(parseChessDbQueryAllBody('[1,2,3]'), isEmpty);
    });

    test('a move without a score is dropped, not defaulted to zero', () {
      final moves = parseChessDbQueryAllBody(
        '{"status":"ok","moves":['
        '{"uci":"d2d4","san":"d4"},'
        '{"uci":"e2e4","san":"e4","score":-15}'
        ']}',
      );
      expect(moves.map((m) => m.uci), ['e2e4']);
    });
  });

  group('mapChessDbRawScoreStm', () {
    test('ordinary scores pass through', () {
      expect(mapChessDbRawScoreStm(30).stmCp, 30);
      expect(mapChessDbRawScoreStm(-30).mate, isNull);
    });

    test('mate scores decode to a ply distance', () {
      final winning = mapChessDbRawScoreStm(29996);
      expect(winning.mate, 4);
      expect(winning.stmCp, kMateCpBase - 4);

      final losing = mapChessDbRawScoreStm(-29996);
      expect(losing.mate, -4);
      expect(losing.stmCp, -kMateCpBase - 4);
    });

    test('agrees with the white-normalizing wrapper', () {
      final mapped = mapChessDbApiScore(29996, isWhiteToMove: false);
      expect(mapped!.$1, -(kMateCpBase - 4));
      expect(mapped.$2, 4);
    });
  });

  group('DbMoveList', () {
    const list = DbMoveList(
      moves: [
        DbMove(uci: 'e2e4', stmCp: 30),
        DbMove(uci: 'd2d4', stmCp: 30),
        DbMove(uci: 'c2c4', stmCp: 18),
      ],
      source: DbMoveSource.cdbDirect,
    );

    test('withinCp(0) is the set of exact ties', () {
      expect(list.withinCp(0).map((m) => m.uci), ['e2e4', 'd2d4']);
    });

    test('a window admits the near-misses', () {
      expect(list.withinCp(12).map((m) => m.uci), ['e2e4', 'd2d4', 'c2c4']);
    });

    test('score decides and rank never overrides it', () {
      // ChessDB's rank means opposite things on its two faces, so it gets no
      // vote: b2b3 stays ahead of c2c3 on source order, not on rank.
      final sorted = DbMoveList.sorted(const [
        DbMove(uci: 'a2a3', stmCp: 10, rank: 2),
        DbMove(uci: 'b2b3', stmCp: 20, rank: 0),
        DbMove(uci: 'c2c3', stmCp: 20, rank: 2),
      ]);
      expect(sorted.map((m) => m.uci), ['b2b3', 'c2c3', 'a2a3']);
    });
  });
}
