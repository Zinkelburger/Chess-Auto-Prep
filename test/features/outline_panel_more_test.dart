// The outline column's smaller rules: a rename backed out of changes
// nothing, Shift takes the lines between the anchor and the click from the
// first row on, New chapter in the toolbar while a search finds no chapter,
// Retry save says how it went, and Version history only where there is a
// file and a history.
import 'dart:io';

import 'package:chess_auto_prep/features/library/chapter_outline.dart';
import 'package:chess_auto_prep/features/library/outline_panel.dart';
import 'package:chess_auto_prep/features/library/outline_rows.dart';
import 'package:chess_auto_prep/storage/backup_history.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart' show IoFailure;
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:chess_auto_prep/ui/status_bar.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/status_host.dart';

const _threeLines = '''
// Book
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 e6 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 *

[Event "Slav"]
[Result "*"]

1. d4 d5 2. c4 c6 *
''';

void main() {
  late LibraryFixture fixture;
  late ChapterOutline outline;

  Future<void> show(
    WidgetTester tester, {
    BackupHistory? history,
    bool chapterOpen = true,
  }) async {
    fixture = await openLibrary(
      [
        folder('KID', ['Main', 'Sidelines']),
      ],
      text: _threeLines,
      open: chapterOpen ? ref('KID', 'Main') : null,
      backupHistory: history,
    );
    outline = ChapterOutline(
      library: fixture.library,
      session: fixture.session,
      debounce: Duration.zero,
    );
    addTearDown(() {
      outline.dispose();
      fixture.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: SizedBox(
              width: outlineColumnWidth,
              child: OutlinePanel(
                outline: outline,
                library: fixture.library,
                session: fixture.session,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> picked(WidgetTester tester) => [
    for (final row in tester.widgetList<LineRow>(find.byType(LineRow)))
      if (row.selected) row.line.name,
  ];

  testWidgets('a rename backed out of changes nothing', (tester) async {
    await show(tester);
    final before = fixture.session.chapter!.lines.first.tags.toString();
    await tester.tap(find.byTooltip('Actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename line…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(fixture.session.chapter!.lines.first.tags.toString(), before);
  });

  testWidgets('a rename to the same name changes nothing', (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('Actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename line…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(fixture.session.canUndo, isFalse);
  });

  testWidgets('Shift takes every line from the first row to the click', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text("Queen's"));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('Slav'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(picked(tester), ["Queen's", 'Indian', 'Slav']);
  });

  testWidgets('Shift with no line clicked yet picks nothing', (tester) async {
    await show(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('Indian'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(picked(tester), isEmpty);
  });

  testWidgets('a search that matches no chapter keeps New chapter in the '
      'toolbar', (tester) async {
    await show(tester);
    outline.search('zzz');
    await tester.pumpAndSettle();
    expect(outline.chapters, isEmpty);
    expect(find.byTooltip('New chapter…'), findsOneWidget);
  });

  testWidgets('Retry save says when the line move still needs retrying', (
    tester,
  ) async {
    await show(tester);
    fixture.store.saves.add(const IoFailure('read-only disk'));
    await tester.tap(find.byTooltip('Actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to chapter…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sidelines').last);
    await tester.pumpAndSettle();
    fixture.store.saves.add(const IoFailure('read-only disk'));
    await tester.tap(find.text('Retry save'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(StatusBar),
        matching: find.textContaining('still needs retrying'),
      ),
      findsOneWidget,
    );
  });

  group('Version history', () {
    BackupHistory history() => BackupHistory(
      RecoveryGate(
        documents: Directory('/no-such-documents'),
        support: Directory('/no-such-support'),
      ),
    );

    testWidgets('is offered for an open file with a history', (tester) async {
      await show(tester, history: history());
      expect(find.text('Version history…'), findsOneWidget);
    });

    testWidgets('is not offered without a history', (tester) async {
      await show(tester);
      expect(find.text('Version history…'), findsNothing);
    });

    testWidgets('is not offered with no file open', (tester) async {
      await show(tester, history: history(), chapterOpen: false);
      expect(find.text('Version history…'), findsNothing);
    });
  });
}
