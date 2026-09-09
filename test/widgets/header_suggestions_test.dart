import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/widgets/slice/header_suggestions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('distinct actual spellings ordered by game count, then name', () {
    final suggestions = HeaderSuggestions(const [
      (headers: {'Event': 'Open [A]'}, pgnText: '*'),
      (headers: {'Event': 'Open [A]'}, pgnText: '*'),
      (headers: {'Event': 'open [A]'}, pgnText: '*'),
      (headers: {'Event': 'Open A'}, pgnText: '*'),
      (headers: {'Event': '  '}, pgnText: '*'),
      (headers: <String, String>{}, pgnText: '*'),
    ]);
    expect(suggestions.matching('Event', 'oPEN ['), [
      (value: 'Open [A]', count: 2),
      (value: 'open [A]', count: 1),
    ]);
    expect(suggestions.matching('Event', ''), [
      (value: 'Open [A]', count: 2),
      (value: 'open [A]', count: 1),
      (value: 'Open A', count: 1),
    ]);
    expect(suggestions.matching('Event', 'opne'), isEmpty);
    expect(suggestions.matching('Event', '.*'), isEmpty);
    expect(suggestions.matching('Event', ' Open'), isEmpty);
    expect(suggestions.matching('Missing', ''), isEmpty);
  });

  test('Player counts each game once across either colour', () {
    final suggestions = HeaderSuggestions(const [
      (headers: {'White': 'Alpha', 'Black': 'Beta'}, pgnText: '*'),
      (headers: {'White': 'Gamma', 'Black': 'Alpha'}, pgnText: '*'),
      (headers: {'White': 'Alpha', 'Black': 'Alpha'}, pgnText: '*'),
      (headers: {'White': 'alpha'}, pgnText: '*'),
    ]);
    expect(suggestions.matching(kPlayerHeaderField, 'ALP'), [
      (value: 'Alpha', count: 3),
      (value: 'alpha', count: 1),
    ]);
    expect(suggestions.matching('White', 'Alpha'), [
      (value: 'Alpha', count: 2),
      (value: 'alpha', count: 1),
    ]);
    expect(suggestions.matching('Black', 'Alpha'), [
      (value: 'Alpha', count: 2),
    ]);
  });

  test(
    'dates and results are suggested as stored, without fabricated values',
    () {
      final suggestions = HeaderSuggestions(const [
        (headers: {'Date': '2026.09.09', 'Result': '1/2-1/2'}, pgnText: '*'),
        (headers: {'Date': '2026.??.??', 'Result': '*'}, pgnText: '*'),
      ]);
      expect(suggestions.matching('Date', '2026'), [
        (value: '2026.09.09', count: 1),
        (value: '2026.??.??', count: 1),
      ]);
      expect(suggestions.matching('Result', '*'), [(value: '*', count: 1)]);
      expect(suggestions.matching('Result', '0-1'), isEmpty);
    },
  );
}
