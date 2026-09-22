import 'package:chess_auto_prep/v2/ui/name_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a plain name is fine', () {
    expect(nameProblem("King's Indian"), isNull);
    expect(nameProblem('Benoni  x'), isNull);
  });

  test('a name has to be something', () {
    expect(nameProblem('   '), 'Please enter a name.');
  });

  test('a name a filesystem cannot spell is refused', () {
    const message =
        r'Names cannot contain < > : " / \ | ? * or control characters.';
    expect(nameProblem('a/b'), message);
    expect(nameProblem('what?'), message);
    expect(nameProblem('line\nbreak'), message);
  });

  test('a trailing dot or space is refused, as Windows would', () {
    expect(nameProblem('Main '), 'Names cannot end with a dot or space.');
    expect(nameProblem('Main.'), 'Names cannot end with a dot or space.');
  });

  test('the names a directory listing already uses are refused', () {
    expect(nameProblem('.'), 'That name is reserved.');
    expect(nameProblem('..'), 'That name is reserved.');
  });

  test('a name that would hide the folder is refused', () {
    const message =
        'Names cannot start with a dot; the list would not show it.';
    expect(nameProblem('.Sicilian'), message);
    expect(nameProblem('  .hidden'), message);
    expect(nameProblem('e4.e5'), isNull, reason: 'a dot inside is fine');
  });

  test('the names Windows keeps for devices are refused', () {
    const message = 'That name is reserved by the operating system.';
    expect(nameProblem('CON'), message);
    expect(nameProblem('lpt1.pgn'), message);
  });

  test('a name longer than the cap is refused', () {
    expect(nameProblem('a' * 120), isNull);
    expect(nameProblem('a' * 121), 'Names must be 120 characters or fewer.');
  });
}
