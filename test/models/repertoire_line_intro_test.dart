import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/widgets/training/training_lines_panel.dart'
    show formatLineMovesText;
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

RepertoireLine _line(
  List<String> moves, {
  Map<String, String> comments = const {},
  Position? start,
}) {
  return RepertoireLine(
    id: 'test',
    name: 'Test line',
    moves: moves,
    color: 'white',
    startPosition: start ?? Chess.initial,
    fullPgn: '',
    comments: comments,
  );
}

void main() {
  group('uncommentedIntroLength', () {
    test('no comments at all → 0 (whole line trains)', () {
      final line = _line(['e4', 'e6', 'd4', 'd5']);
      expect(line.uncommentedIntroLength, 0);
    });

    test('first prose comment marks the tabiya', () {
      final line = _line(
        ['e4', 'e6', 'd4', 'd5', 'Nc3', 'Bb4'],
        comments: {'4': 'The main line — Black pins next.'},
      );
      expect(line.uncommentedIntroLength, 4);
    });

    test('comment on the very first move → no intro', () {
      final line = _line(['e4', 'e6'], comments: {'0': 'Best by test.'});
      expect(line.uncommentedIntroLength, 0);
    });

    test('engine-token-only comments do not count as annotations', () {
      final line = _line(
        ['e4', 'e6', 'd4', 'd5'],
        comments: {
          '0': '[%eval 0.3]',
          '1': '[%cumProb 12.5%] [%eval 0.2,18]',
          '3': '[%eval 0.1] Now the real fight starts.',
        },
      );
      expect(line.uncommentedIntroLength, 3);
    });
  });

  group('formatLineMovesText', () {
    test('numbers full line from the initial position', () {
      final line = _line(['e4', 'e6', 'd4', 'd5', 'Nc3']);
      expect(formatLineMovesText(line), '1.e4 e6 2.d4 d5 3.Nc3');
    });

    test('slice starting on a black move gets ellipsis numbering', () {
      final line = _line(['e4', 'e6', 'd4', 'd5']);
      expect(formatLineMovesText(line, start: 1), '1...e6 2.d4 d5');
    });

    test('slice with end stops before the tabiya', () {
      final line = _line(['e4', 'e6', 'd4', 'd5']);
      expect(formatLineMovesText(line, end: 2), '1.e4 e6');
    });
  });
}
