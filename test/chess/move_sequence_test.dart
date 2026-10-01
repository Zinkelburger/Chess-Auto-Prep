import 'package:chess_auto_prep/chess/game_filter.dart';
import 'package:chess_auto_prep/chess/move_sequence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sicilian = ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6'];

  group('reading what was typed', () {
    test('move numbers, results and check marks are not moves', () {
      expect(MoveSequence.parse('1.e4 c5 2. Nf3+ d6 *').groups, [
        ['e4', 'c5', 'Nf3', 'd6'],
      ]);
      expect(MoveSequence.parse('1...c5 2.0-0').groups, [
        ['c5', 'O-O'],
      ]);
    });

    test('a gap marker on its own splits the groups', () {
      expect(MoveSequence.parse('e4 … Nf3 d6').groups, [
        ['e4'],
        ['Nf3', 'd6'],
      ]);
      expect(MoveSequence.parse('e4 ... d6 [gap] Nf6').groups, [
        ['e4'],
        ['d6'],
        ['Nf6'],
      ]);
      expect(MoveSequence.parse('   ').isEmpty, isTrue);
    });
  });

  group('where a main line plays it', () {
    test('a group is consecutive moves, found anywhere', () {
      expect(MoveSequence.parse('Nf3 d6').endIn(sicilian), 4);
      expect(MoveSequence.parse('Nf3 d4').endIn(sicilian), isNull);
    });

    test('after a gap the next group may come any number of plies later', () {
      expect(MoveSequence.parse('e4 … Nxd4').endIn(sicilian), 7);
      expect(MoveSequence.parse('Nxd4 … e4').endIn(sicilian), isNull);
    });

    test('from the start and to the end tie the first and last groups', () {
      final opening = MoveSequence.parse('e4 c5');
      expect(opening.endIn(sicilian, fromStart: true), 2);
      expect(
        MoveSequence.parse('c5 Nf3').endIn(sicilian, fromStart: true),
        isNull,
      );
      expect(opening.endIn(sicilian, fromStart: true, toEnd: true), isNull);
      // A game with fewer moves than the sequence does not start with it.
      expect(opening.endIn(const ['e4'], fromStart: true), isNull);
      expect(opening.endIn(const [], fromStart: true), isNull);
      expect(
        MoveSequence.parse(
          'e4 … Nf6',
        ).endIn(sicilian, fromStart: true, toEnd: true),
        8,
      );
    });
  });

  group('as a rule on the moves', () {
    bool keeps(FilterRule rule, String value, List<String> line) => HeaderRule(
      field: movesField,
      rule: rule,
      value: value,
    ).keeps((_) => null, moves: line);

    test('each rule reads the main line its own way', () {
      expect(keeps(FilterRule.contains, 'd4 cxd4', sicilian), isTrue);
      expect(keeps(FilterRule.excludes, 'd4 cxd4', sicilian), isFalse);
      expect(keeps(FilterRule.startsWith, '1.e4 c5 2.Nf3', sicilian), isTrue);
      expect(keeps(FilterRule.startsWith, 'c5', sicilian), isFalse);
      expect(keeps(FilterRule.equals, 'e4 c5', sicilian), isFalse);
      expect(keeps(FilterRule.regex, r'^e4 c5 Nf3 (d6|Nc6)', sicilian), isTrue);
      expect(keeps(FilterRule.atLeast, '4', sicilian), isTrue);
      expect(keeps(FilterRule.atMost, '3', sicilian), isFalse);
    });

    test('a game whose moves were not given does not pass', () {
      expect(
        const HeaderRule(field: movesField, value: 'e4').keeps((_) => null),
        isFalse,
      );
    });

    test('a filter lands after the sequence it found', () {
      const filter = GameFilter(
        rules: [HeaderRule(field: movesField, value: 'e4 … Nxd4')],
      );
      expect(filter.readsMoves, isTrue);
      expect(filter.reachIn(sicilian), 7);
      expect(byEvent.readsMoves, isFalse);
    });
  });
}

const byEvent = GameFilter(
  rules: [HeaderRule(field: 'Event', value: 'Tata')],
);
