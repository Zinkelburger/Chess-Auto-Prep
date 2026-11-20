import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/explorer_choice.dart';
import 'package:chess_auto_prep/chess/pgn/board_shapes.dart';
import 'package:chess_auto_prep/features/trainer/lesson_view.dart';
import 'package:chess_auto_prep/features/trainer/training_outline.dart';
import 'package:chess_auto_prep/workspace/action_layout.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_pane.dart';
import 'package:chess_auto_prep/workspace/analysis/training_analysis_pane.dart';
import 'package:chess_auto_prep/workspace/board/board_view.dart';
import 'package:chess_auto_prep/workspace/board/move_shapes.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:chess_auto_prep/workspace/workspace_view.dart';
import 'package:dartchess/dartchess.dart' show Square;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Future<void> open(WidgetTester tester) async {
    await w.pumpShell(tester);
    await w.requests.open(kidMain);
    w.requests.switchTo(Mode.trainer);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'trainer opens at repertoire scope and Learn starts without picking a line',
    (tester) async {
      await open(tester);
      expect(find.byType(TrainingOutline), findsOneWidget);
      expect(find.text('Whole repertoire'), findsOneWidget);
      expect(find.text('Your repertoires'), findsNothing);
      expect(w.lineTrainer.selection.chapter, isNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Learn'));
      await tester.pumpAndSettle();
      expect(find.byType(LessonView), findsOneWidget);
      expect(w.lineTrainer.lesson!.left, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'analysis stays beside Train and returning restores the lesson position',
    (tester) async {
      await open(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Learn'));
      await tester.pumpAndSettle();
      final lesson = w.lineTrainer.lesson!;
      final fen = lesson.drill.fen;
      await tester.tap(find.text('Study position'));
      await tester.pumpAndSettle();
      expect(w.requests.mode, Mode.trainer);
      expect(lesson.suspended, isTrue);
      expect(w.session.isScratch, isTrue);
      expect(w.session.cursor.fen, fen);
      expect(find.byType(TrainingAnalysisPane), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(w.lineTrainer.lesson, same(lesson));
      expect(lesson.suspended, isFalse);
      expect(w.lineTrainer.board.value!.fen, fen);
      expect(find.text('Reveal help and study'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  ActionLayout layout(WidgetTester tester) =>
      tester.widget<WorkspaceView>(find.byType(WorkspaceView)).layout!;

  BoardView board(WidgetTester tester) =>
      tester.widget<BoardView>(find.byType(BoardView));

  testWidgets('Ctrl+N in an adjacent pane keeps quiz help concealed', (
    tester,
  ) async {
    await open(tester);
    layout(tester).open(0, WorkspaceTab.explorer);
    w.lineTrainer.learn();
    await tester.pumpAndSettle();
    final claim = w.lineTrainer.board.value;
    expect(claim, isNotNull);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Reveal help and study'), findsOneWidget);
    expect(find.byType(TrainingAnalysisPane), findsNothing);
    expect(w.lineTrainer.lesson!.suspended, isFalse);
    expect(w.lineTrainer.board.value!.fen, claim!.fen);
    expect(w.session.source, kidMain);
  });

  testWidgets(
    'reselecting the chapter during Study position resumes the drill',
    (tester) async {
      await open(tester);
      w.store.hold = true;
      w.session.setComment(w.session.cursor.value, 'Before the lesson');
      final saving = w.saver.flush();
      await tester.pump();
      expect(w.store.waiting, greaterThan(0));
      w.lineTrainer.learn();
      await tester.pump();
      final lesson = w.lineTrainer.lesson!;
      final fen = lesson.drill.fen;
      await tester.tap(find.text('Study position'));
      expect(lesson.suspended, isTrue);
      await w.requests.documents.select(kidMain);
      w.store.hold = false;
      w.store.releaseAll();
      await saving;
      await tester.pumpAndSettle();
      expect(w.session.source, kidMain);
      expect(w.lineTrainer.lesson, same(lesson));
      expect(w.lineTrainer.board.value!.fen, fen);
      expect(lesson.suspended, isFalse);
    },
  );

  testWidgets('analysis from the recap uses the displayed chapter', (
    tester,
  ) async {
    await open(tester);
    layout(tester).open(0, WorkspaceTab.analysis);
    w.lineTrainer.learn();
    await tester.pumpAndSettle();
    final lesson = w.lineTrainer.lesson!;
    for (var i = lesson.left; i >= 0; i--) {
      lesson.skip();
    }
    await tester.pumpAndSettle();
    expect(w.lineTrainer.board.value, isNull);
    board(tester).onMove('g8f6');
    await tester.pumpAndSettle();
    expect(w.session.isScratch, isTrue);
    expect(w.session.cursor.currentMove?.san, 'Nf6');
    expect(lesson.suspended, isFalse);
  });

  testWidgets(
    'later cursor navigation wins while a new move waits for a copy',
    (tester) async {
      await open(tester);
      layout(tester).open(0, WorkspaceTab.analysis);
      await tester.pumpAndSettle();
      board(tester).onMove('c7c5');
      expect(w.session.cursor.currentMove?.uci, 'c7c5');
      w.session.cursor.toStart();
      board(tester).onMove('g8f6');
      w.session.cursor.toStart();
      await tester.pumpAndSettle();
      expect(w.session.source, kidMain);
      expect(w.session.cursor.value.isRoot, isTrue);
      expect(w.store.requestedSaves, isEmpty);
    },
  );

  testWidgets(
    'board and engine follow Book while a file row follows the chapter',
    (tester) async {
      await open(tester);
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      final panes = layout(tester);
      panes.show(0, WorkspaceTab.explorer);
      panes
          .explorer(0)
          .choose(const ExplorerChoice(source: ExplorerSource.book));
      panes.split(0, WorkspaceTab.analysis, PaneSplitDirection.right);
      panes.split(1, WorkspaceTab.explorer, PaneSplitDirection.below);
      panes
          .explorer(2)
          .choose(const ExplorerChoice(source: ExplorerSource.thisFile));
      await tester.pumpAndSettle();
      board(tester).onMove('g8f6');
      await tester.pumpAndSettle();
      expect(w.tree.offFile.single.uci, 'g8f6');
      expect(find.byTooltip('Back to the file'), findsOneWidget);
      final engine = tester.widget<EnginePane>(find.byType(EnginePane));
      await engine.onMove!('d2d4');
      await tester.pumpAndSettle();
      expect(w.tree.offFile.last.uci, 'd2d4');
      // Return to Black's off-file move, with White to play on Book's board.
      w.tree.back();
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('c7c5'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(w.session.cursor.currentMove?.uci, 'c7c5');
      expect(w.tree.offFile, isEmpty);
      expect(w.store.requestedSaves, isEmpty);
    },
  );

  testWidgets('drawing and clearing chapter arrows edit the scratch copy', (
    tester,
  ) async {
    await open(tester);
    const first = BoardShape(Square.c7, Square.c5, ShapeColour.green);
    const second = BoardShape(Square.g8, Square.f6, ShapeColour.red);
    drawIntoComment(w.session, first);
    await w.saver.flush();
    final saved = w.store.requestedSaves.length;
    layout(tester).open(0, WorkspaceTab.analysis);
    await tester.pumpAndSettle();
    board(tester).onDraw!(second);
    await tester.pumpAndSettle();
    expect(w.session.isScratch, isTrue);
    expect(shapesOnBoard(w.session), containsAll([first, second]));
    await w.requests.documents.select(kidMain);
    await tester.pumpAndSettle();
    expect(shapesOnBoard(w.session), [first]);
    board(tester).onClear!();
    await tester.pumpAndSettle();
    expect(w.session.isScratch, isTrue);
    expect(shapesOnBoard(w.session), isEmpty);
    await w.requests.documents.select(kidMain);
    expect(shapesOnBoard(w.session), [first]);
    await w.saver.flush();
    expect(w.store.requestedSaves, hasLength(saved));
  });

  testWidgets('a close the window stays open after keeps the sitting', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Learn'));
    await tester.pumpAndSettle();
    final lesson = w.lineTrainer.lesson!;
    w.parts.prepareToClose();
    await tester.pumpAndSettle();
    expect(w.lineTrainer.board.value, isNull, reason: 'no moves while closing');
    w.parts.resumeAfterClose();
    await tester.pumpAndSettle();
    expect(w.lineTrainer.lesson, same(lesson));
    expect(lesson.suspended, isFalse);
    expect(find.byType(LessonView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
