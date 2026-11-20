import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/features/tournaments/standings_table.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A, B and C, where A beat B and drew with B, and C has not played.
Tournament _match({bool played = true}) => Tournament({
  'id': 'club',
  'config': {
    'name': 'Club match',
    'engines': [
      for (final name in ['A', 'B', 'C']) TournamentEngine.bundled(name).json,
    ],
  },
  'games': [
    if (played) ...[
      {'whiteIndex': 0, 'blackIndex': 1, 'result': 'whiteWins'},
      {'whiteIndex': 1, 'blackIndex': 0, 'result': 'draw'},
    ],
  ],
});

/// Each row of the table as the player reads it; a head-to-head cell by its
/// score.
List<List<String?>> _rows(WidgetTester tester) => [
  for (final row in tester.widget<DataTable>(find.byType(DataTable)).rows)
    [
      for (final cell in row.cells)
        switch (cell.child) {
          Text(:final data) => data,
          Column(:final children) => (children.first as Text).data,
          _ => null,
        },
    ],
];

Future<void> _show(WidgetTester tester, Tournament tournament) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(body: TournamentStandingsTable(tournament: tournament)),
    ),
  );
}

void main() {
  testWidgets('the table ranks the engines with their head-to-head scores, '
      'and the rating statistics come only when asked for', (tester) async {
    await _show(tester, _match());
    expect(find.text('Draw %'), findsNothing);
    expect(_rows(tester), [
      ['1', 'A', '1.5/2', '1', '1', '0', '—', '1.5/2', '0/0'],
      ['2', 'B', '0.5/2', '0', '1', '1', '0.5/2', '—', '0/0'],
      ['3', 'C', '0/0', '0', '0', '0', '0/0', '0/0', '—'],
    ]);

    await tester.tap(find.text('Show rating statistics'));
    await tester.pump();
    expect(find.text('Draw %'), findsOneWidget);
    final rows = _rows(tester);
    // Draw %, Elo ±, LOS and SB follow the W/D/L columns.
    expect(rows[0].sublist(6, 10), [
      '50.0%',
      startsWith('191 ±'),
      '84.1%',
      '0.75',
    ]);
    expect(rows[2].sublist(6, 10), ['—', '—', '50.0%', '0.00']);
  });

  testWidgets('before any game ends the table says so', (tester) async {
    await _show(tester, _match(played: false));
    expect(find.text('No games finished yet.'), findsOneWidget);
    expect(find.byType(DataTable), findsNothing);
  });
}
