import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/features/bughouse/archive_moves.dart';
import 'package:chess_auto_prep/v2/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/v2/features/bughouse/lab_panel.dart';
import 'package:chess_auto_prep/v2/features/bughouse/table_search.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_books.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

FicsMove _move(BoardNumber board, Side mover, String san, int games) => (
  board: board,
  mover: mover,
  san: san,
  games: games,
  abWins: games ~/ 2,
  cdWins: games ~/ 3,
  draws: 0,
  unknown: 0,
  averageElo: null,
);

void main() {
  late BughouseLab lab;
  late ScriptedBughouse outside;
  late TableSearch search;
  late ArchiveMoves archive;

  setUp(() {
    lab = BughouseLab();
    outside = ScriptedBughouse();
    search = TableSearch(
      lab: lab,
      startEngine: () => outside.outside.launch(cores: 2),
      depth: (ownNodes: 50, childNodes: 20, topMoves: 2),
      passes: const [Duration(seconds: 1)],
    );
    archive = ArchiveMoves(lab: lab, book: outside.archive);
  });

  tearDown(() {
    archive.dispose();
    search.dispose();
    lab.dispose();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: LabPanel(lab: lab, search: search, archive: archive),
        ),
      ),
    );
    search.open();
    await archive.open();
    await tester.pumpAndSettle();
  }

  testWidgets('only the clock and the engine switch ask anything', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Time'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    for (final gone in [
      'Our team',
      'Must move on',
      'Search',
      'Analyze',
      'Flip boards',
      'New game',
      'FICS archive',
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
  });

  testWidgets('the switch shows both teams’ lines', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('A + B'), findsOneWidget);
    expect(find.text('C + D'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('A + B'), findsNothing);
  });

  testWidgets('the FICS archive lists each board’s moves under its table', (
    tester,
  ) async {
    outside.archive
      ..present = true
      ..positions[TablePosition.initial.bookKey] = (
        games: 900,
        moves: [
          _move(BoardNumber.one, Side.white, 'e4', 500),
          _move(BoardNumber.two, Side.white, 'd4', 300),
        ],
      );
    await pump(tester);
    final one = tester.getTopLeft(find.text('A e4'));
    final two = tester.getTopLeft(find.text('D d4'));
    // Side by side, each under its own board's column.
    expect(two.dx, greaterThan(one.dx + 200));
    expect(two.dy, one.dy);
    expect(find.text('FICS archive · 900 games'), findsNWidgets(2));
  });
}
