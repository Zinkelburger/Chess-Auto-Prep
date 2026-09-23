import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/workspace/explorer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';

const empty = ExplorerAnswer(moves: [], games: []);

/// A position [ply] plies deep; only the counters matter here.
Fen deep(int ply) {
  final move = ply ~/ 2 + 1;
  final side = ply.isEven ? 'w' : 'b';
  return Fen('8/8/8/8/8/8/8/K6k $side - - 0 $move');
}

/// The first [ply] moves down [branch] from the start. The moves are only
/// names: the count of empty answers looks at the line, not the chess.
ExplorerLine down(String branch, int ply) =>
    ExplorerLine(Fen.initial, [for (var i = 0; i < ply; i++) '$branch$i']);

void main() {
  late ExplorerAnswers answers;
  const choice = ExplorerChoice.defaults;

  setUp(() => answers = ExplorerAnswers());

  test('an answer is kept by choice and position', () {
    answers.remember(Fen.initial, choice, startAnswer, down('a', 0));
    expect(answers.at(Fen.initial, choice), same(startAnswer));
    const other = ExplorerChoice(source: ExplorerSource.twic);
    expect(answers.at(Fen.initial, other), isNull);
    answers.forget(Fen.initial, choice);
    expect(answers.at(Fen.initial, choice), isNull);
  });

  test('three empty answers down a line stop the asking below them', () {
    for (final ply in [8, 9, 10]) {
      expect(answers.pastEmpties(down('a', ply + 1)), isFalse);
      answers.remember(deep(ply), choice, empty, down('a', ply));
    }
    expect(answers.pastEmpties(down('a', 11)), isTrue);
    expect(answers.pastEmpties(down('a', 7)), isFalse, reason: 'above it');
    answers.resetEmpties();
    expect(answers.pastEmpties(down('a', 11)), isFalse);
  });

  test('empty answers down one branch stop nothing on another, however '
      'deep', () {
    for (final ply in [11, 12, 13]) {
      answers.remember(deep(ply), choice, empty, down('a', ply));
    }
    expect(answers.pastEmpties(down('a', 20)), isTrue);
    expect(answers.pastEmpties(down('b', 14)), isFalse);
    expect(answers.pastEmpties(down('b', 30)), isFalse);
    final aside = ExplorerLine(Fen.initial, [...down('a', 12).moves, 'x', 'y']);
    expect(answers.pastEmpties(aside), isFalse, reason: 'left before 13');
    final elsewhere = ExplorerLine(deep(0), down('a', 20).moves);
    expect(answers.pastEmpties(elsewhere), isFalse, reason: 'another root');
  });

  test('an empty answer off the line starts the count again', () {
    answers
      ..remember(deep(8), choice, empty, down('a', 8))
      ..remember(deep(9), choice, empty, down('a', 9))
      ..remember(deep(9), choice, empty, down('b', 9))
      ..remember(deep(10), choice, empty, down('b', 10));
    expect(answers.pastEmpties(down('b', 11)), isFalse, reason: 'two, not 4');
    answers.remember(deep(11), choice, empty, down('b', 11));
    expect(answers.pastEmpties(down('b', 12)), isTrue);
  });

  test('an answer with games starts the count again', () {
    answers
      ..remember(deep(8), choice, empty, down('a', 8))
      ..remember(deep(9), choice, empty, down('a', 9))
      ..remember(deep(10), choice, startAnswer, down('a', 10))
      ..remember(deep(11), choice, empty, down('a', 11));
    expect(answers.pastEmpties(down('a', 12)), isFalse);
  });

  test('the oldest answer goes past the cache size', () {
    // Told apart by the en passant field, which is enough for a key.
    Fen distinct(int n) => Fen('8/8/8/8/8/8/8/K6k w - x$n 0 1');
    for (var n = 0; n <= ExplorerAnswers.cacheSize; n++) {
      answers.remember(distinct(n), choice, startAnswer, down('a', 0));
    }
    expect(answers.at(distinct(0), choice), isNull);
    expect(answers.at(distinct(1), choice), isNotNull);
  });

  test('ply counts from the start', () {
    expect(plyOf(Fen.initial), 0);
    expect(plyOf(deep(9)), 9);
  });
}
