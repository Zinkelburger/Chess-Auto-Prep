import 'package:chess_auto_prep/v2/chess/bughouse/match.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/v2/features/bughouse/match_panel.dart';
import 'package:chess_auto_prep/v2/features/bughouse/matches.dart';
import 'package:chess_auto_prep/v2/features/bughouse/table_search.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  for (final discard in [false, true]) {
    testWidgets(
      'failed checkpoint recovers through ${discard ? 'confirmed discard' : 'retry'}',
      (tester) async {
        final outside = ScriptedBughouse();
        final lab = BughouseLab();
        final tables = TableSearch(
          lab: lab,
          book: outside.book,
          startEngine: () => outside.outside.launch(cores: 2),
        );
        final matches = Matches(
          store: outside.matches,
          lab: lab,
          tables: tables,
          startEngine: () => outside.outside.launch(cores: 2),
        );
        addTearDown(matches.dispose);
        addTearDown(tables.dispose);
        addTearDown(lab.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: darkTheme(),
            home: Scaffold(
              body: MatchPanel(matches: matches, lab: lab),
            ),
          ),
        );
        outside.matches.failSave = 'disk full';
        await matches.start(
          MatchConfig(
            name: 'Blocked',
            startDualFen: TablePosition.initial.dualFen,
            seed: 42,
            games: 1,
            maxPlies: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Could not save the match: disk full'),
          findsOneWidget,
        );
        expect(find.text('Retry save'), findsOneWidget);
        expect(find.text('Resume'), findsNothing);
        await tester.tap(find.text('New match'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(outside.starts, 0);
        if (discard) {
          await tester.tap(find.text('Discard save'));
          await tester.pumpAndSettle();
          expect(find.text('Discard unsaved match results?'), findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(matches.writable, isFalse);
          await tester.tap(find.text('Discard save'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Discard save'));
          await tester.pumpAndSettle();
          expect(matches.writable, isTrue);
          expect(find.text('Retry save'), findsNothing);
          expect(outside.matches.saved, hasLength(1));
          return;
        }
        outside.matches.failSave = null;
        await tester.tap(find.text('Retry save'));
        await tester.pumpAndSettle();
        expect(find.text('Retry save'), findsNothing);
        expect(find.text('Resume'), findsOneWidget);
        expect(outside.starts, 0);
        await tester.tap(find.text('Resume'));
        await tester.pumpAndSettle();
        expect(outside.starts, 1);
        expect(matches.selected!.status, MatchStatus.completed);
      },
    );
  }
}
