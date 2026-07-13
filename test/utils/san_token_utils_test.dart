import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/utils/san_token_utils.dart';

void main() {
  group('cleanSanTokens', () {
    test('empty and whitespace-only input', () {
      expect(cleanSanTokens(''), isEmpty);
      expect(cleanSanTokens('   \n\t '), isEmpty);
    });

    test('plain numbered movetext', () {
      expect(
        cleanSanTokens('1. e4 e5 2. Nf3 Nc6'),
        ['e4', 'e5', 'Nf3', 'Nc6'],
      );
    });

    test('glued move numbers', () {
      expect(cleanSanTokens('1.e4 e5 2.Nf3'), ['e4', 'e5', 'Nf3']);
    });

    test('black-continuation ellipsis, spaced and glued', () {
      expect(cleanSanTokens('3... Nf6 4. Ng5'), ['Nf6', 'Ng5']);
      expect(cleanSanTokens('3...Nf6 4.Ng5'), ['Nf6', 'Ng5']);
    });

    test('result tokens stripped', () {
      expect(cleanSanTokens('1. e4 e5 1-0'), ['e4', 'e5']);
      expect(cleanSanTokens('1. d4 d5 0-1'), ['d4', 'd5']);
      expect(cleanSanTokens('1. c4 e5 1/2-1/2'), ['c4', 'e5']);
      expect(cleanSanTokens('1. Nf3 d5 *'), ['Nf3', 'd5']);
    });

    test('NAG tokens stripped', () {
      expect(cleanSanTokens(r'1. e4 $2 e5 $14'), ['e4', 'e5']);
    });

    test('castling survives (not mistaken for a result token)', () {
      expect(
        cleanSanTokens('4. O-O O-O-O 1-0'),
        ['O-O', 'O-O-O'],
      );
    });

    test('check, mate, capture, and promotion notation survive', () {
      expect(
        cleanSanTokens('10. Qxf7+ Kd8 11. e8=Q# 1-0'),
        ['Qxf7+', 'Kd8', 'e8=Q#'],
      );
    });

    test('irregular whitespace', () {
      expect(cleanSanTokens('1.  e4\n e5   2. Nf3'), ['e4', 'e5', 'Nf3']);
    });
  });
}
