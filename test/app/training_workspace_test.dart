import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/features/trainer/lesson_view.dart';
import 'package:chess_auto_prep/features/trainer/training_outline.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/analysis/training_analysis_pane.dart';
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
    'opening Analysis from the pane menu keeps moves off the repertoire',
    (tester) async {
      await open(tester);
      final before = (w.store.documents[kidMain] as Opened).text;
      await tester.tap(find.byTooltip('Open tools and arrange panes').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Analysis'));
      await tester.pumpAndSettle();
      expect(find.byType(TrainingAnalysisPane), findsOneWidget);

      tester.semantics.tap(find.semantics.byLabel('g8, Black knight'));
      await tester.pump();
      tester.semantics.tap(find.semantics.byLabel('f6, empty'));
      await tester.pumpAndSettle();
      await w.saver.flush();
      expect(find.bySemanticsLabel('f6, Black knight'), findsOneWidget);
      expect((w.store.documents[kidMain] as Opened).text, before);
    },
  );

  testWidgets(
    'leaving trainer during a save keeps the chapter in the builder',
    (tester) async {
      await open(tester);
      w.store.hold = true;
      w.session.playMove('g8f6');
      final saving = w.saver.flush();
      await tester.pump();
      expect(w.store.waiting, greaterThan(0));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      w.requests.switchTo(Mode.repertoires);
      w.store.hold = false;
      w.store.releaseAll();
      await saving;
      await tester.pumpAndSettle();

      expect(w.requests.mode, Mode.repertoires);
      expect(w.session.source, kidMain);
      expect(w.session.cursor.currentMove?.uci, 'g8f6');
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
