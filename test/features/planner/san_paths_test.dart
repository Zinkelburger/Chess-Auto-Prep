import 'package:chess_auto_prep/features/planner/services/san_paths.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fenAfterSanPath', () {
    test('plays a legal path from the initial position', () {
      expect(fenAfterSanPath(const []), Chess.initial.fen);
      expect(
        fenAfterSanPath(['e4', 'c5']),
        'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
      );
    });

    test('is null for an illegal or malformed move', () {
      expect(fenAfterSanPath(['e4', 'Kxe8']), isNull);
      expect(fenAfterSanPath(['e4', '??']), isNull);
    });
  });

  group('sanPathStartsWith', () {
    test('matches the path itself and any continuation', () {
      expect(sanPathStartsWith(['d4', 'd5'], ['d4', 'd5']), isTrue);
      expect(sanPathStartsWith(['d4', 'd5', 'c4'], ['d4', 'd5']), isTrue);
      expect(sanPathStartsWith(['d4'], const []), isTrue);
    });

    test('rejects a longer or diverging prefix', () {
      expect(sanPathStartsWith(['d4'], ['d4', 'd5']), isFalse);
      expect(sanPathStartsWith(['d4', 'Nf6'], ['d4', 'd5']), isFalse);
    });
  });

  test('sanPathKey joins moves with single spaces', () {
    expect(sanPathKey(['d4', 'd5', 'c4']), 'd4 d5 c4');
    expect(sanPathKey(const []), '');
  });
}
