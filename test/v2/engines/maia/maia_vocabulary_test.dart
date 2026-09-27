import 'package:chess_auto_prep/v2/engines/maia/maia_vocabulary.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shipped_vocabulary.dart';

void main() {
  test('names and indexes are the same table read both ways', () {
    final vocabulary = MaiaVocabulary.parse(
      '{"e2e4": 0, "d2d4": 1, "g1f3": 2}',
    )!;
    expect(vocabulary.size, 3);
    expect(vocabulary.indexOf('d2d4'), 1);
    expect(vocabulary.nameAt(1), 'd2d4');
    expect(vocabulary.indexOf('h2h9'), isNull);
  });

  test('an index nothing is scored at has no name', () {
    final vocabulary = MaiaVocabulary.parse('{"e2e4": 0, "d2d4": 3}')!;
    expect(vocabulary.nameAt(1), '');
    expect(vocabulary.nameAt(4), '');
    expect(vocabulary.nameAt(-1), '');
  });

  test('refuses text that is not a move table', () {
    expect(MaiaVocabulary.parse('not json'), isNull);
    expect(MaiaVocabulary.parse('[1, 2, 3]'), isNull);
    expect(MaiaVocabulary.parse('{}'), isNull);
    expect(MaiaVocabulary.parse('{"e2e4": "first"}'), isNull);
    expect(MaiaVocabulary.parse('{"e2e4": -1}'), isNull);
  });

  test('the shipped table is the grid plus White promotions', () {
    final vocabulary = shippedVocabulary();
    expect(vocabulary.size, 4352);
    expect(vocabulary.nameAt(0), 'a1a1');
    expect(vocabulary.indexOf('e2e4'), 796);
    expect(vocabulary.indexOf('a7a8q'), isNotNull);
    expect(
      vocabulary.indexOf('a2a1q'),
      isNull,
      reason: 'Black promotions reach the network through the mirror',
    );
  });

  test('the shipped table names castling as the king reaching g1', () {
    final vocabulary = shippedVocabulary();
    expect(vocabulary.indexOf('e1g1'), isNotNull);
    expect(vocabulary.indexOf('e1c1'), isNotNull);
  });
}
