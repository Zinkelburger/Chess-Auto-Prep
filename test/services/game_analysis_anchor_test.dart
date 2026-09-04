/// Every path that turns a game's `[%eval]` series into ?!/?/?? marks measures
/// the first move against an anchor, and they must all use the same one.
///
/// A review pass persists movetext — `[%eval]` lives on moves, and nothing
/// carries the engine's score for the *starting* position onto disk. So a
/// reader cannot recover one, and a writer that assumes one produces marks the
/// stored game disagrees with: the live pass anchored on the engine's start
/// eval (about +0.25) while [parseCachedEvals] and the movetext's marker pass
/// both restarted at an even game, so a borderline first move was marked
/// during the run and unmarked the next time the game was opened.
library;

import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:flutter_test/flutter_test.dart';

String _game(String movetext) =>
    '[Event "Test"]\n'
    '[White "W"]\n'
    '[Black "B"]\n'
    '[Result "*"]\n'
    '\n'
    '$movetext *\n';

void main() {
  group('initialWinChance', () {
    test('is an even game', () {
      expect(initialWinChance(), 0.0);
    });

    test('is what a swing of exactly one threshold is measured from', () {
      // classifyMove reads the drop from the anchor, so an anchor that is not
      // 0 shifts every first-move verdict by its own size.
      expect(
        classifyMove(initialWinChance() - -0.30),
        MoveClassification.blunder,
      );
      expect(
        classifyMove(initialWinChance() - -0.20),
        MoveClassification.mistake,
      );
      expect(
        classifyMove(initialWinChance() - -0.10),
        MoveClassification.inaccuracy,
      );
      expect(
        classifyMove(initialWinChance() - -0.09),
        MoveClassification.normal,
      );
    });
  });

  group('parseCachedEvals anchors the first move on an even game', () {
    test('reports the shared anchor, not a guess at the start eval', () {
      final parsed = parseCachedEvals(
        _game('1. e4 {[%eval 0.30]} e5 {[%eval 0.25]}'),
      );
      expect(parsed, isNotNull);
      expect(parsed!.startWinChance, initialWinChance());
    });

    test('a first move that throws the game away is a blunder', () {
      // -2.00 sits at a winning chance near -0.35: a 0.35 drop from an even
      // game, comfortably past the 0.30 blunder threshold.
      final parsed = parseCachedEvals(
        _game('1. g4 {[%eval -2.00]} e5 {[%eval -1.90]}'),
      );
      expect(parsed, isNotNull);
      expect(parsed!.evals.first.san, 'g4');
      expect(parsed.evals.first.classification, MoveClassification.blunder);
    });

    test('a quiet first move is not marked', () {
      final parsed = parseCachedEvals(
        _game('1. e4 {[%eval 0.30]} e5 {[%eval 0.25]}'),
      );
      expect(parsed!.evals.first.classification, MoveClassification.normal);
    });

    test('a reply that hands the game back is the mover\'s own blunder', () {
      // Black to move at +0.30 plays into +2.50: a swing towards White well
      // past the blunder threshold, measured from White's move, not the anchor.
      final parsed = parseCachedEvals(
        _game('1. e4 {[%eval 0.30]} h5 {[%eval 2.50]}'),
      );
      final black = parsed!.evals[1];
      expect(black.san, 'h5');
      expect(black.classification, MoveClassification.blunder);
    });

    test('the anchor applies to a game that starts from a FEN too', () {
      // A study position White is already winning. The first move holds the
      // advantage, so it is not a mistake — the swing, not the standing
      // evaluation, is what gets classified. Anchoring at an even game must
      // not turn "already winning" into a first-move blunder.
      const fen =
          'r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4';
      final pgn =
          '[Event "Test"]\n'
          '[SetUp "1"]\n'
          '[FEN "$fen"]\n'
          '[Result "*"]\n'
          '\n'
          '4. d3 {[%eval 9.00]} Bc5 {[%eval 9.10]} *\n';
      final parsed = parseCachedEvals(pgn);
      expect(parsed, isNotNull);
      expect(parsed!.startWinChance, initialWinChance());
      expect(parsed.evals.first.san, 'd3');
      expect(
        parsed.evals.first.classification,
        MoveClassification.normal,
        reason:
            'holding a won position is not a blunder, whatever the anchor '
            'thinks the game was worth before the move',
      );
    });
  });
}
