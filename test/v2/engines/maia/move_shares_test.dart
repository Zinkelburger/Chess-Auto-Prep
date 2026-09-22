import 'dart:typed_data';

import 'package:chess_auto_prep/v2/engines/maia/maia_vocabulary.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_shares.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in table: index 0 is e2e4, 1 is d2d4, 2 is g1f3.
final MaiaVocabulary _vocabulary = MaiaVocabulary.parse(
  '{"e2e4": 0, "d2d4": 1, "g1f3": 2}',
)!;

Map<String, double> _shares(
  List<double> logits,
  List<double> mask, {
  bool mirrored = false,
}) => sharesFromLogits(
  logits,
  Float32List.fromList(mask),
  mirrored: mirrored,
  vocabulary: _vocabulary,
);

void main() {
  test('the legal moves share the whole of it, likeliest first', () {
    final shares = _shares([1.0, 3.0, 2.0], [1, 0, 1]);
    expect(shares.keys.toList(), ['g1f3', 'e2e4']);
    expect(shares.values.reduce((a, b) => a + b), closeTo(1.0, 1e-9));
    expect(shares['g1f3'], closeTo(0.7311, 1e-4));
    expect(shares['e2e4'], closeTo(0.2689, 1e-4));
  });

  test('a mirrored position answers about the board that was asked about', () {
    final shares = _shares([2.0, 1.0, 0.0], [1, 1, 0], mirrored: true);
    expect(shares.keys.toList(), ['e7e5', 'd7d5']);
    expect(shares['e7e5'], greaterThan(shares['d7d5']!));
  });

  test('a legal move the network had no number for comes out at zero', () {
    final shares = _shares([0.0], [1, 1, 0]);
    expect(shares['e2e4'], closeTo(1.0, 1e-9));
    expect(shares['d2d4'], closeTo(0.0, 1e-9));
  });

  test('an illegal move never appears, however high the network scored it', () {
    final shares = _shares([9.0, 1.0, 2.0], [0, 1, 1]);
    expect(shares.keys, isNot(contains('e2e4')));
    expect(shares.values.reduce((a, b) => a + b), closeTo(1.0, 1e-9));
  });

  test('a position with no legal moves has no shares', () {
    expect(_shares([1.0, 2.0, 3.0], [0, 0, 0]), isEmpty);
  });
}
