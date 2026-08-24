/// Writing a pass's per-ply scores onto a game's moves: the scores land on the
/// moves they belong to, the annotations already there survive, and a series
/// too sparse to be believed is refused rather than half-written.
library;

import 'package:chess_auto_prep/features/tactics/services/eval_series_annotator.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const _headers =
    '[Event "Rated blitz game"]\n'
    '[Site "https://lichess.org/abc123"]\n'
    '[White "me"]\n'
    '[Black "opp"]\n'
    '[Result "1-0"]\n';

/// The mainline nodes of a game, which is what the annotator writes onto.
List<PgnNodeData> nodesOf(String movetext) =>
    PgnGame.parsePgn('$_headers\n$movetext').moves.mainline().toList();

void main() {
  test('each score lands on the move whose position it scores', () {
    final nodes = nodesOf('1. e4 e5 2. Nf3 Nc6 1-0');
    final annotated = annotateMovetextWithEvals(
      moveNodes: nodes,
      plyEvals: const [
        PlyEval(cp: 30, depth: 18),
        PlyEval(cp: 12, depth: 18),
        PlyEval(cp: 45, depth: 18),
        PlyEval(cp: 20, depth: 18),
      ],
      lastPlyIsCheckmate: false,
      result: '1-0',
    );

    expect(
      annotated,
      '1. e4 {[%eval 0.30,18]} e5 {[%eval 0.12,18]} '
      '2. Nf3 {[%eval 0.45,18]} Nc6 {[%eval 0.20,18]} 1-0',
    );
  });

  test('scores are White-normalized, not written from the mover\'s view', () {
    final nodes = nodesOf('1. e4 e5 2. Qh5 Nf6 1-0');
    final annotated = annotateMovetextWithEvals(
      moveNodes: nodes,
      // Black is doing well after 2... Nf6, and that reads as a negative
      // number whether or not it was Black who moved.
      plyEvals: const [
        PlyEval(cp: 20, depth: 16),
        PlyEval(cp: 15, depth: 16),
        PlyEval(cp: -60, depth: 16),
        PlyEval(cp: -85, depth: 16),
      ],
      lastPlyIsCheckmate: false,
      result: '1-0',
    );

    final parsed = parseCachedEvals('$_headers\n$annotated');
    expect(parsed, isNotNull);
    expect([for (final e in parsed!.evals) e.scoreCp], [20, 15, -60, -85]);
    expect([for (final e in parsed.evals) e.depth], everyElement(16));
  });

  test('mate scores keep their distance and sign', () {
    final nodes = nodesOf('1. e4 e5 1-0');
    final annotated = annotateMovetextWithEvals(
      moveNodes: nodes,
      plyEvals: const [
        PlyEval(mate: 4, depth: 20),
        PlyEval(mate: -3, depth: 20),
      ],
      lastPlyIsCheckmate: false,
      result: '1-0',
    );

    expect(annotated, contains('[%eval #4,20]'));
    expect(annotated, contains('[%eval #-3,20]'));
    final parsed = parseCachedEvals('$_headers\n$annotated');
    expect([for (final e in parsed!.evals) e.scoreMate], [4, -3]);
  });

  test('the clock comments these games arrive with survive', () {
    final nodes = nodesOf('1. e4 { [%clk 0:03:00] } e5 { [%clk 0:02:58] } 1-0');
    final annotated = annotateMovetextWithEvals(
      moveNodes: nodes,
      plyEvals: const [PlyEval(cp: 30, depth: 18), PlyEval(cp: 12, depth: 18)],
      lastPlyIsCheckmate: false,
      result: '1-0',
    );

    expect(annotated, contains('[%eval 0.30,18] [%clk 0:03:00]'));
    expect(annotated, contains('[%eval 0.12,18] [%clk 0:02:58]'));
  });

  test('a series too sparse to count as analyzed is refused outright', () {
    final nodes = nodesOf('1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0');
    final annotated = annotateMovetextWithEvals(
      moveNodes: nodes,
      // Three of six plies unscored — one more than a reader tolerates.
      plyEvals: const [
        PlyEval(cp: 30, depth: 18),
        null,
        null,
        PlyEval(cp: 20, depth: 18),
        null,
        PlyEval(cp: 25, depth: 18),
      ],
      lastPlyIsCheckmate: false,
      result: '1-0',
    );

    expect(annotated, isNull);
    // Refused *before* writing: the caller's nodes are untouched, so nothing
    // half-annotated can reach the cache.
    expect(nodes.every((n) => n.comments == null), isTrue);
  });

  test('two unscored plies is still a game worth storing', () {
    final nodes = nodesOf('1. e4 e5 2. Nf3 Nc6 1-0');
    final annotated = annotateMovetextWithEvals(
      moveNodes: nodes,
      plyEvals: const [
        PlyEval(cp: 30, depth: 18),
        PlyEval(cp: 12, depth: 18),
        null,
        null,
      ],
      lastPlyIsCheckmate: false,
      result: '1-0',
    );

    expect(annotated, isNotNull);
    expect(parseCachedEvals('$_headers\n$annotated'), isNotNull);
  });

  test('the mating move is excused, not counted against the budget', () {
    // Scholar's mate: the last ply is checkmate, so it carries no score, and
    // two more plies happen to be unscored as well.
    final nodes = nodesOf('1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0');
    final annotated = annotateMovetextWithEvals(
      moveNodes: nodes,
      plyEvals: const [
        PlyEval(cp: 30, depth: 18),
        PlyEval(cp: 15, depth: 18),
        PlyEval(cp: 35, depth: 18),
        null,
        PlyEval(cp: 40, depth: 18),
        null,
        null, // the mate itself
      ],
      lastPlyIsCheckmate: true,
      result: '1-0',
    );

    expect(annotated, isNotNull);
    // Without the excuse this would be three misses and a refusal.
    expect(parseCachedEvals('$_headers\n$annotated'), isNotNull);
  });

  test('a game with no moves has nothing to annotate', () {
    expect(
      annotateMovetextWithEvals(
        moveNodes: const [],
        plyEvals: const [],
        lastPlyIsCheckmate: false,
        result: '*',
      ),
      isNull,
    );
  });
}
