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

    test('materializing reuses saved ancestry and retains valid PV suffix', () {
      final m = _loaded('1. e4 e5 2. Nf3 (2. Bc4 Nf6) *');
      final root = m.variationsByPly[2]!.single;
      final reply = root.children.single;
      m.setInlinePreviewPosition(2, reply.position);
      expect(
        m.materializePreviewLine(2, ['Bc4', 'Nf6', 'd3', 'bad'], 2),
        isTrue,
      );
      expect(m.analysisPath, [root, reply]);
      expect(reply.children.single.san, 'd3');
      expect(reply.children.single.isEphemeral, isTrue);
      expect(m.currentPosition.fen, reply.fen);
      expect(m.variationsByPly[2], [root]);
      expect(m.buildAnnotatedMovetext(), isNot(contains('d3')));
    });

    test('preview attachment rejects an unrelated board without mutation', () {
      final m = _loaded('1. e4 e5 *');
      m.setInlinePreviewPosition(1, Chess.initial);
      expect(m.materializePreviewLine(1, ['c5', 'Nf3'], 2), isFalse);
      expect(m.currentPosition.fen, Chess.initial.fen);
      expect(m.variationsByPly, isEmpty);
      expect(m.mainLineIndex, 1);
    });

    test('a Black-to-move setup uses normal preview variation ancestry', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 7';
      final m = _loaded('[FEN "$fen"]\n[SetUp "1"]\n\n7... e5 *');
      var pos = m.startPosition;
      for (final san in ['c5', 'Nf3']) {
        pos = pos.play(pos.parseSan(san)!);
      }
      m.setInlinePreviewPosition(0, pos);
      expect(m.materializePreviewLine(0, ['c5', 'Nf3'], 2), isTrue);
      m.addMove('d6', editing: true, allowMainline: true);
      expect(m.analysisPath.map((n) => n.san), ['c5', 'Nf3', 'd6']);
      expect(m.analysisPath.every((n) => !n.isEphemeral), isTrue);
      expect(m.buildAnnotatedMovetext(), contains('7... c5 8. Nf3 d6'));
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

    test('Chessable dummy intro is promoted onto the mainline', () {
      const pgn =
          '1. Z0 ({Welcome} 1. d4 {We intend to play} Z0 2. Nf3 {and} '
          'Z0 3. e3 {next.}) *';
      final m = _loaded(pgn);
      expect(m.moveHistory.map((n) => n.san), ['d4', '--', 'Nf3', '--', 'e3']);
      expect(
        m.moveHistory.first.startingComments?.join(' '),
        contains('Welcome'),
      );
      expect(
        m.moveHistory.first.comments?.join(' '),
        contains('We intend to play'),
      );
      expect(m.variationsByPly[0], isNull);

      expect(m.goToMainLineMove(5), isTrue);
      expect(
        m.currentPosition.fen.split(' ')[0],
        'rnbqkbnr/pppppppp/8/8/3P4/4PN2/PPP2PPP/RNBQKB1R',
      );
      expect(m.currentPosition.turn, Side.black);
    });
  });
}
