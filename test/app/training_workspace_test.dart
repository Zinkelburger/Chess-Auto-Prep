import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/features/trainer/lesson_view.dart';
import 'package:chess_auto_prep/features/trainer/training_outline.dart';
import 'package:chess_auto_prep/workspace/training_analysis_pane.dart';
import 'package:flutter/material.dart';
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
      expect(w.session.fen, fen);
      expect(find.byType(TrainingAnalysisPane), findsOneWidget);
      expect(find.text('Return to training'), findsOneWidget);
      await tester.tap(find.text('Return to training'));
      await tester.pumpAndSettle();
      expect(w.lineTrainer.lesson, same(lesson));
      expect(lesson.suspended, isFalse);
      expect(w.lineTrainer.board.value!.fen, fen);
      expect(find.text('Reveal help and study'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
