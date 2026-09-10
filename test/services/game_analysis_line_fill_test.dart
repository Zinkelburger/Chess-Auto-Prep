/// A stored eval series restores each move's engine line from its `[%pv]`,
/// says which classified moves have none, and can write lines back onto the
/// movetext beside the scores already there — the pure halves of the fill
/// that runs when a review-pass graph opens without lines on its mistakes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart';

import 'package:chess_auto_prep/services/game_analysis_controller.dart';

const _header =
    '[Event "Test"]\n'
    '[White "A"]\n'
    '[Black "B"]\n'
    '[Result "*"]\n'
    '\n';

/// Eight plies, every one scored; White throws the game away on move 4 and
/// Black hands most of it back on move 4. Only the first blunder has a line.
const _series =
    '$_header'
    '1. e4 {[%eval 0.20,12]} e5 {[%eval 0.15,12]} '
    '2. Nf3 {[%eval 0.25,12]} Nc6 {[%eval 0.20,12]} '
    '3. Bb5 {[%eval 0.30,12]} a6 {[%eval 0.30,12]} '
    '4. Ng5 {[%eval -6.00,12] [%pv Ba4,Nf6]} Nf6 {[%eval -0.50,12]} *\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a stored [%pv] restores the move\'s best line', () async {
    final controller = GameAnalysisController();
    addTearDown(controller.dispose);
    expect(await controller.tryLoadFromPgn(_series), isTrue);

    final ng5 = controller.evals.firstWhere((e) => e.san == 'Ng5');
    expect(ng5.classification, MoveClassification.blunder);
    expect(ng5.bestLine, ['Ba4', 'Nf6']);
    expect(ng5.needsBestLine, isFalse);
  });

  test('classified moves without a line are the ones to fill', () async {
    final controller = GameAnalysisController();
    addTearDown(controller.dispose);
    await controller.tryLoadFromPgn(_series);

    final missing = controller.movesMissingBestLine;
    expect(missing.map((e) => e.san), ['Nf6']);
    expect(missing.single.classification, isNot(MoveClassification.normal));
    // Normal moves never need a line, stored or not.
    final e4 = controller.evals.firstWhere((e) => e.san == 'e4');
    expect(e4.needsBestLine, isFalse);
  });

  // The exact text matters: it replaces the game in the reader's file. The
  // spacing inside the braces and the trailing terminator are dartchess's
  // `makePgn`, which `injectBestLines` now goes through so that a game's
  // sidelines and opening comment survive the rewrite — the old mainline-only
  // writer dropped both. Both are valid PGN and both round-trip: every
  // `[%...]` reader here searches within the comment, so the inner spaces are
  // immaterial, and `*` is the terminator this game's `[Result "*"]` implies.
  test('injectBestLines writes the line beside the existing score', () {
    final movetext = injectBestLines(_series, {
      8: ['Qxg5', 'd3'],
    });
    expect(movetext, contains('[%bestline Ba4,Nf6]'));
    expect(movetext, contains('[%bestline Qxg5,d3]'));
    final game = PgnGame.parsePgn('$_header$movetext');
    final parents = <PgnNode<PgnNodeData>>[];
    var parent = game.moves;
    while (parent.children.isNotEmpty) {
      parents.add(parent);
      parent = parent.children.first;
    }
    expect(parents[6].children[1].data.san, 'Ba4');
    expect(parents[6].children[1].children.single.data.san, 'Nf6');
    expect(parents[7].children[1].data.san, 'Qxg5');
    expect(parents[7].children[1].children.single.data.san, 'd3');
    expect(game.moves.mainline().map((n) => n.san), [
      'e4',
      'e5',
      'Nf3',
      'Nc6',
      'Bb5',
      'a6',
      'Ng5',
      'Nf6',
    ]);
  });

  test('a rewritten game keeps its sidelines and its opening comment', () {
    const withExtras =
        '$_header'
        '{intro [%clk 0:05:00]} 1. e4 {[%eval 0.20,12]} (1. d4 d5) '
        'e5 {[%eval 0.15,12]} 2. Nf3 {[%eval 0.25,12]} '
        'Nc6 {[%eval 6.00,12]} *\n';
    final movetext = injectBestLines(withExtras, {
      4: ['Nf6', 'Bc4'],
    });
    expect(movetext, isNotNull);
    expect(movetext, contains('[%bestline Nf6,Bc4]'));
    expect(movetext, contains('d4'), reason: 'the sideline survived');
    expect(
      movetext,
      contains('[%clk 0:05:00]'),
      reason: 'the game comment survived',
    );
  });

  test('injectBestLines is null when it has nothing to write', () {
    expect(injectBestLines(_series, const {}), isNull);
    expect(
      injectBestLines(_series, {
        99: const ['e4'],
      }),
      isNull,
    );
    expect(injectBestLines(_series, {8: const []}), isNull);
  });

  test('a line written back is read back on the next load', () async {
    final movetext = injectBestLines(_series, {
      8: ['Qxg5', 'd3'],
    })!;
    final controller = GameAnalysisController();
    addTearDown(controller.dispose);
    await controller.tryLoadFromPgn('$_header$movetext\n');
    expect(controller.movesMissingBestLine, isEmpty);
    final nf6 = controller.evals.firstWhere((e) => e.san == 'Nf6');
    expect(nf6.bestLine, ['Qxg5', 'd3']);
  });
}
