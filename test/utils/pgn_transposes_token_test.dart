import 'package:chess_auto_prep/utils/pgn_comment_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('[%transposes] token', () {
    test('parses the move list', () {
      expect(
        parseTransposesToken(
          'Transposes to 1. Nf3 d5 2. d4 Nf6. [%transposes Nf3 d5 d4 Nf6] '
          '[%eval +0.20]',
        ),
        ['Nf3', 'd5', 'd4', 'Nf6'],
      );
      expect(parseTransposesToken('[%eval +0.20]'), isNull);
      expect(parseTransposesToken(null), isNull);
    });

    test('is stripped from displayed prose', () {
      expect(
        filterDisplayComment(
          'Transposes to 1. Nf3 d5 2. d4 Nf6. [%transposes Nf3 d5 d4 Nf6]',
        ),
        'Transposes to 1. Nf3 d5 2. d4 Nf6.',
      );
    });
  });
}
