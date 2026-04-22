import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/repertoire_service.dart';

void main() {
  test('parseRepertoirePgn uses FEN headers for line start positions', () {
    const startingFen =
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
    final pgn = [
      '[Event "Custom Root"]',
      '[White "Repertoire"]',
      '[Black "Opponent"]',
      '[FEN "$startingFen"]',
      '[SetUp "1"]',
      '',
      '2. Nf3 *',
    ].join('\n');

    final lines = RepertoireService().parseRepertoirePgn(pgn);

    expect(lines, hasLength(1));
    expect(lines.single.startPosition.fen, startingFen);
    expect(lines.single.moves, ['Nf3']);
  });
}
