import 'package:chess_auto_prep/storage/saved_place.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the first game of a file is a place; a negative one is not', () {
    expect(SavedPlace.fromJson({'mode': 'viewer', 'game': 0})?.game, 0);
    expect(SavedPlace.fromJson({'mode': 'viewer', 'game': -1})?.game, isNull);
  });
}
