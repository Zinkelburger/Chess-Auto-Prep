import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoire/models/repertoire_reload_summary.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';

RepertoireLine _line(
  String name,
  List<String> moves, {
  String? pgn,
  String color = 'white',
}) {
  return RepertoireLine(
    id: name,
    name: name,
    moves: moves,
    color: color,
    startPosition: Chess.initial,
    fullPgn: pgn ?? '[Event "$name"]\n\n${moves.join(' ')} *',
  );
}

void main() {
  group('RepertoireReloadSummary.between', () {
    test('reports nothing when the file is untouched', () {
      final lines = [
        _line('Advance', ['e4', 'c6', 'd4']),
        _line('Exchange', ['e4', 'c6', 'exd5']),
      ];

      final summary = RepertoireReloadSummary.between(lines, lines);

      expect(summary.unchanged, isTrue);
      expect(summary.total, 2);
    });

    test('names the lines the file gained and lost', () {
      final before = [
        _line('Advance', ['e4', 'c6', 'd4']),
        _line('Exchange', ['e4', 'c6', 'exd5']),
      ];
      final after = [
        _line('Advance', ['e4', 'c6', 'd4']),
        _line('Two Knights', ['e4', 'c6', 'Nc3']),
      ];

      final summary = RepertoireReloadSummary.between(before, after);

      expect(summary.unchanged, isFalse);
      expect(summary.added, ['Two Knights']);
      expect(summary.removed, ['Exchange']);
      expect(summary.total, 2);
    });

    test('counts a same-moves line whose PGN body changed as edited', () {
      final before = [
        _line('Advance', ['e4', 'c6', 'd4'], pgn: '1. e4 c6 2. d4 *'),
      ];
      final after = [
        _line('Advance', ['e4', 'c6', 'd4'], pgn: '1. e4 c6 2. d4 {plan} *'),
      ];

      final summary = RepertoireReloadSummary.between(before, after);

      expect(summary.added, isEmpty);
      expect(summary.removed, isEmpty);
      expect(summary.edited, 1);
      expect(summary.unchanged, isFalse);
    });

    // Ids are a truncated move prefix and collide between lines sharing an
    // opening; matching on the full move list is what keeps a quiet file quiet.
    test('does not report churn for lines that share an id prefix', () {
      final lines = [
        _line('A', ['d4', 'Nf6', 'c4', 'e6']),
        _line('B', ['d4', 'Nf6', 'c4', 'g6']),
      ];

      final summary = RepertoireReloadSummary.between(lines, [
        lines[1],
        lines[0],
      ]);

      expect(summary.unchanged, isTrue);
    });

    test('treats the same moves from the other side as a different line', () {
      final before = [
        _line('Ours', ['e4', 'e5'], color: 'white'),
      ];
      final after = [
        _line('Theirs', ['e4', 'e5'], color: 'black'),
      ];

      final summary = RepertoireReloadSummary.between(before, after);

      expect(summary.added, ['Theirs']);
      expect(summary.removed, ['Ours']);
    });

    test('falls back to the opening moves when a line has no name', () {
      final summary = RepertoireReloadSummary.between(const [], [
        _line('', ['e4', 'c5', 'Nf3']),
      ]);

      expect(summary.added, ['e4 c5 Nf3']);
    });

    test('a failed reload carries the message and nothing else', () {
      const summary = RepertoireReloadSummary.failed('disk on fire');

      expect(summary.hasError, isTrue);
      expect(summary.unchanged, isFalse);
      expect(summary.error, 'disk on fire');
    });
  });
}
