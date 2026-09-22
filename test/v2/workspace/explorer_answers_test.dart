import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/explorer_choice.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/workspace/explorer_answers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';

const empty = ExplorerAnswer(moves: [], games: []);

/// A position [ply] plies deep; only the counters matter here.
Fen deep(int ply) {
  final move = ply ~/ 2 + 1;
  final side = ply.isEven ? 'w' : 'b';
  return Fen('8/8/8/8/8/8/8/K6k $side - - 0 $move');
}

void main() {
  late ExplorerAnswers answers;
  const choice = ExplorerChoice.defaults;

  setUp(() => answers = ExplorerAnswers());

  test('an answer is kept by choice and position', () {
    answers.remember(Fen.initial, choice, startAnswer);
    expect(answers.at(Fen.initial, choice), same(startAnswer));
    const other = ExplorerChoice(source: ExplorerSource.twic);
    expect(answers.at(Fen.initial, other), isNull);
    answers.forget(Fen.initial, choice);
    expect(answers.at(Fen.initial, choice), isNull);
  });

  test('three empty answers down a line stop the asking below them', () {
    for (final ply in [8, 9, 10]) {
      expect(answers.pastEmpties(ply + 1), isFalse);
      answers.remember(deep(ply), choice, empty);
    }
    expect(answers.pastEmpties(11), isTrue);
    expect(answers.pastEmpties(7), isFalse, reason: 'above the line');
    answers.resetEmpties();
    expect(answers.pastEmpties(11), isFalse);
  });

  test('an answer with games starts the count again', () {
    answers
      ..remember(deep(8), choice, empty)
      ..remember(deep(9), choice, empty)
      ..remember(deep(10), choice, startAnswer)
      ..remember(deep(11), choice, empty);
    expect(answers.pastEmpties(12), isFalse);
  });

  test('the oldest answer goes past the cache size', () {
    // Told apart by the en passant field, which is enough for a key.
    Fen distinct(int n) => Fen('8/8/8/8/8/8/8/K6k w - x$n 0 1');
    for (var n = 0; n <= ExplorerAnswers.cacheSize; n++) {
      answers.remember(distinct(n), choice, startAnswer);
    }
    expect(answers.at(distinct(0), choice), isNull);
    expect(answers.at(distinct(1), choice), isNotNull);
  });

  test('ply counts from the start', () {
    expect(plyOf(Fen.initial), 0);
    expect(plyOf(deep(9)), 9);
  });
}
