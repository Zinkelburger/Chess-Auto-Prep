// What the PGN Viewer and Study offer from their menus, with a file open
// and without: the games list's own File entries, the game's analysis and
// solitaire, the pane `+`, a study's way to Lichess, and reading holding
// what is played until Edit writes it.
@Timeout(Duration(seconds: 60))
library;

import 'package:chess_auto_prep/app/document_views.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/mode_view.dart';
import 'package:chess_auto_prep/features/pgn_viewer/filter_pane.dart';
import 'package:chess_auto_prep/features/trainer/trainer_state.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:chess_auto_prep/storage/training_progress.dart';
import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

    testWidgets('keeps the board entries but not the file ones a builder '
        'has', (tester) async {
      start();
      final labels = viewer()
          .actions(await menu(tester))
          .map((action) => action.label);
      expect(labels, isNot(contains('Save a copy…')));
      expect(labels, isNot(contains('Close file')));
      expect(labels, contains('Play through'));
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
