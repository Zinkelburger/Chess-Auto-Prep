import 'package:chess_auto_prep/app/runtime_settings.dart';
import '../support/runtime_settings.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/engine/inline_engine_bar.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/study/study_board_pane.dart';
import 'package:chess_auto_prep/widgets/study/study_chapter_actions.dart';
import 'package:chess_auto_prep/widgets/study/study_chapter_sidebar.dart';
import 'package:chess_auto_prep/widgets/study/study_picker_bar.dart';
import 'package:chess_auto_prep/widgets/study/study_side_pane.dart';
import 'package:chess_auto_prep/widgets/training/move_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/board_engine_fixture.dart';
import '../support/study_fixture.dart';

RuntimeSettings? _settings;
RuntimeSettings get settings => _settings ??= testRuntimeSettings();
void main() {
  setUp(() {
    _settings = null;
    addTearDown(() => _settings?.dispose());
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});

    useScriptedBoardEngine();
  });

  testWidgets(
    'chapter manager follows external metadata without reacting to notes',
    (tester) async {
      final study = memoryStudy();
      addTearDown(study.dispose);
      await pumpRuntimeWidget(
        tester,
        settings,
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    child: SizedBox(
                      width: 520,
                      height: 600,
                      child: StudyChapterSidebar(
                        study: study,
                        inlineActions: true,
                        onChapterAction: (_, _) {},
                      ),
                    ),
                  ),
                ),
                child: const Text('Open manager'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open manager'));
      await tester.pumpAndSettle();
      final list = tester.widget(find.byType(ReorderableListView));
      study.setComment(TreePath.empty, 'Introduction');
      await tester.pump();
      expect(tester.widget(find.byType(ReorderableListView)), same(list));
      study.addChapter('Second');
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);
      study.renameChapter(0, 'First renamed');
      await tester.pumpAndSettle();
      expect(find.text('First renamed'), findsOneWidget);
      study.deleteChapter(1);
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsNothing);
      expect(tester.takeException(), isNull);
      await pumpRuntimeWidget(tester, settings, const SizedBox.shrink());
    },
  );

  testWidgets('compact chapter menu retains its target before the next frame', (
    tester,
  ) async {
    final study = memoryStudy();
    addTearDown(study.dispose);
    study.addChapter('Second');
    study.selectChapter(0);
    int? copied;
    await pumpRuntimeWidget(
      tester,
      settings,
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StudySidePane(
            study: study,
            compact: true,
            onEngineLine: (_, _) {},
            onAddChapter: () {},
            onPickChapter: () {},
            onManageChapters: () {},
            onChapterAction: (action, index) {
              if (action == ChapterAction.copyPgn) copied = index;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Chapter actions'));
    await tester.pumpAndSettle();
    study.selectChapter(1);
    // No rebuild between the selection change and the open menu's callback.
    await tester.tap(find.text('Copy chapter PGN'));
    await tester.pumpAndSettle();
    expect(copied, 0);
    expect(study.chapterIndex, 1);
    expect(tester.takeException(), isNull);
    await pumpRuntimeWidget(tester, settings, const SizedBox.shrink());
  });

  testWidgets('cursor, prose, glyphs and shapes update only their consumers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final study = memoryStudy();
    addTearDown(study.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    study.playSan('e4');
    study.playSan('e5');
    await pumpRuntimeWidget(
      tester,
      settings,
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          appBar: AppBar(
            title: StudyPickerBar(
              study: study,
              focusNode: focus,
              onPickStudy: () {},
            ),
          ),
          body: Row(
            children: [
              SizedBox(
                width: 220,
                child: StudyChapterSidebar(
                  study: study,
                  onAddChapter: () {},
                  onChapterAction: (_, _) {},
                ),
              ),
              Expanded(
                child: StudyBoardPane(
                  study: study,
                  moveInputKey: GlobalKey<MoveInputWidgetState>(),
                  onShapeDrawn: (_, _) {},
                ),
              ),
              Expanded(
                child: StudySidePane(
                  study: study,
                  compact: false,
                  onEngineLine: (_, _) {},
                  onAddChapter: () {},
                  onPickChapter: () {},
                  onManageChapters: () {},
                  onChapterAction: (_, _) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Widget board() => tester.widget(
      find.descendant(
        of: find.byType(StudyBoardPane),
        matching: find.byType(ChessBoardWidget),
      ),
    );
    Widget engine() => tester.widget(find.byType(InlineEngineBar));
    Widget list() => tester.widget(find.byType(ReorderableListView));
    Widget editor() => tester.widget(find.byType(InteractivePgnEditor));
    Widget title() => tester.widget(find.text('Untitled study'));
    final initialBoard = board();
    final initialEngine = engine();
    final initialList = list();
    final initialTitle = title();
    final initialEditor = editor();
    final paintBoundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('study-board-paint')),
    );
    final initialPaint = paintBoundary.debugLayer!.firstChild;
    expect(initialPaint, isNotNull);

    study.setComment(study.path, 'Text only');
    await tester.pump();
    expect(board(), same(initialBoard));
    expect(engine(), same(initialEngine));
    expect(list(), same(initialList));
    expect(title(), same(initialTitle));
    expect(editor(), isNot(same(initialEditor)));
    expect(paintBoundary.debugLayer!.firstChild, same(initialPaint));

    study.toggleNag(study.path, 1);
    await tester.pump();
    expect(board(), same(initialBoard));
    expect(engine(), same(initialEngine));
    expect(list(), same(initialList));

    expect(paintBoundary.debugLayer!.firstChild, same(initialPaint));
    study.setComment(study.path, 'Text only [%cal Ge2e4]');
    await tester.pump();
    expect(board(), isNot(same(initialBoard)));
    expect(paintBoundary.debugLayer!.firstChild, isNot(same(initialPaint)));
    expect(engine(), same(initialEngine));
    expect(list(), same(initialList));

    study.goToStart();
    await tester.pump();
    expect(engine(), isNot(same(initialEngine)));
    expect(list(), same(initialList));
    expect(title(), same(initialTitle));
    final movedBoard = board();
    final movedEngine = engine();
    final movedEditor = editor();
    await study.refreshStudyList();
    await tester.pump();
    expect(board(), same(movedBoard));
    expect(engine(), same(movedEngine));
    expect(editor(), same(movedEditor));

    study.updateChapter(0, name: 'Renamed');
    await tester.pump();
    expect(find.text('Renamed'), findsOneWidget);
    expect(list(), isNot(same(initialList)));
    expect(editor(), same(movedEditor));
    expect(board(), same(movedBoard));

    study.setComment(const TreePath([0]), 'Elsewhere');
    await tester.pump();
    expect(board(), same(movedBoard));
    expect(engine(), same(movedEngine));
    expect(tester.takeException(), isNull);
    await pumpRuntimeWidget(tester, settings, const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
