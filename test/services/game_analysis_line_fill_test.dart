/// A stored eval series restores each move's engine line from its `[%pv]`,
/// says which classified moves have none, and can write lines back onto the
/// movetext beside the scores already there — the pure halves of the fill
/// that runs when a review-pass graph opens without lines on its mistakes.
library;

import 'package:flutter_test/flutter_test.dart';

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

  test('injectBestLines writes the line beside the existing score', () {
    final movetext = injectBestLines(_series, {
      8: ['Bxc6', 'dxc6'],
    });
    expect(
      movetext,
      '1. e4 {[%eval 0.20,12]} e5 {[%eval 0.15,12]} '
      '2. Nf3 {[%eval 0.25,12]} Nc6 {[%eval 0.20,12]} '
      '3. Bb5 {[%eval 0.30,12]} a6 {[%eval 0.30,12]} '
      '4. Ng5 {[%eval -6.00,12] [%pv Ba4,Nf6]} '
      'Nf6 {[%eval -0.50,12] [%pv Bxc6,dxc6]}',
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
      8: ['Bxc6', 'dxc6'],
    })!;
    final controller = GameAnalysisController();
    addTearDown(controller.dispose);
    await controller.tryLoadFromPgn('$_header$movetext\n');
    expect(controller.movesMissingBestLine, isEmpty);
    final nf6 = controller.evals.firstWhere((e) => e.san == 'Nf6');
    expect(nf6.bestLine, ['Bxc6', 'dxc6']);
  });
}
