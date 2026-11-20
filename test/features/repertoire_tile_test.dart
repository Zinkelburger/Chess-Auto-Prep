// A repertoire's row and its chapters' rows: what each menu does, what it
// asks first, and which chapter the list marks as open.

import 'package:chess_auto_prep/features/library/library_panel.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/ui/list_row.dart';
import 'package:chess_auto_prep/ui/status_bar.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/status_host.dart';

void main() {
  final kid = folder('KID', ['Classical', 'Main']);
  late LibraryFixture fixture;

  tearDown(() => fixture.dispose());

  Future<void> show(WidgetTester tester, {ChapterRef? selected}) async {
    fixture = await openLibrary([kid]);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: LibraryPanel(
              library: fixture.library,
              selected: selected,
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Picks [action] from the `⋯` menu of the row at [row], counting rows
  /// from the top: the repertoire, then its chapters when it is open.
  Future<void> menu(WidgetTester tester, int row, String action) async {
    await tester.tap(find.byIcon(Icons.more_horiz).at(row));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.text('KID'));
    await tester.pumpAndSettle();
  }

  bool marked(WidgetTester tester, String chapter) => tester
      .widget<ListRow>(
        find.ancestor(of: find.text(chapter), matching: find.byType(ListRow)),
      )
      .selected;

  testWidgets('the chapter open in the workspace is the one marked', (
    tester,
  ) async {
    await show(tester, selected: ref('KID', 'Main'));
    await expand(tester);

    expect(marked(tester, 'Main'), isTrue);
    expect(marked(tester, 'Classical'), isFalse);
  });

  testWidgets('a repertoire is renamed from its row', (tester) async {
    await show(tester);
    await menu(tester, 0, 'Rename…');
    await tester.enterText(find.byType(TextField).last, "King's Indian");
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(fixture.textAt("/repertoires/King's Indian/Main.pgn"), isNotNull);
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNull);
    expect(find.byType(StatusBar), findsNothing);
  });

  testWidgets('a repertoire renamed to its own name is left alone', (
    tester,
  ) async {
    await show(tester);
    await menu(tester, 0, 'Rename…');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNotNull);
    expect(find.byType(StatusBar), findsNothing, reason: 'nothing to say');
  });

  testWidgets('a chapter renamed to its own name is left alone', (
    tester,
  ) async {
    await show(tester);
    await expand(tester);
    await menu(tester, 2, 'Rename…');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNotNull);
    expect(find.byType(StatusBar), findsNothing, reason: 'nothing to say');
  });

  testWidgets('deleting a chapter is confirmed first', (tester) async {
    await show(tester);
    await expand(tester);
    await menu(tester, 2, 'Delete…');
    expect(find.text('Delete chapter “Main”?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNotNull);

    await menu(tester, 2, 'Delete…');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNull);
    expect(fixture.textAt('/repertoires/KID/Classical.pgn'), isNotNull);
  });
}
