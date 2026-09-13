import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/pgn/viewer_game_model.dart';
import 'package:chess_auto_prep/core/pgn/pgn_analysis_variations.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';

const _review =
    '1. e4 {[%eval 0]} e5 {[%eval 0]} '
    '2. Nf3 {[%eval -6] [%pv Bc4,Nf6,d3]} Nc6 {[%eval -6]} *';

void main() {
  test(
    'legacy review becomes one saved, legal RAV and round-trips idempotently',
    () {
      final m = ViewerGameModel()..load(PgnGame.parsePgn(_review));
      expect(m.didMaterializeAnalysis, isTrue);
      expect(m.hasEphemeralMoves, isFalse);
      final root = m.variationsByPly[2]!.single;
      expect(root.san, 'Bc4');
      expect(root.children.single.san, 'Nf6');
      final saved = m.buildAnnotatedMovetext();
      expect(saved, contains('( 2. Bc4 Nf6 3. d3 )'));
      expect(saved, contains('[%bestline Bc4,Nf6,d3]'));
      expect(parseCachedEvals(saved)!.evals[2].bestLine, ['Bc4', 'Nf6', 'd3']);
      m.load(PgnGame.parsePgn(saved));
      expect(m.didMaterializeAnalysis, isFalse);
      expect(m.variationsByPly[2], hasLength(1));
      expect(m.buildAnnotatedMovetext(), saved);
    },
  );

  test(
    'deleting a best line or its suffix stays deleted after save/reload',
    () {
      final m = ViewerGameModel()..load(PgnGame.parsePgn(_review));
      final root = m.variationsByPly[2]!.single;
      m.deleteAnalysisNode(root.children.single.id);
      final shortened = m.buildAnnotatedMovetext();
      expect(shortened, contains('[%bestline Bc4]'));
      m.load(PgnGame.parsePgn(shortened));
      expect(m.variationsByPly[2]!.single.children, isEmpty);
      m.deleteAnalysisNode(m.variationsByPly[2]!.single.id);
      final deleted = m.buildAnnotatedMovetext();
      expect(deleted, isNot(contains('bestline')));
      m.load(PgnGame.parsePgn(deleted));
      expect(m.variationsByPly, isEmpty);
    },
  );

  test(
    'an existing author branch keeps notes and alternatives when reused',
    () {
      final game = PgnGame.parsePgn(
        '1. e4 e5 2. Nf3 {[%pv Bc4,Nf6,d3]} '
        '(2. Bc4 \$1 {Author note} Nc6 {Existing reply}) *',
      );
      expect(materializeAnalysisVariations(game, {2}), isTrue);
      final roots = game.moves.children.single.children.single.children;
      expect(roots, hasLength(2));
      final best = roots[1];
      expect(best.data.comments, ['Author note']);
      expect(best.data.nags, [1]);
      expect(best.children.map((n) => n.data.san), ['Nf6', 'Nc6']);
      expect(best.children[0].children.single.data.san, 'd3');
      expect(materializeAnalysisVariations(game, {2}), isFalse);
    },
  );

  test(
    'setup positions retain Black move numbering and reject illegal suffixes',
    () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 7';
      final m = ViewerGameModel()
        ..load(
          PgnGame.parsePgn(
            '[SetUp "1"]\n[FEN "$fen"]\n\n7... e5 {[%eval 6] [%pv c5,Nf3,invalid]} *',
          ),
        );
      expect(m.variationsByPly[0]!.single.san, 'c5');
      expect(m.buildAnnotatedMovetext(), contains('( 7... c5 8. Nf3 )'));
      expect(m.buildAnnotatedMovetext(), isNot(contains('invalid')));
    },
  );
}
