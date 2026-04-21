import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/repertoire_controller.dart';

void main() {
  test('setPositionFromMoveHistory preserves full move history from startpos',
      () {
    final controller = RepertoireController();
    const fen =
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';
    const moves = ['e4', 'e5', 'Nf3'];

    final success = controller.setPositionFromMoveHistory(
      fen: fen,
      moves: moves,
    );

    expect(success, isTrue);
    expect(controller.currentMoveSequence, moves);
    expect(controller.currentMoveIndex, 2);
    expect(controller.fen, fen);
  });

  test('setPositionFromMoveHistory supports custom starting positions', () {
    final controller = RepertoireController();
    const startingFen =
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
    const fen =
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';

    final success = controller.setPositionFromMoveHistory(
      fen: fen,
      moves: const ['Nf3'],
      startingFen: startingFen,
    );

    expect(success, isTrue);
    expect(controller.currentMoveSequence, ['Nf3']);
    expect(controller.fen, fen);
    expect(controller.startingFen, startingFen);
  });
}
