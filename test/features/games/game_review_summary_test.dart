/// Review summaries derived from stored `[%eval]` comments: counted for the
/// user's side only, null when the game isn't analyzed, and the chip label
/// shows the worst category.
library;

import 'package:chess_auto_prep/features/games/services/game_review_summary.dart';
import 'package:flutter_test/flutter_test.dart';

const _foolsMate =
    '[Event "Test"]\n'
    '[White "A"]\n'
    '[Black "B"]\n'
    '[Result "0-1"]\n'
    '\n'
    '1. f3 { [%eval 0.00,18] } e5 { [%eval -0.5,18] } '
    '2. g4 { [%eval -6.0,18] } Qh4# 0-1\n';

const _unanalyzed =
    '[Event "Test"]\n'
    '[White "A"]\n'
    '[Black "B"]\n'
    '[Result "1-0"]\n'
    '\n'
    '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0\n';

void main() {
  test('counts only my side\'s mistakes', () {
    final asWhite = summarizeGameReview(_foolsMate, meWhite: true);
    expect(asWhite, isNotNull);
    expect(asWhite!.blunders, 1); // 2. g4
    expect(asWhite.mistakes, 0);
    expect(asWhite.clean, isFalse);
    expect(asWhite.breakdown, contains('1 blunder'));

    final asBlack = summarizeGameReview(_foolsMate, meWhite: false);
    expect(asBlack, isNotNull);
    // Black played fine (the mating move is a board fact, not a swing).
    expect(asBlack!.clean, isTrue);
    expect(asBlack.breakdown, contains('no blunders'));
  });

  test('keeps the counted moves as moments, with the position they were '
      'played in', () {
    final asWhite = summarizeGameReview(_foolsMate, meWhite: true)!;
    expect(asWhite.moments, hasLength(1));
    final m = asWhite.moments.single;
    expect(m.ply, 3);
    expect(m.san, 'g4');
    expect(m.fenBefore, startsWith('rnbqkbnr/pppp1ppp/8/4p3/8/5P2/PPPPP1PP/'));
    expect(m.scoreCp, -600);
    expect(m.bestSan, isNull, reason: 'no [%pv] stored');
    expect(asWhite.hasMoments, isTrue);

    final asBlack = summarizeGameReview(_foolsMate, meWhite: false)!;
    expect(asBlack.moments, isEmpty);
  });

  test('withMoments keeps the counts and swaps the moves', () {
    const stored = GameReviewSummary(blunders: 1, mistakes: 0, inaccuracies: 0);
    final parsed = summarizeGameReview(_foolsMate, meWhite: true)!;
    final merged = stored.withMoments(parsed.moments);
    expect(merged.blunders, 1);
    expect(merged.moments, parsed.moments);
  });

  test('a game without eval comments is not analyzed', () {
    expect(summarizeGameReview(_unanalyzed, meWhite: true), isNull);
  });

  test('unknown side or malformed PGN yields null, not a throw', () {
    expect(summarizeGameReview(_foolsMate, meWhite: null), isNull);
    expect(summarizeGameReview('not a pgn at all', meWhite: true), isNull);
  });

  test('batch form maps each (pgn, side) pair', () {
    final out = computeReviewSummariesBatch([
      (_foolsMate, true),
      (_unanalyzed, true),
      (_foolsMate, null),
    ]);
    expect(out, hasLength(3));
    expect(out[0], isNotNull);
    expect(out[1], isNull);
    expect(out[2], isNull);
  });

  test('the breakdown names every category, pluralized', () {
    const mixed = GameReviewSummary(blunders: 2, mistakes: 1, inaccuracies: 3);
    expect(
      mixed.breakdown,
      'Analyzed: 2 blunders, 1 mistake, 3 inaccuracies.',
      reason: 'all three counts, not just the worst',
    );
    const one = GameReviewSummary(blunders: 1, mistakes: 0, inaccuracies: 1);
    expect(one.breakdown, contains('1 blunder,'));
    expect(one.breakdown, contains('1 inaccuracy.'));
  });
}
