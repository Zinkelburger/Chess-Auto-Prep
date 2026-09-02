/// Taking an engine pass's annotations onto the loaded game without moving
/// the reader: the same moves with new comments are adopted in place, and
/// anything that is not the same game is refused so the caller reloads.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/pgn/viewer_game_model.dart';

const _header = '[Event "Pin"]\n[Result "*"]\n\n';
const _plain =
    '$_header'
    '1. e4 e5 (1... c5 {Sicilian}) 2. Nf3 Nc6 *\n';
const _annotated =
    '$_header'
    '1. e4 {[%eval 0.20]} e5 {[%eval 0.15]} (1... c5 {Sicilian}) '
    '2. Nf3 \$1 {[%eval 0.25]} Nc6 {[%eval -3.00] [%pv Bb5,a6]} *\n';

ViewerGameModel _loaded(String pgn) {
  final model = ViewerGameModel();
  model.load(PgnGame.parsePgn(pgn));
  return model;
}

void main() {
  test('the same game with new comments is adopted where the reader is', () {
    final m = _loaded(_plain);
    m.goToMainLineMove(3);
    // Black to move after 2. Nf3: a scratch sideline instead of 2... Nc6.
    m.addMove('Nf6', editing: false, allowMainline: false);
    expect(m.hasEphemeralMoves, isTrue);

    final parsed = PgnGame.parsePgn(_annotated);
    expect(m.adoptAnnotations(parsed), isTrue);

    expect(m.mainLineIndex, 3);
    expect(m.hasEphemeralMoves, isTrue, reason: 'analysis in progress kept');
    expect(m.moveHistory[3].comments, ['[%eval -3.00] [%pv Bb5,a6]']);
    expect(m.moveHistory[2].nags, [1]);
    expect(m.variationsByPly[1]!.where((n) => !n.isEphemeral), hasLength(1));
  });

  test('a different mainline is refused', () {
    final m = _loaded(_plain);
    expect(
      m.adoptAnnotations(
        PgnGame.parsePgn(
          '$_header'
          '1. e4 e5 2. Nf3 Nf6 *',
        ),
      ),
      isFalse,
    );
    expect(
      m.adoptAnnotations(
        PgnGame.parsePgn(
          '$_header'
          '1. e4 e5 2. Nf3 *',
        ),
      ),
      isFalse,
    );
    expect(m.moveHistory[0].comments, isNull, reason: 'left untouched');
  });

  test('a different set of stored sidelines is refused', () {
    final m = _loaded(_plain);
    expect(
      m.adoptAnnotations(
        PgnGame.parsePgn(
          '$_header'
          '1. e4 {[%eval 0.20]} e5 2. Nf3 Nc6 *',
        ),
      ),
      isFalse,
      reason: 'the Sicilian sideline is gone',
    );
    expect(
      m.adoptAnnotations(
        PgnGame.parsePgn(
          '$_header'
          '1. e4 e5 (1... c5) (1... e6) 2. Nf3 Nc6 *',
        ),
      ),
      isFalse,
      reason: 'a sideline was added',
    );
  });
}
