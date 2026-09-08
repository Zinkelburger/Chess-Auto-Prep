import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saved bounds retain inclusive wording and persistence keys', () {
    for (final (field, mode, value, label) in [
      ('Date', 'after', '1960', 'In or after 1960'),
      ('Date', 'before', '2000', 'In or before 2000'),
      ('WhiteElo', 'after', '2200', 'White rating at least 2200'),
      ('BlackElo', 'before', '1800', 'Black rating at most 1800'),
      ('Player', 'notContains', 'Alpha', 'Player name excludes Alpha'),
      ('Result', 'exact', '1-0', 'Result is 1-0'),
      ('ECO', 'regex', '^B', 'ECO matches regex ^B'),
    ]) {
      final saved = {'field': field, 'mode': mode, 'value': value};
      final filter = HeaderFilterConfig.fromJson(saved);
      expect(filter.chipLabel, label);
      expect(filter.toJson(), saved);
    }
  });
}
