import 'package:chess_auto_prep/features/planner/models/plan_starting_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses named KID, Fianchetto and London roots with full prefixes', () {
    final roots = PlanStartingLine.parse('''
Main KID | 1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 4. e4 d6 *
Fianchetto KID | 1.d4 Nf6 2.c4 g6 3.Nf3 Bg7 4.g3 d6
London | 1.d4 Nf6 2.Bf4 d5
''');
    PlanStartingLine.validate(roots);
    expect(roots.map((r) => r.name), ['Main KID', 'Fianchetto KID', 'London']);
    expect(roots.first.moves, [
      'd4',
      'Nf6',
      'c4',
      'g6',
      'Nc3',
      'Bg7',
      'e4',
      'd6',
    ]);
    expect(roots[1].moves[6], 'g3');
    expect(roots.last.moves, ['d4', 'Nf6', 'Bf4', 'd5']);
    expect(
      PlanStartingLine.parse(
        roots.map((r) => r.text).join('\n'),
      ).map((r) => r.moves),
      roots.map((r) => r.moves),
    );
  });

  test(
    'invalid move reports its row rather than accepting a truncated path',
    () {
      expect(
        () => PlanStartingLine.parse('1.e4 e5\nLondon | 1.d4 Nf6 2.Kxe8'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'error',
            contains('Line 2'),
          ),
        ),
      );
    },
  );

  test('rejects duplicate positions reached by different move orders', () {
    final roots = PlanStartingLine.parse('1.d4 Nf6 2.c4 e6\n1.c4 e6 2.d4 Nf6');
    expect(
      () => PlanStartingLine.validate(roots),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'error',
          contains('same position'),
        ),
      ),
    );
  });

  test('rejects overlapping roots including the initial position', () {
    for (final text in ['1.d4 Nf6\n1.d4 Nf6 2.c4', 'All |\n1.d4']) {
      expect(
        () => PlanStartingLine.validate(PlanStartingLine.parse(text)),
        throwsFormatException,
      );
    }
    expect(PlanStartingLine.parse('').single.moves, isEmpty);
  });
}
