import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/tactics_fixture.dart';

void main() {
  final puzzles = puzzlesOf(
    parseChapter(name: 'Default', text: tacticsSet, game: 0).lines,
  );

  test('every game of the set is a puzzle, in file order', () {
    expect([for (final p in puzzles) p.index], [0, 1, 2, 3, 4]);
    expect(
      [for (final p in puzzles) p.kind],
      [
        MistakeKind.blunder,
        MistakeKind.mistake,
        MistakeKind.inaccuracy,
        MistakeKind.custom,
        MistakeKind.blunder,
      ],
    );
  });

  test('a puzzle is the side to move finding the main line', () {
    final mate = puzzles[0];
    expect(mate.toMove, Side.white);
    expect(mate.answer, ['Qxf7#']);
    expect(mate.movesToFind, 1);
    final two = puzzles[1];
    expect(two.toMove, Side.black);
    expect(two.answer, ['e5', 'Nf3', 'Nc6']);
    expect(two.movesToFind, 2);
  });

  test('the headers say what was played, against whom and when', () {
    final mate = puzzles[0];
    expect(mate.label, '4. Qe2??');
    expect(mate.played, 'Qe2');
    expect(mate.refutation, 'Nd4');
    expect(mate.opponent, 'Rival');
    expect(mate.playedOn, DateTime(2026, 9, 20));
    expect(mate.gameId, 'lichess_abc');
    expect(puzzles[1].label, '1... f6?');
    expect(puzzles[1].opponent, 'Other');
    expect(puzzles[3].label, 'Black to play');
    expect(puzzles[3].playedOn, isNull);
  });

  test('the note before the first move is read as played, before and '
      'after', () {
    final note = puzzles[1].note!;
    expect(note.played, 'f6');
    expect(note.before, '+0.3');
    expect(note.after, '-1.1');
    expect(puzzles[2].note, isNull);
  });

  test('a puzzle never tried is new; the headers give its record', () {
    expect(puzzles[0].stats.isNew, isTrue);
    expect(puzzles[0].stats.successRate, 0);
    final tried = puzzlesOf(
      parseChapter(
        name: 'Default',
        text: tacticsSet.replaceFirst(
          '[FlawTags',
          '[ReviewCount "4"]\n[SuccessCount "3"]\n'
              '[LastReviewed "2026-09-21T08:00:00.000"]\n'
              '[TimeToSolve "12.5"]\n[StarRating "2"]\n[FlawTags',
        ),
        game: 0,
      ).lines,
    ).first.stats;
    expect(tried.reviews, 4);
    expect(tried.successRate, 0.75);
    expect(tried.lastReviewed, DateTime(2026, 9, 21, 8));
    expect(tried.seconds, 12.5);
    expect(tried.stars, 2);
  });

  test('search matches players, dates and the move, word by word', () {
    final mate = puzzles[0];
    expect(mate.matches('rival'), isTrue);
    expect(mate.matches('2026.09.20 qe2'), isTrue);
    expect(mate.matches('rival other'), isFalse);
    expect(mate.matches('  '), isTrue);
  });
}
