import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/pgn/viewer_game_model.dart';

ViewerGameModel _loaded(String pgn) {
  final model = ViewerGameModel();
  model.load(PgnGame.parsePgn(pgn));
  return model;
}

void main() {
  group('ViewerGameModel', () {
    test('addMove kinds: follow, extend (editing), sideline', () {
      final m = _loaded('1. e4 e5 *');

      expect(
        m.addMove('e4', editing: false, allowMainline: true),
        ViewerMoveKind.followedMainline,
      );
      expect(m.mainLineIndex, 1);

      expect(
        m.addMove('Nc6', editing: false, allowMainline: true),
        ViewerMoveKind.variation,
      );
      expect(m.hasEphemeralMoves, isTrue);
      expect(m.analysisPath, hasLength(1));

      m.clearAnalysis();
      expect(m.hasEphemeralMoves, isFalse);

      m.goToMainLineMove(2);
      expect(
        m.addMove('Nf3', editing: true, allowMainline: true),
        ViewerMoveKind.extendedMainline,
      );
      expect(m.moveHistory.map((d) => d.san), ['e4', 'e5', 'Nf3']);
    });

    test('editing sidelines are saved; scratch sidelines are not', () {
      final m = _loaded('1. e4 e5 *');
      m.goToMainLineMove(1);
      m.addMove('c5', editing: true, allowMainline: true);

      final out = m.buildAnnotatedMovetext();
      expect(out, contains('c5'));

      final m2 = _loaded('1. e4 e5 *');
      m2.goToMainLineMove(1);
      m2.addMove('c5', editing: false, allowMainline: true);
      expect(m2.buildAnnotatedMovetext(), isNot(contains('c5')));
    });

    test('custom-FEN games carry FEN/SetUp headers in line PGN', () {
      const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
      final m = _loaded('[FEN "$fen"]\n[SetUp "1"]\n\n1. e4 Kd7 *');

      expect(m.moveHistory.map((d) => d.san), ['e4', 'Kd7']);

      final line = m.moveHistory.sublist(0, 1);
      final pgn = m.buildLinePgn(line);
      expect(pgn, contains('[FEN "$fen"]'));
      expect(pgn, contains('[SetUp "1"]'));
      expect(pgn, contains('1. e4'));
    });

    test('lineToVariationNode stitches mainline prefix + sideline path', () {
      final m = _loaded('1. e4 e5 2. Nf3 *');
      m.goToMainLineMove(2);
      m.addMove('f4', editing: false, allowMainline: true);
      m.addMove('exf4', editing: false, allowMainline: true);

      final node = m.analysisPath.last;
      final line = m.lineToVariationNode(node, 2)!;
      expect(line.map((d) => d.san), ['e4', 'e5', 'f4', 'exf4']);
    });

    test(
      'deleteAnalysisNode retreats the cursor out of the deleted subtree',
      () {
        final m = _loaded('1. e4 e5 *');
        m.goToMainLineMove(1);
        m.addMove('c5', editing: false, allowMainline: true);
        m.addMove('Nf3', editing: false, allowMainline: true);
        final deepest = m.analysisPath.last;

        m.deleteAnalysisNode(deepest.id);
        expect(m.analysisPath, hasLength(1));
        expect(m.analysisPath.single.san, 'c5');
        expect(m.currentPosition.fen, m.analysisPath.single.fen);
      },
    );
  });
}
