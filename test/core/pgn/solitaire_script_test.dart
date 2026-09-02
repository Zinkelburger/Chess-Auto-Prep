import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/pgn/solitaire_script.dart';
import 'package:chess_auto_prep/core/pgn/viewer_game_model.dart';

ViewerGameModel _load(String movetext) {
  final m = ViewerGameModel();
  m.load(PgnGame.parsePgn('[Event "?"]\n\n$movetext'));
  return m;
}

String _shape(SolitaireScript s) => s.steps
    .map(
      (st) =>
          '${st.isPremise ? '!' : ''}${st.san}'
          '${st.isMainline ? '@${st.mainlinePly}' : '/${st.branchPly}'}',
    )
    .join(' ');

void main() {
  test('a plain session is the mainline from the start', () {
    final s = buildSolitaireScript(_load('1. e4 e5 2. Nf3 Nc6 *'));
    expect(_shape(s), 'e4@0 e5@1 Nf3@2 Nc6@3');
    expect(s.startMainlinePly, 0);
    expect(s.includesVariations, isFalse);
    expect(s.userMoveCount(true), 2);
    expect(s.userMoveCount(false), 2);
  });

  test('starting from a ply leaves the moves before it out', () {
    final s = buildSolitaireScript(
      _load('1. e4 e5 2. Nf3 Nc6 *'),
      fromMainlinePly: 2,
    );
    expect(_shape(s), 'Nf3@2 Nc6@3');
    expect(s.startMainlinePly, 2);
    expect(s.steps.first.before.fullmoves, 2);
  });

  test('sidelines are skipped unless asked for', () {
    final s = buildSolitaireScript(_load('1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *'));
    expect(_shape(s), 'e4@0 e5@1 Nf3@2');
  });

  test(
    'a variations drill walks each sideline right after the move it replaces, '
    'opening it with a shown premise',
    () {
      final s = buildSolitaireScript(
        _load('1. e4 e5 (1... c5 2. Nf3 Nc6) 2. Nf3 Nc6 *'),
        includeVariations: true,
      );
      expect(_shape(s), 'e4@0 e5@1 !c5/1 Nf3/1 Nc6/1 Nf3@2 Nc6@3');
      expect(s.includesVariations, isTrue);
      // The premise is never asked, whichever side it belongs to.
      expect(s.userMoveCount(false), 3, reason: 'e5, Nc6 (sideline), Nc6');
      expect(s.userMoveCount(true), 3, reason: 'e4, Nf3 (sideline), Nf3');
    },
  );

  test('nested alternatives follow the move they replace', () {
    final s = buildSolitaireScript(
      _load('1. e4 e5 (1... c5 2. Nf3 (2. Nc3 Nc6) d6) 2. Nf3 *'),
      includeVariations: true,
    );
    expect(_shape(s), 'e4@0 e5@1 !c5/1 Nf3/1 !Nc3/1 Nc6/1 d6/1 Nf3@2');
    final nested = s.steps.where((st) => st.san == 'Nc6').single;
    expect(nested.parentNode?.san, 'Nc3');
  });

  test('sideline steps know the node they are played from', () {
    final s = buildSolitaireScript(
      _load('1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *'),
      includeVariations: true,
    );
    final premise = s.steps[2];
    final reply = s.steps[3];
    expect(premise.parentNode, isNull, reason: 'roots hang off the mainline');
    expect(reply.parentNode?.id, premise.node?.id);
    expect(reply.before.fen, premise.node?.fen);
  });

  test('null-move plies are walked through, never asked', () {
    final s = buildSolitaireScript(_load('1. d4 -- 2. Nf3 *'));
    expect(_shape(s), 'd4@0 Nf3@2');
  });

  test('scratch (ephemeral) lines are not part of a drill', () {
    final m = _load('1. e4 e5 2. Nf3 *');
    m.goToMainLineMove(1);
    m.recordVariationMove('d4');
    final s = buildSolitaireScript(m, includeVariations: true);
    expect(_shape(s), 'e4@0 e5@1 Nf3@2');
  });
}
