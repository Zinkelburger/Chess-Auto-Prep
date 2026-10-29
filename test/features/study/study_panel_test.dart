import 'package:chess_auto_prep/storage/pgn_file_import.dart';
import '../../support/viewer_fixture.dart';
import 'package:chess_auto_prep/features/study/study_panel.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_fixture.dart';
import '../../support/status_host.dart';

/// About as wide as the list pane opens.
const _panelWidth = 300.0;

void main() {
  late StudyFixture study;
  late List<(ChapterRef, int)> opened;

  setUp(() async {
    study = await openStudy(twoChapterStudy);
    opened = [];
  });

  tearDown(() => study.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: _panelWidth,
                child: StudyPanel(
                  studies: study.studies,
                  session: study.session,
                  onOpen: (ref, chapter) => opened.add((ref, chapter)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the studies and the chapters of the open one', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Endgames'), findsOneWidget);
    expect(find.text('Rook endings'), findsOneWidget);
    expect(find.text('Pawn endings'), findsOneWidget);
    // The ordinals say which game of the file each chapter is.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('clicking a chapter asks the host to open that game', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Pawn endings'));
    await tester.pump();
    expect(opened, [(study.ref, 1)]);
  });

  testWidgets('searching narrows the list and says when nothing matches', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'openings');
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing matches'), findsOneWidget);
  });

  testWidgets('a folder that could not be read offers to try again', (
    tester,
  ) async {
    study.files.listing = const StudiesUnreadable('permission denied');
    await study.studies.refresh();
    await pump(tester);
    expect(find.textContaining('Could not read'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('chapter tag editor validates and saves a result', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Chapter actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('PGN tags…'));
    await tester.pumpAndSettle();
    // White, Black, then Result: the game's own tags come first.
    final result = find.widgetWithText(TextField, 'Value').at(2);
    await tester.enterText(result, 'invalid');
    await tester.tap(find.text('Save tags'));
    await tester.pumpAndSettle();
    expect(
      find.text('Use a PGN result: *, 1-0, 0-1 or 1/2-1/2.'),
      findsOneWidget,
    );
    await tester.enterText(result, '1-0');
    await tester.tap(find.text('Save tags'));
    await tester.pumpAndSettle();
    expect(study.onDisk, contains('[Result "1-0"]'));
    expect(study.onDisk, contains('Nf3 1-0'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a game from a scoresheet: the tag editor offers its fields, '
      'keeps the training id out of reach and names the chapter after the '
      'players', (tester) async {
    const typed =
        '[Event "Plane games: Chapter 1"]\n'
        '[StudyName "Plane games"]\n[ChapterName "Chapter 1"]\n'
        '[Orientation "white"]\n[LineID "line_ZTR8MA"]\n\n'
        '1. e4 e5 2. Nf3 *\n';
    study.dispose();
    study = await openStudy(typed, name: 'Plane games');
    await pump(tester);
    await tester.tap(find.byTooltip('Chapter actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('PGN tags…'));
    await tester.pumpAndSettle();
    final keys = find.widgetWithText(TextField, 'Tag');
    for (final (i, key) in [
      'White',
      'Black',
      'Result',
      'Date',
      'Event',
      'Round',
    ].indexed) {
      expect((tester.widget<TextField>(keys.at(i))).controller!.text, key);
    }
    expect(find.text('line_ZTR8MA'), findsNothing);
    expect(find.text('Plane games: Chapter 1'), findsNothing);
    final values = find.widgetWithText(TextField, 'Value');
    await tester.enterText(values.at(0), 'Me');
    await tester.enterText(values.at(1), 'Club rival');
    await tester.enterText(values.at(2), '1-0');
    await tester.enterText(values.at(4), 'Club championship');
    await tester.tap(find.text('Save tags'));
    await tester.pumpAndSettle();
    expect(study.onDisk, contains('[White "Me"]'));
    expect(study.onDisk, contains('[Event "Club championship"]'));
    expect(study.onDisk, contains('[LineID "line_ZTR8MA"]'));
    expect(
      study.onDisk,
      isNot(contains('[Date ""]')),
      reason: 'empty: left out',
    );
    expect(study.onDisk, contains('[ChapterName "Me - Club rival"]'));
    expect(find.text('Me - Club rival'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the row menu renames a chapter', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Chapter actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Rooks');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rooks'), findsOneWidget);
    expect(study.onDisk, contains('[ChapterName "Rooks"]'));
  });

  testWidgets('invalid Lichess links explain how to recover', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Import…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lichess URL'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'nonsense');
    await tester.tap(find.text('Preview chapters'));
    await tester.pumpAndSettle();
    expect(find.text('Use a Lichess study or chapter link.'), findsOneWidget);
    expect(study.lichess.asked, isEmpty);
  });

  testWidgets('an unavailable Lichess import keeps its URL for retry', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Import…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lichess URL'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'lichess.org/study/abcd1234',
    );
    await tester.tap(find.text('Preview chapters'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Lichess did not respond'), findsOneWidget);
    expect(find.text('lichess.org/study/abcd1234'), findsOneWidget);
  });

  testWidgets('chapter search preserves original chapter indexes', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'pawn');
    await tester.pumpAndSettle();
    expect(find.text('Rook endings'), findsNothing);
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.text('Pawn endings'));
    expect(opened, [(study.ref, 1)]);
  });

  testWidgets('study picker is separate from chapter navigation', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('All studies'));
    await tester.pumpAndSettle();
    expect(find.text('Your studies'), findsOneWidget);
    expect(find.text('Pawn endings'), findsNothing);
    await tester.tap(find.text('Endgames'));
    await tester.pumpAndSettle();
    expect(find.text('Pawn endings'), findsOneWidget);
  });

  testWidgets('move to position moves the selected chapter and its identity', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Chapter actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to position…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();
    expect(study.studies.chapters.first.name, 'Pawn endings');
    expect(study.session.game, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed replacement file clears the previous import preview', (
    tester,
  ) async {
    study.dispose();
    final picker = ScriptedPicker('/valid.pgn');
    final importer = ScriptedImport()
      ..picked['/valid.pgn'] = const PickedText(twoChapterStudy);
    study = await openStudy(
      twoChapterStudy,
      picker: picker,
      importer: importer,
    );
    await pump(tester);
    await tester.tap(find.text('Import…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose PGN file…'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Add chapters'),
          )
          .onPressed,
      isNotNull,
    );
    picker.answer = '/missing.pgn';
    await tester.tap(find.text('Choose PGN file…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('That PGN could not be read'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Add chapters'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('a hidden new-study name does not block appending pasted PGN', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Import…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste PGN'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'PGN'),
      '[Event "Added"]\n\n1. c4 *\n',
    );
    await tester.tap(find.text('Preview chapters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New study'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Study name (optional)'),
      'bad/name',
    );
    await tester.tap(find.text('Current study'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add chapters'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(opened.last, (study.ref, 2));
    expect(study.session.chapter!.lines, hasLength(3));
  });

  testWidgets('deleted studies remain reachable even when none are deleted', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Deleted studies'));
    await tester.pumpAndSettle();
    expect(find.text('No deleted studies.'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
