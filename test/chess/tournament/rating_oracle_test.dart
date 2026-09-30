import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/tournament/standings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Elo, margin and likelihood of superiority as the old app's crosstable
/// reported them for these records, recorded once from that code.
const _reports = 'test/fixtures/legacy/rating_reports.json';

void main() {
  test(
    'fresh arithmetic matches shipped rating reports on representative records',
    () async {
      final rows = jsonDecode(await File(_reports).readAsString()) as List;
      expect(rows, hasLength(6));
      for (final row in rows.cast<Map<String, Object?>>()) {
        final expected = (
          elo: (row['elo'] as num?)?.toDouble(),
          margin: (row['margin'] as num?)?.toDouble(),
          superiority: (row['superiority'] as num).toDouble(),
        );
        final actual = MatchScore(
          row['wins'] as int,
          row['draws'] as int,
          row['losses'] as int,
        );
        expect(
          actual.elo,
          expected.elo == null ? isNull : closeTo(expected.elo!, 1e-8),
        );
        expect(
          actual.margin,
          expected.margin == null ? isNull : closeTo(expected.margin!, 1e-4),
        );
        expect(actual.superiority, closeTo(expected.superiority, 2e-7));
      }
    },
  );
}
