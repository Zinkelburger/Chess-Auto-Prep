import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/services/repertoire_color_inference.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

RepertoireLine _line(
  List<String> moves, {
  String id = '',
  bool isModelGame = false,
}) => RepertoireLine(
  id: id.isEmpty ? moves.join(' ') : id,
  name: moves.join(' '),
  moves: moves,
  color: 'white',
  startPosition: Chess.initial,
  fullPgn: '',
  isModelGame: isModelGame,
);

/// A White repertoire: one White answer per position, many Black replies
/// covered.
List<RepertoireLine> _whiteRepertoire() => [
  for (final black in ['c5', 'e5', 'e6', 'c6', 'd5', 'd6', 'g6', 'Nf6'])
    for (final reply in ['a3', 'h3'])
      _line(['e4', black, 'Nf3', reply == 'a3' ? 'Nc6' : 'd6', 'd4']),
];

/// A Black repertoire: many White first moves, one Black answer to each.
List<RepertoireLine> _blackRepertoire() => [
  for (final white in ['e4', 'd4', 'c4', 'Nf3', 'g3', 'b3', 'f4', 'Nc3'])
    for (final second in ['a3', 'h3']) _line([white, 'e6', second, 'd5']),
];

void main() {
  group('inferTrainingColor', () {
    test('reads White from a White-shaped move tree', () {
      final guess = inferTrainingColor(_whiteRepertoire());
      expect(guess, isNotNull);
      expect(guess!.isWhite, isTrue);
      expect(guess.colorName, 'white');
    });

    test('reads Black from a Black-shaped move tree', () {
      final guess = inferTrainingColor(_blackRepertoire());
      expect(guess, isNotNull);
      expect(guess!.isWhite, isFalse);
      expect(guess.colorName, 'black');
    });

    test('says nothing about a file too small to have a shape', () {
      expect(
        inferTrainingColor([
          _line(['e4', 'e5']),
        ]),
        isNull,
      );
      expect(inferTrainingColor(const []), isNull);
    });

    test('falls back to who plays the last move when nothing branches', () {
      // Eight unrelated single-variation lines: no shared prefixes, so the
      // branching signal has nothing to measure.
      final lines = [
        for (var i = 0; i < 8; i++)
          _line(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'B${'a' * (i + 1)}4']),
      ];
      final guess = inferTrainingColor(lines);
      expect(guess, isNotNull);
      expect(guess!.evidence, ColorEvidence.lastMove);
      expect(guess.isWhite, isTrue);
    });

    test('ignores model games, which branch on both sides', () {
      final withModels = [
        ..._blackRepertoire(),
        for (var i = 0; i < 40; i++)
          _line(
            [
              'd4',
              'Nf6',
              'c4',
              'g6',
              'Nc3',
              'Bg7',
              'e4',
              'd6',
              'Nf3',
              'O-O',
              'Be2',
              'e5',
              'O-O',
              'N${'a' * (i + 1)}6',
            ],
            id: 'model$i',
            isModelGame: true,
          ),
      ];
      expect(inferTrainingColor(withModels)?.isWhite, isFalse);
    });
  });

  group('parseRepertoirePgn colour resolution', () {
    const blackCourse = '''
[Event "Course"]
[White "Chapter 1"]
[Black "Line 1"]
[Result "*"]

1. e4 e6 2. d4 d5 *

[Event "Course"]
[White "Chapter 1"]
[Black "Line 2"]
[Result "*"]

1. d4 e6 2. c4 d5 *

[Event "Course"]
[White "Chapter 1"]
[Black "Line 3"]
[Result "*"]

1. c4 e6 2. Nc3 d5 *

[Event "Course"]
[White "Chapter 1"]
[Black "Line 4"]
[Result "*"]

1. Nf3 e6 2. g3 d5 *

[Event "Course"]
[White "Chapter 1"]
[Black "Line 5"]
[Result "*"]

1. g3 e6 2. Bg2 d5 *

[Event "Course"]
[White "Chapter 1"]
[Black "Line 6"]
[Result "*"]

1. b3 e6 2. Bb2 d5 *
''';

    test('assumes White when inference is not asked for', () {
      final lines = RepertoireService().parseRepertoirePgn(blackCourse);
      expect(lines.map((l) => l.color).toSet(), {'white'});
    });

    test('reads the side off the moves when asked to', () {
      final lines = RepertoireService().parseRepertoirePgn(
        blackCourse,
        inferColorWhenUnknown: true,
      );
      expect(lines.map((l) => l.color).toSet(), {'black'});
    });

    test('a declared // Color: still wins over inference', () {
      final lines = RepertoireService().parseRepertoirePgn(
        '// Color: White\n$blackCourse',
        inferColorWhenUnknown: true,
      );
      expect(lines.map((l) => l.color).toSet(), {'white'});
    });

    test('an explicit trainingColor still wins over inference', () {
      final lines = RepertoireService().parseRepertoirePgn(
        blackCourse,
        trainingColor: 'white',
        inferColorWhenUnknown: true,
      );
      expect(lines.map((l) => l.color).toSet(), {'white'});
    });
  });
}
