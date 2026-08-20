/// [writePgnGame] is the one emitter every generated PGN goes through, so the
/// shape of what it writes — headers, comments, and sidelines — is pinned
/// here rather than re-asserted through each caller.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/export/move_annotation.dart';
import 'package:chess_auto_prep/services/generation/export/pgn_game_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Movetext only — everything after the blank line that ends the tag pairs.
String movetextOf(String pgn) => pgn.split('\n\n').last.trim();

void main() {
  group('variations', () {
    test('hang off the move they are keyed to, numbered from it', () {
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course'},
          movesSan: ['e4', 'c5', 'Nf3'],
          variations: {
            2: [
              PgnSideline(['Nf3', 'd6', 'd4']),
            ],
          },
        ),
        detail: MoveAnnotationDetail.none,
      );

      expect(movetextOf(pgn), '1. e4 c5 2. Nf3 (2. Nf3 d6 3. d4) *');
    });

    test('a sideline on a Black move opens with the ... number', () {
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course'},
          movesSan: ['e4', 'c5'],
          variations: {
            1: [
              PgnSideline(['c5', 'Nf3', 'd6']),
            ],
          },
        ),
        detail: MoveAnnotationDetail.none,
      );

      expect(movetextOf(pgn), '1. e4 c5 (1... c5 2. Nf3 d6) *');
    });

    test('are written even in a bare export — content, not detail', () {
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course'},
          movesSan: ['e4'],
          annotations: [MoveAnnotation(evalCp: 30)],
          variations: {
            0: [
              PgnSideline(['e4', 'e5']),
            ],
          },
        ),
        detail: MoveAnnotationDetail.none,
      );

      expect(movetextOf(pgn), '1. e4 (1. e4 e5) *');
    });

    test('follow the move comment when both are present', () {
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course'},
          movesSan: ['e4'],
          annotations: [MoveAnnotation(evalCp: 30)],
          variations: {
            0: [
              PgnSideline(['e4', 'e5']),
            ],
          },
        ),
        detail: MoveAnnotationDetail.full,
      );

      expect(movetextOf(pgn), '1. e4 {[%eval +0.30]} (1. e4 e5) *');
    });

    test('an annotation glyph sits on the SAN, ahead of the comment', () {
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course'},
          movesSan: ['e4', 'f6'],
          annotations: [
            MoveAnnotation(isOnlyMove: true),
            MoveAnnotation(mistakeCp: 160, betterMoveSan: 'e5'),
          ],
        ),
        detail: MoveAnnotationDetail.likelihood,
      );

      expect(
        movetextOf(pgn),
        '1. e4! {Only move.} f6? {Blunder: gives up 1.60 against e5.} *',
      );
    });

    test('a line starting mid-game numbers its sidelines from the FEN', () {
      // Black to move on move 4.
      const fen =
          'rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 4';
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course'},
          movesSan: ['d6', 'd4'],
          startFen: fen,
          rootWhiteToMove: false,
          startMoveNumber: 4,
          variations: {
            1: [
              PgnSideline(['d4', 'cxd4']),
            ],
          },
        ),
        detail: MoveAnnotationDetail.none,
      );

      expect(movetextOf(pgn), '4... d6 5. d4 (5. d4 cxd4) *');
      expect(pgn, contains('[FEN "$fen"]'));
    });

    test('several sidelines on one move are written in list order', () {
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course'},
          movesSan: ['e4', 'c5'],
          variations: {
            1: [
              PgnSideline(['e5?', 'Nf3']),
              PgnSideline(['c5', 'Nf3']),
            ],
          },
        ),
        detail: MoveAnnotationDetail.none,
      );

      expect(movetextOf(pgn), '1. e4 c5 (1... e5? 2. Nf3) (1... c5 2. Nf3) *');
    });

    test('a sideline comment lands on its first move', () {
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course'},
          movesSan: ['e4', 'c5'],
          variations: {
            1: [
              PgnSideline(['e5?', 'Nf3', 'Nc6'], comment: '[%loss 1.80]'),
            ],
          },
        ),
        detail: MoveAnnotationDetail.none,
      );

      expect(
        movetextOf(pgn),
        '1. e4 c5 (1... e5? {[%loss 1.80]} 2. Nf3 Nc6) *',
      );
    });

    test('an empty variation list writes nothing', () {
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course'},
          movesSan: ['e4'],
          variations: {0: []},
        ),
        detail: MoveAnnotationDetail.none,
      );

      expect(movetextOf(pgn), '1. e4 *');
    });
  });

  group('headers', () {
    test('a standard start emits no FEN pair', () {
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course'},
          movesSan: ['e4'],
          startFen: kStandardStartFen,
        ),
        detail: MoveAnnotationDetail.none,
      );

      expect(pgn, isNot(contains('FEN')));
      expect(pgn, isNot(contains('SetUp')));
    });

    test('empty header values are dropped rather than written blank', () {
      final pgn = writePgnGame(
        const PgnGameSpec(
          headers: {'Event': 'Course', 'ECO': ''},
          movesSan: ['e4'],
        ),
        detail: MoveAnnotationDetail.none,
      );

      expect(pgn, contains('[Event "Course"]'));
      expect(pgn, isNot(contains('ECO')));
    });
  });
}
