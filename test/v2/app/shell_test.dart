import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/features/library/library_panel.dart';
import 'package:chess_auto_prep/v2/features/library/outline_panel.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/recent_pgn_files.dart';
import 'package:chess_auto_prep/v2/workspace/search_pane.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  final kid = kidMain;
  final benko = benkoMain;

  /// Both columns list a chapter called Main once one is open, so a row is
  /// looked for in the column it belongs to.
  Finder inLibrary(Finder row) =>
      find.descendant(of: find.byType(LibraryPanel), matching: row);
  Finder inOutline(Finder row) =>
      find.descendant(of: find.byType(OutlinePanel), matching: row);
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());
  Future<void> pump(WidgetTester tester) => w.pumpShell(tester);

  testWidgets('opening a chapter puts it in the workspace', (tester) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pump();
    expect(w.session.source, kid);
    expect(w.session.chapter?.gameCount, 2);
    expect(
      find.text('Black · 2 lines, 1 from another position'),
      findsOneWidget,
    );
  });

  testWidgets('a sitting ends when the mode it was started in is left', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    w.lineTrainer.show();
    await tester.pumpAndSettle();
    w.lineTrainer.learn();
    await tester.pump();
    expect(w.lineTrainer.board.value, isNotNull);
    w.requests.switchTo(Mode.tactics);
    await tester.pump();
    expect(w.lineTrainer.lesson, isNull);
    expect(w.lineTrainer.board.value, isNull, reason: 'the board is back');
    expect(w.analysis.pausedFor, isNull);
    // A sitting started afresh in another mode is that mode's.
    w.requests.switchTo(Mode.repertoires);
    await tester.pumpAndSettle();
    w.lineTrainer.learn();
    await tester.pump();
    expect(w.lineTrainer.lesson, isNotNull);
  });

  testWidgets('a sitting ends with its Train tab closed', (tester) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    await tester.tap(find.text('Train'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'the tab fits');
    w.lineTrainer.learn();
    await tester.pump();
    expect(w.lineTrainer.lesson, isNotNull);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(w.lineTrainer.lesson, isNull);
    expect(w.lineTrainer.board.value, isNull);
  });

  testWidgets('the later of two clicks wins, whichever read finishes first', (
    tester,
  ) async {
    await pump(tester);
    w.store.hold = true;
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.tap(inLibrary(find.text('Main')).first); // benko
    expect(w.store.waiting, 2);
    w.store.releaseAll(); // KID's read answers before benko's
    await tester.pump();
    expect(w.session.source, benko);
    // The stale KID answer must not have replaced benko.
    await tester.pump();
    expect(w.session.source, benko);
  });

  testWidgets('a chapter that vanished is reported, not opened', (
    tester,
  ) async {
    await pump(tester);
    w.store.documents.clear();
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pump();
    expect(w.session.isScratch, isTrue);
    expect(find.text('Main is no longer on disk'), findsOneWidget);
  });
  testWidgets('another chapter is not opened over a frozen document until '
      'the user says so', (tester) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    w.store.saves.add(
      const SaveRefused('game 3 would change but the edit was to game 1'),
    );
    w.session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();
    expect(w.saver.state, isA<SaveStopped>());

    w.question.answer = DraftChoice.keepWaiting;
    await tester.tap(inLibrary(find.text('Main')).first); // benko
    await tester.pumpAndSettle();
    expect(w.question.asked.single, contains('was stopped'));
    expect(w.session.source, kid, reason: 'nothing opened over the words');
    expect(w.session.commentAt(NodePath.of([0])), contains('frozen words'));
  });

  testWidgets('leaving a frozen document anyway is logged', (tester) async {
    final entries = <LogEntry>[];
    void collect(LogEntry entry) => entries.add(entry);
    log.install(collect);
    addTearDown(() => log.remove(collect));
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    w.store.saves.add(const SaveRefused('game 3 would change'));
    w.session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();

    w.question.answer = DraftChoice.closeAnyway;
    await tester.tap(inLibrary(find.text('Main')).first); // benko
    await tester.pumpAndSettle();
    expect(w.session.source, benko);
    expect(
      entries
          .where((entry) => entry.level == LogLevel.warning)
          .map((entry) => entry.action),
      contains(contains('leave this document with unsaved words')),
    );
  });
  testWidgets('clicking the chapter that is already open asks nothing', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    w.store.saves.add(const SaveRefused('game 3 would change'));
    w.session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();
    w.question.asked.clear();

    await tester.tap(inLibrary(find.text('Main')).last); // KID again
    await tester.pumpAndSettle();
    expect(w.question.asked, isEmpty);
    expect(w.session.source, kid);
  });

  testWidgets('saving a copy on the way out says where the words went', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    w.store.saves.add(const SaveRefused('game 3 would change'));
    w.session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();

    w.question.answer = DraftChoice.saveACopy;
    await tester.tap(inLibrary(find.text('Main')).first); // benko
    await tester.pumpAndSettle();
    expect(w.session.source, benko, reason: 'the click still went through');
    expect(find.text('Saved a copy as Main copy.pgn'), findsOneWidget);
    expect(
      w.store.documents.keys.map((ref) => ref.path),
      contains('/repertoires/KID/Main copy.pgn'),
    );
  });

  testWidgets('the PGN Viewer opens a recent file on its first game and '
      'walks its games on the same board', (tester) async {
    final games = collectionRef('games');
    w.store.documents[games] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    w.recent.listing = RecentFilesListed([games.path]);
    await pump(tester);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PGN Viewer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('games.pgn'));
    await tester.pumpAndSettle();
    expect(w.session.source, games);
    expect(w.session.game, 0);
    expect(find.text('of 3'), findsOneWidget, reason: 'under the board');
    expect(find.byType(OutlinePanel), findsNothing);
    // The header names the game rather than counting lines.
    // Once in the list, once as the heading.
    expect(find.text('Carlsen, Magnus – Nakamura, Hikaru'), findsNWidgets(2));
    expect(find.text('1-0 · Tata Steel · 2024'), findsOneWidget);
    await tester.tap(find.byTooltip('Next game (↓)'));
    await tester.pumpAndSettle();
    expect(w.session.game, 1);
    expect(find.text('Ding, Liren – Giri, Anish'), findsWidgets);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close file'));
    await tester.pumpAndSettle();
    expect(w.session.source, isNull);
    expect(find.text('Recent files'), findsOneWidget);
  });

  testWidgets('Ctrl+Z reaches the document from the outline column', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pumpAndSettle();

    // Working in another column leaves the focus there: on the row that was
    // clicked, or on the menu button beside it, and not on the board.
    final inRow = find.descendant(
      of: find.byType(OutlinePanel),
      matching: find.byType(Text),
    );
    Focus.of(tester.element(inRow.last)).requestFocus();
    await tester.pumpAndSettle();
    expect(
      find.ancestor(
        of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
        matching: find.byType(OutlinePanel),
      ),
      findsOneWidget,
      reason: 'the focus is on a row of the outline column',
    );

    await tester.tap(inOutline(find.byTooltip('Actions')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename line…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Closed');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(textOf(w.store, kid), contains('[Event "Closed"]'));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(textOf(w.store, kid), isNot(contains('[Event "Closed"]')));
  });

  testWidgets('the Actions menu closes and shows the Replies tab', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pumpAndSettle();
    expect(find.text('Replies'), findsOneWidget);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    expect(find.text('Next tab'), findsOneWidget);
    expect(find.text('Ctrl+Tab'), findsOneWidget);
    // The menu is taller than this window; its last entries scroll in.
    await tester.ensureVisible(find.text('Close Replies'));
    await tester.tap(find.text('Close Replies'));
    await tester.pumpAndSettle();
    expect(find.text('Replies'), findsNothing);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Show Replies'));
    await tester.tap(find.text('Show Replies'));
    await tester.pumpAndSettle();
    expect(find.text('Replies'), findsOneWidget);
    expect(find.text('Next gap'), findsOneWidget, reason: 'brought up');
  });

  testWidgets('Search from here (Ctrl+G) brings the Search tab up and '
      'starts it, on the analysis board and on a chapter', (tester) async {
    await pump(tester);
    Future<void> searchFromHere() async {
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      final entry = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'Search from here'),
      );
      expect(entry.onPressed, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      // No engine in this test: the tab says so, and the pane is back.
      expect(find.byType(SearchPane), findsOneWidget);
      expect(find.text('no engine in this test'), findsOneWidget);
      expect(w.analysis.paused, isFalse);
    }

    await searchFromHere();
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pumpAndSettle();
    await searchFromHere();
  });

  testWidgets('Actions sits beside the mode menu, at the left, and says its '
      'key', (tester) async {
    await pump(tester);
    final mode = tester.getTopRight(find.text('Repertoire builder').first);
    final actions = tester.getTopLeft(find.text('Actions'));
    expect(actions.dx, greaterThan(mode.dx));
    expect(actions.dx, lessThan(paneMinWidth * 2));
    expect(find.byTooltip('Actions (Ctrl+K)'), findsOneWidget);
  });

  testWidgets('Close file in Study takes off the chapter its own list '
      'opened', (tester) async {
    final study = studyRef('Endgames');
    w.store.documents[study] = Opened(
      twoChapterStudy,
      scriptedRevision(twoChapterStudy),
    );
    await pump(tester);
    w.requests.switchTo(Mode.study);
    await tester.pumpAndSettle();
    await w.requests.open(study, game: 0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close file'));
    await tester.pumpAndSettle();
    expect(w.session.source, isNull);
  });

  testWidgets('a mode a request brings up is entered as one chosen from the '
      'menu, and only when it changes', (tester) async {
    await pump(tester);
    final listed = w.studyFiles.listings;
    w.requests.switchTo(Mode.study);
    await tester.pumpAndSettle();
    expect(w.studyFiles.listings, listed + 1, reason: 'read again on entry');
    w.requests.switchTo(Mode.study);
    await tester.pumpAndSettle();
    expect(w.studyFiles.listings, listed + 1, reason: 'not entered twice');
    w.requests.switchTo(Mode.bughouse);
    await tester.pumpAndSettle();
    expect(w.analysis.pausedFor, isNotNull, reason: 'Stockfish gives way');
    w.requests.switchTo(Mode.repertoires);
    await tester.pumpAndSettle();
    expect(w.analysis.pausedFor, isNull);
  });

  testWidgets('the side is changed from Actions and written to the file', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pumpAndSettle();
    expect(find.byType(SegmentedButton<Side>), findsNothing);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play as White'));
    await tester.pumpAndSettle();
    expect(w.session.chapter?.side, Side.white);
    expect(
      find.text('White · 2 lines, 1 from another position'),
      findsOneWidget,
    );
  });

  testWidgets('a chapter whose file does not say its side is asked once, '
      'and the answer is written down', (tester) async {
    const unsaid = '[Event "Open"]\n[Result "*"]\n\n1. e4 e5 *\n';
    w.store.documents[benko] = Opened(unsaid, scriptedRevision(unsaid));
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).first);
    await tester.pumpAndSettle();
    expect(find.text('Which side is Main for?'), findsOneWidget);
    await tester.tap(find.text('Black'));
    await tester.pumpAndSettle();
    expect(find.text('Which side is Main for?'), findsNothing);
    expect(w.session.chapter?.side, Side.black);
    expect(w.session.chapter?.sideStated, isTrue);
    await w.saver.flush();
    expect(
      (w.store.documents[benko] as Opened).text,
      startsWith('// Color: Black\n'),
    );
    // The stated chapter is not asked.
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pumpAndSettle();
    expect(find.text('Which side is Main for?'), findsNothing);
  });

  testWidgets('the list toggle sits at the edge of the pane, shown or not', (
    tester,
  ) async {
    await pump(tester);
    // Shown: `«` in the pane's own top right corner, not the top bar.
    final hide = find.byTooltip('Hide the list (Ctrl+B)');
    expect(hide, findsOneWidget);
    expect(find.byTooltip('Show the list (Ctrl+B)'), findsNothing);
    final corner = tester.getTopRight(hide);
    expect(corner.dx, closeTo(paneMinWidth, Space.l));
    expect(corner.dy, greaterThan(40));
    await tester.tap(hide);
    await tester.pumpAndSettle();
    // Hidden: `»` at the top bar's left, where the pane would begin.
    final show = find.byTooltip('Show the list (Ctrl+B)');
    expect(show, findsOneWidget);
    expect(hide, findsNothing);
    expect(tester.getTopLeft(show).dx, lessThan(Space.l));
    expect(find.text('Your repertoires'), findsNothing);
    await tester.tap(show);
    await tester.pumpAndSettle();
    expect(find.text('Your repertoires'), findsOneWidget);
  });
}

/// What the scripted store holds for [ref] now.
String textOf(ScriptedDocumentStore store, ChapterRef ref) =>
    switch (store.documents[ref]) {
      Opened(:final text) => text,
      _ => '',
    };
