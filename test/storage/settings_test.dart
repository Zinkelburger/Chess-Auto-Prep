import 'package:chess_auto_prep/storage/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the rating rows stay inside what the model was trained on', () {
    expect((Settings.minElo, Settings.maxElo), (1100, 2900));
  });

  test('the gap threshold runs from five games to a thousand', () {
    expect((Settings.minCoverOnceIn, Settings.maxCoverOnceIn), (5, 1000));
  });
}
