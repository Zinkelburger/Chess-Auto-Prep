// What the PGN Viewer and Study offer from their menus, with a file open
// and without: the games list's own File entries, the game's analysis and
// solitaire, the pane `+`, a study's way to Lichess, and reading holding
// what is played until Edit writes it.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:chess_auto_prep/app/document_views.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/mode_view.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/pgn_viewer/filter_pane.dart';
import 'package:chess_auto_prep/features/trainer/trainer_state.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:chess_auto_prep/storage/training_progress.dart';
import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:chess_auto_prep/workspace/workspace_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_engine.dart';
import '../support/scripted_store.dart';
import '../support/scripted_study_writer.dart';
import '../support/study_fixture.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  late ValueNotifier<bool> editing;

  void start({bool lichess = false}) {
    w = WindowFixture(lichessWriter: lichess ? ScriptedStudyWriter() : null);
    editing = ValueNotifier(false);
    addTearDown(() {
      editing.dispose();
      w.dispose();
    });
  }

  ViewerView viewer() {
    final view = ViewerView(
      w.parts.workspace,
      w.requests,
      w.parts.documents,
      editing,
    );
    addTearDown(view.dispose);
    return view;
  }

  StudyView study() {
    final view = StudyView(
      w.parts.workspace,
      w.requests,
      w.parts.documents,
      editing,
      w.lineTrainer,
    );
    addTearDown(view.dispose);
    return view;
  }

  Future<ModeMenu> menu(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    void none() {}
    final ModeMenu menu = (
      editing: editing,
      board: () => const [],
      dialogs: (
        saveCopy: none,
        saveHeld: none,
        exportPgn: none,
        search: none,
        accounts: none,
        newBook: none,
        importCourse: none,
      ),
      context: tester.element(find.byType(SizedBox)),
    );
    return menu;
  }

  AppAction entry(List<AppAction> actions, String label) =>
      actions.singleWhere((action) => action.label == label);
  bool on(List<AppAction> actions, String label) =>
      entry(actions, label).run != null;

  Future<void> openThreeGames(WidgetTester tester) async {
    final ref = collectionRef('three');
    w.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await w.requests.openFile(ref);
    await tester.pump();
  }

  group('the PGN Viewer', () {
    const fileEntries = [
      'Filter games',
      'Export games…',
      'Add games to study…',
      'Analyze all games',
    ];

    testWidgets('with no file, offers nothing to do to one', (tester) async {
      start();
      final view = viewer();
      final actions = view.actions(await menu(tester));
      for (final label in fileEntries) {
        expect(on(actions, label), isFalse, reason: label);
      }
      expect(view.fileEntry.run, isNull);
      expect(view.walk(1), isFalse);
    });

    testWidgets('with a file, offers its games and the game', (tester) async {
      start();
      final view = viewer();
      await openThreeGames(tester);
      final actions = view.actions(await menu(tester));
      for (final label in [...fileEntries, 'Analyze game', 'Solitaire chess']) {
        expect(on(actions, label), isTrue, reason: label);
      }
      expect(view.fileEntry.run, isNotNull);
      expect(view.walk(1), isTrue);
    });

    testWidgets('keeps the board and file entries, but makes no copy of a '
        'file it reads', (tester) async {
      start();
      final labels = viewer()
          .actions(await menu(tester))
          .map((action) => action.label);
      expect(labels, isNot(contains('Save a copy…')));
      expect(labels, containsAll(['Close file', 'Play through']));
      expect(
        viewer().actions(await menu(tester)).where((a) => a.group == 'View'),
        isNotEmpty,
      );
    });

    testWidgets('Esc ends a solitaire game, and leaves nothing without one', (
      tester,
    ) async {
      start();
      final view = viewer();
      await openThreeGames(tester);
      expect(view.leave(), isFalse);
      final solitaire = w.parts.workspace.solitaire!..start();
      expect(solitaire.active, isTrue);
      expect(view.leave(), isTrue);
      expect(solitaire.active, isFalse);
    });

    testWidgets('a pane `+` offers the engine switch alone', (tester) async {
      start();
      final actions = viewer().paneActions(editing);
      expect(actions.map((action) => action.label), ['Engine on']);
    });

    testWidgets('reading holds what is played; Edit writes it', (tester) async {
      start();
      final view = viewer();
      await openThreeGames(tester);
      view.entered();
      addTearDown(view.left);
      expect(w.session.holdsEdits, isTrue);
      editing.value = true;
      w.session.cursor.forward();
      expect(w.session.holdsEdits, isFalse);
    });

    testWidgets('editing the Analysis tab leaves the source variation held', (
      tester,
    ) async {
      start();
      await w.pumpShell(tester, openFolders: false);
      await openThreeGames(tester);
      w.session.cursor.forward(); // 1. e4
      w.session.playMove('c7c5');
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(w.parts.workspace.inspection!.active, isTrue);
      expect(w.session.hasHeldEdits, isTrue);

      await chooseAction(tester, 'Edit');
      await w.saver.flush();
      final stored = w.store.documents[collectionRef('three')] as Opened;
      expect(stored.text, threeGameFile);
      expect(w.session.hasHeldEdits, isTrue);
    });

    testWidgets('the scratch edit strip stays open on return to its game', (
      tester,
    ) async {
      start();
      await w.pumpShell(tester, openFolders: false);
      await openThreeGames(tester);
      final board = tester.widget<WorkspaceView>(find.byType(WorkspaceView));
      board.tabs.show(WorkspaceTab.analysis);
      await tester.pumpAndSettle();
      await chooseAction(tester, 'Edit');
      expect(find.byTooltip('Good move'), findsOneWidget);

      await tester.tap(find.text('Moves'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Good move'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byType(WorkspaceView),
          matching: find.text('Analysis'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Good move'), findsOneWidget);
      expect(w.session.holdsEdits, isTrue);
    });

    testWidgets('a review started on Read leaves the PGN unchanged after '
        'switching to Opening books', (tester) async {
      final engine = ScriptedEngine();
      w = WindowFixture(
        launchEngine: ({required cores, required memoryMb}) async =>
            Started(engine),
      );
      addTearDown(w.dispose);
      await w.pumpShell(tester, openFolders: false);
      await openThreeGames(tester);
      w.viewer.showGame(2); // 1. c4 *
      await tester.pumpAndSettle();
      final source = w.session.source!;
      expect(w.session.readOnly, isNull);
      expect(w.session.holdsEdits, isTrue);
      expect(w.session.hasHeldEdits, isFalse);

      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      final analyze = find.widgetWithText(MenuItemButton, 'Analyze game');
      await tester.ensureVisible(analyze);
      await tester.tap(analyze);
      await tester.pump();
      final review = w.parts.workspace.review!;
      engine.current
        ..emit(line(depth: review.depth, pv: ['c2c4']))
        ..end();
      await tester.pump();
      expect(review.completed, 1);
      final reply = engine.current;

      w.requests.switchTo(Mode.books);
      await tester.pump();
      reply
        ..emit(line(depth: review.depth, pv: ['e7e5']))
        ..end();
      await tester.pump();
      expect(review.running, isFalse);
      expect(review.problem, isNull);
      expect(review.annotated, isTrue);
      expect(w.session.hasHeldEdits, isTrue);
      await w.saver.flush();
      expect((w.store.documents[source] as Opened).text, threeGameFile);
    });

    testWidgets("filters by the Analysis tab's board while it is up", (
      tester,
    ) async {
      start();
      final view = viewer();
      await openThreeGames(tester);
      final inspection = w.parts.workspace.inspection!;
      await inspection.show();
      inspection.session.playMove('e2e4');
      expect(inspection.active, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => view.tab(context, WorkspaceTab.filter)!,
            ),
          ),
        ),
      );
      tester
          .widget<ViewerFilterPane>(find.byType(ViewerFilterPane))
          .onPosition!();
      expect(
        w.parts.documents.filter.filter.position,
        inspection.session.cursor.boardFen,
      );
      expect(
        w.parts.documents.filter.filter.position,
        isNot(w.session.cursor.boardFen),
      );
      inspection.hide();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });
  });

  group('the trainer', () {
    TrainerView trainer() {
      final view = TrainerView(
        w.parts.workspace,
        w.requests,
        w.parts.documents,
        w.lineTrainer,
      );
      addTearDown(view.dispose);
      return view;
    }

    /// KID's two lines ready to train, as the trainer shows them.
    Future<TrainerReady> ready() async {
      await w.requests.open(kidMain);
      w.requests.switchTo(Mode.trainer);
      await w.lineTrainer.reload();
      return w.lineTrainer.state as TrainerReady;
    }

    testWidgets('offers Learn for the one line left to learn', (tester) async {
      start();
      final view = trainer();
      final state = await ready();
      for (final line in state.lines.skip(1)) {
        await state.progress.setExcluded(line, excluded: true);
      }
      expect(w.lineTrainer.learnCount, 1);
      expect(on(view.actions(await menu(tester)), 'Learn'), isTrue);
    });

    testWidgets('offers no Learn while what was saved is out of date', (
      tester,
    ) async {
      start();
      final view = trainer();
      final state = await ready();
      w.progress.nextWrite = const ProgressConflict();
      await state.progress.setExcluded(state.lines.first, excluded: true);
      expect(state.progress.stale, isTrue);
      expect(w.lineTrainer.learnCount, greaterThan(0));
      expect(on(view.actions(await menu(tester)), 'Learn'), isFalse);
    });
  });

  group('Study', () {
    final openings = studyRef('Openings');

    Future<ScriptedEngine> startReview(WidgetTester tester, Mode mode) async {
      final engine = ScriptedEngine();
      w = WindowFixture(
        launchEngine: ({required cores, required memoryMb}) async =>
            Started(engine),
      );
      addTearDown(w.dispose);
      w.store.documents[openings] = Opened(
        threeChapterStudy,
        scriptedRevision(threeChapterStudy),
      );
      w.studyFiles.listing = StudiesListed([openings]);
      await w.pumpShell(tester, openFolders: false);
      if (mode == Mode.study) {
        await w.requests.openStudy(openings);
      } else {
        await w.requests.readInViewer(openings, game: 0);
      }
      await tester.pumpAndSettle();
      expect(w.session.holdsEdits, mode == Mode.pgnViewer);
      expect(w.session.hasHeldEdits, isFalse);
      final review = w.parts.workspace.review!;
      unawaited(review.start());
      await tester.pump();
      engine.current
        ..emit(line(depth: review.depth, pv: ['e2e4']))
        ..end();
      await tester.pump();
      expect(review.completed, 1);
      return engine;
    }

    Future<void> finishReview(
      WidgetTester tester,
      ScriptedEngine engine,
    ) async {
      final review = w.parts.workspace.review!;
      engine.current
        ..emit(line(depth: review.depth, pv: ['e7e5']))
        ..end();
      await tester.pump();
      expect(review.running, isFalse);
      expect(review.problem, isNull);
      expect(review.annotated, isTrue);
      await w.saver.flush();
    }

    testWidgets('Open in Study autosaves the pending review and the next '
        'comment in Edit', (tester) async {
      final engine = await startReview(tester, Mode.pgnViewer);
      await w.requests.openStudy(openings);
      await finishReview(tester, engine);
      expect(w.session.hasHeldEdits, isFalse);
      expect((w.store.documents[openings] as Opened).text, contains('[%eval '));

      w.session.setComment(w.session.cursor.value, 'Watch the centre.');
      await w.saver.flush();
      expect(
        (w.store.documents[openings] as Opened).text,
        contains('Watch the centre.'),
      );
    });

    testWidgets('Read in PGN Viewer holds a pending Study review even '
        'after switching to Opening books', (tester) async {
      final engine = await startReview(tester, Mode.study);
      await w.requests.readInViewer(openings, game: 0);
      expect(w.session.holdsEdits, isTrue);
      w.requests.switchTo(Mode.books);
      expect(w.session.holdsEdits, isFalse);
      await finishReview(tester, engine);
      expect(w.session.hasHeldEdits, isTrue);
      expect((w.store.documents[openings] as Opened).text, threeChapterStudy);
    });

    Future<void> openStudy(WidgetTester tester) async {
      final ref = studyRef('Endgames');
      w.store.documents[ref] = Opened(
        twoChapterStudy,
        scriptedRevision(twoChapterStudy),
      );
      w.studyFiles.listing = StudiesListed([ref]);
      await w.requests.openStudy(ref);
      await tester.pump();
    }

    testWidgets(
      'turning to Edit while a rename is going stays on Read with the move held',
      (tester) async {
        start();
        final view = study();
        await openStudy(tester);
        view.entered();
        addTearDown(view.left);
        w.session
          ..cursor.toEnd()
          ..playMove('b8c6');
        final source = w.session.source!;
        w.store.hold = true;
        final rename = w.studies.rename(source, 'Renamed');
        await tester.pump();
        expect(w.store.waiting, 1);
        editing.value = true;
        expect(editing.value, isFalse);
        expect(w.requests.status, contains('Stayed in Read'));
        w.store.hold = false;
        w.store.releaseNext();
        await rename;
        expect(w.session.source, studyRef('Renamed'));
        expect(w.session.hasHeldEdits, isTrue);
        expect(w.session.holdsEdits, isTrue);
        expect(w.session.tree!.mainLine.last.san, 'Nc6');
      },
    );

    testWidgets('sends to Lichess only where it can write there, and only a '
        'study that is open', (tester) async {
      start(lichess: true);
      final view = study();
      expect(on(view.makes(await menu(tester)), 'Send to Lichess…'), isFalse);
      await openStudy(tester);
      expect(on(view.makes(await menu(tester)), 'Send to Lichess…'), isTrue);
    });

    testWidgets('without a way to write to Lichess, there is no Send', (
      tester,
    ) async {
      start();
      final view = study();
      await openStudy(tester);
      expect(
        view.makes(await menu(tester)).map((action) => action.label),
        isNot(contains('Send to Lichess…')),
      );
    });
  });
}
