import 'package:chess_auto_prep/v2/chess/game_filter.dart';
import 'package:flutter_test/flutter_test.dart';

/// A game's headers as a lookup, which is what a rule reads.
String? Function(String) headers(Map<String, String> values) =>
    (header) => values[header];

final carlsenWhite = headers({
  'White': 'Carlsen, Magnus',
  'Black': 'Nakamura, Hikaru',
  'WhiteElo': '2830',
  'BlackElo': '2780',
  'Date': '2024.05.01',
  'Event': 'Norway Chess',
});

final clubGame = headers({
  'White': 'Me',
  'Black': 'Rival',
  'WhiteElo': '1500',
  'Date': '2019.01.10',
});

bool keeps(HeaderRule rule, String? Function(String) game) => rule.keeps(game);

void main() {
  test('text rules ignore case: contains, excludes, is', () {
    const contains = HeaderRule(field: 'Event', value: 'norway');
    expect(keeps(contains, carlsenWhite), isTrue);
    expect(keeps(contains, clubGame), isFalse);
    final excludes = contains.copyWith(rule: FilterRule.excludes);
    expect(keeps(excludes, carlsenWhite), isFalse);
    expect(keeps(excludes, clubGame), isTrue, reason: 'no Event excludes it');
    const equals = HeaderRule(
      field: 'White',
      rule: FilterRule.equals,
      value: 'me',
    );
    expect(keeps(equals, clubGame), isTrue);
    expect(keeps(equals.copyWith(value: 'm'), clubGame), isFalse);
  });

  test('≥ and ≤ compare ratings as numbers and dates as text', () {
    const atLeast = HeaderRule(
      field: 'WhiteElo',
      rule: FilterRule.atLeast,
      value: '500',
    );
    expect(keeps(atLeast, carlsenWhite), isTrue, reason: '2830 ≥ 500');
    const noRating = HeaderRule(
      field: 'BlackElo',
      rule: FilterRule.atLeast,
      value: '1000',
    );
    expect(keeps(noRating, clubGame), isFalse);
    const since = HeaderRule(
      field: 'Date',
      rule: FilterRule.atLeast,
      value: '2020.01.01',
    );
    expect(keeps(since, carlsenWhite), isTrue);
    expect(keeps(since, clubGame), isFalse);
    final until = since.copyWith(rule: FilterRule.atMost);
    expect(keeps(until, clubGame), isTrue);
  });

  test('a regex that does not compile matches nothing', () {
    const good = HeaderRule(
      field: 'Black',
      rule: FilterRule.regex,
      value: r'^naka',
    );
    expect(keeps(good, carlsenWhite), isTrue);
    expect(keeps(good.copyWith(value: '(unclosed'), carlsenWhite), isFalse);
  });

  test('Player is either colour, and several names split by ;', () {
    const either = HeaderRule(value: 'nakamura; rival');
    expect(keeps(either, carlsenWhite), isTrue);
    expect(keeps(either, clubGame), isTrue);
    const neither = HeaderRule(rule: FilterRule.excludes, value: 'Me; Hikaru');
    expect(keeps(neither, carlsenWhite), isFalse);
    expect(keeps(neither, clubGame), isFalse);
    expect(
      keeps(
        const HeaderRule(rule: FilterRule.excludes, value: 'Tal'),
        clubGame,
      ),
      isTrue,
    );
  });

  test('a rule with no value keeps everything and is not active', () {
    const blank = HeaderRule(field: 'Event', value: '  ');
    expect(keeps(blank, clubGame), isTrue);
    const filter = GameFilter(rules: [blank]);
    expect(filter.isEmpty, isTrue);
    expect(filter.active, isEmpty);
  });

  test('a filter needs every rule, or with any, one of them', () {
    const rules = [
      HeaderRule(value: 'Carlsen'),
      HeaderRule(field: 'WhiteElo', rule: FilterRule.atMost, value: '2000'),
    ];
    const all = GameFilter(rules: rules);
    expect(all.keeps(carlsenWhite), isFalse);
    expect(all.keeps(clubGame), isFalse);
    final any = all.copyWith(any: true);
    expect(any.keeps(carlsenWhite), isTrue);
    expect(any.keeps(clubGame), isTrue);
    expect(GameFilter.none.keeps(clubGame), isTrue);
  });

  test('a rule reads as its chip, by the names people use', () {
    const rule = HeaderRule(
      field: 'WhiteElo',
      rule: FilterRule.atLeast,
      value: ' 2200 ',
    );
    expect(rule.label, 'White rating ≥ 2200');
    expect(fieldLabel('Annotator'), 'Annotator');
    expect(const GameFilter(rules: [rule]), const GameFilter(rules: [rule]));
  });
}
