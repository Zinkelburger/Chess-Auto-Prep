/// Which games of a collection a list shows: rules on their header values,
/// as the old PGN Viewer's `Filter` tab wrote them. Pure values; the owner
/// that applies one to the open file is `workspace/file_filter.dart`.
library;

import 'package:collection/collection.dart';

/// How a rule compares a header with the value typed. `≥` and `≤` compare
/// numbers as numbers — a rating of 2400 is at least 500 — and anything
/// else, such as a `YYYY.MM.DD` date, as text, which orders dates.
enum FilterRule {
  contains('contains'),
  excludes('excludes'),
  equals('is'),
  regex('regex'),
  atLeast('≥'),
  atMost('≤');

  const FilterRule(this.label);

  /// What the rule is called where it is chosen and on its chip.
  final String label;
}

/// Not a header: a rule on this field matches a player of either colour,
/// and its value may name several players split by `;` (a comma is inside
/// `Carlsen, Magnus`).
const playerField = 'Player';

/// The fields a rule is usually about, with what a person calls each; a
/// rule may name any other header as it is spelled in the file.
const filterFields = {
  playerField: 'Player',
  'White': 'White',
  'Black': 'Black',
  'WhiteElo': 'White rating',
  'BlackElo': 'Black rating',
  'Date': 'Date',
  'Event': 'Event',
  'Site': 'Site',
  'Result': 'Result',
  'ECO': 'ECO',
  'Opening': 'Opening',
};

/// What a person calls [field]: its name in [filterFields], else the header
/// as the file spells it.
String fieldLabel(String field) => filterFields[field] ?? field;

/// One condition: [field] compared with [value] by [rule]. A rule with no
/// value keeps every game, so a row being filled in hides nothing.
final class HeaderRule {
  const HeaderRule({
    this.field = playerField,
    this.rule = FilterRule.contains,
    this.value = '',
  });

  /// A header name, or [playerField].
  final String field;
  final FilterRule rule;
  final String value;

  bool get isBlank => value.trim().isEmpty;

  HeaderRule copyWith({String? field, FilterRule? rule, String? value}) =>
      HeaderRule(
        field: field ?? this.field,
        rule: rule ?? this.rule,
        value: value ?? this.value,
      );

  /// `White rating ≥ 2200`, `Player contains Carlsen`: the rule's chip.
  String get label => '${fieldLabel(field)} ${rule.label} ${value.trim()}';

  /// Whether a game whose header values are [headers] passes.
  ///
  /// On [playerField] a game passes when any name typed matches either
  /// player — except for `excludes`, where every name must be missing from
  /// both, which is what "player excludes X" means.
  bool keeps(String? Function(String header) headers) {
    if (isBlank) return true;
    if (field != playerField) return _matches(headers(field) ?? '', value);
    final names = [
      for (final name in value.split(';'))
        if (name.trim().isNotEmpty) name.trim(),
    ];
    final white = headers('White') ?? '';
    final black = headers('Black') ?? '';
    bool either(String name) => _matches(white, name) || _matches(black, name);
    bool both(String name) => _matches(white, name) && _matches(black, name);
    return rule == FilterRule.excludes ? names.every(both) : names.any(either);
  }

  bool _matches(String header, String query) {
    final have = header.trim();
    final want = query.trim();
    return switch (rule) {
      FilterRule.contains => have.toLowerCase().contains(want.toLowerCase()),
      FilterRule.excludes => !have.toLowerCase().contains(want.toLowerCase()),
      FilterRule.equals => have.toLowerCase() == want.toLowerCase(),
      FilterRule.regex => _pattern(want)?.hasMatch(have) ?? false,
      FilterRule.atLeast => _ordered(have, want) >= 0,
      FilterRule.atMost => _ordered(have, want) <= 0,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is HeaderRule &&
      other.field == field &&
      other.rule == rule &&
      other.value == value;

  @override
  int get hashCode => Object.hash(field, rule, value);
}

/// A pattern that does not compile matches nothing, rather than every game.
/// Each is compiled once, not once a game: a filter runs over every game of
/// the file on each change.
RegExp? _pattern(String source) {
  if (_patterns.length > 32) _patterns.clear();
  return _patterns.putIfAbsent(source, () {
    try {
      return RegExp(source, caseSensitive: false);
    } on FormatException {
      return null;
    }
  });
}

final _patterns = <String, RegExp?>{};

/// [a] against [b]: as numbers when both are, else as text. A header that
/// is missing compares as empty text, which is before any date and no
/// rating, so `≥ 2000` leaves out a game without a rating.
int _ordered(String a, String b) {
  final x = num.tryParse(a);
  final y = num.tryParse(b);
  if (x != null && y != null) return x.compareTo(y);
  if (a.isEmpty) return -1;
  return a.compareTo(b);
}

/// Every rule of a list at once, or any one of them.
final class GameFilter {
  const GameFilter({this.rules = const [], this.any = false});

  static const none = GameFilter();

  final List<HeaderRule> rules;

  /// A game passes when one rule keeps it, rather than all of them.
  final bool any;

  /// The rules that say something.
  List<HeaderRule> get active => [
    for (final rule in rules)
      if (!rule.isBlank) rule,
  ];

  /// Whether the filter keeps every game.
  bool get isEmpty => active.isEmpty;

  GameFilter copyWith({List<HeaderRule>? rules, bool? any}) =>
      GameFilter(rules: rules ?? this.rules, any: any ?? this.any);

  bool keeps(String? Function(String header) headers) {
    final rules = active;
    if (rules.isEmpty) return true;
    return any
        ? rules.any((rule) => rule.keeps(headers))
        : rules.every((rule) => rule.keeps(headers));
  }

  @override
  bool operator ==(Object other) =>
      other is GameFilter &&
      other.any == any &&
      const ListEquality<HeaderRule>().equals(other.rules, rules);

  @override
  int get hashCode => Object.hash(any, Object.hashAll(rules));
}
