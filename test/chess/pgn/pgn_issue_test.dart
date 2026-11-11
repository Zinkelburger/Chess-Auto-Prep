import 'package:chess_auto_prep/chess/pgn/pgn_issue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a place is counted in lines and columns from one', () {
    expect(placeOf('abc', 0), (line: 1, column: 1));
    expect(placeOf('ab\ncd', 4), (line: 2, column: 2));
    expect(placeOf('\nab', 2), (
      line: 2,
      column: 2,
    ), reason: 'a newline that starts the text ends its first line');
    expect(placeOf('ab', 9), (line: 1, column: 3), reason: 'past the end');
  });
}
