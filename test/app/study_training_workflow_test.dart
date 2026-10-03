import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/features/trainer/lesson_view.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';
import '../support/study_fixture.dart';
import '../support/scripted_store.dart';

void main() {
  testWidgets(
    'Study starts marked quizzes after visiting the repertoire trainer',
    (tester) async {
      final w = WindowFixture();
      addTearDown(w.dispose);
      final ref = studyRef('Endgames');
      final text = twoChapterStudy.replaceFirst(
        '1. e4 e5 2. Nf3',
        '1. e4 e5 2. Nf3 {[%tstart] [%tend]}',
      );
      w.store.documents[ref] = Opened(text, scriptedRevision(text));
      w.studyFiles.listing = StudiesListed([ref]);
      await w.pumpShell(tester);
      await w.requests.open(kidMain);
      w.requests.switchTo(Mode.trainer);
      await tester.pumpAndSettle();
      expect(w.lineTrainer.selection.active, isTrue);
      await w.requests.openStudy(ref, chapter: 0);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Train study'));
      await tester.pumpAndSettle();
      expect(w.requests.mode, Mode.study);
      expect(w.lineTrainer.selection.active, isFalse);
      final state = w.lineTrainer.state as TrainerReady;
      expect(state.study, isTrue);
      expect(state.lines, hasLength(2));
      expect(state.lines.first.yourMoves, 1);
      expect(
        find.text('Study chapters · quiz markers set the moves to practice'),
        findsOneWidget,
      );
      await tester.tap(find.text('Learn 2'));
      await tester.pumpAndSettle();
      expect(find.byType(LessonView), findsOneWidget);
      expect(w.lineTrainer.lesson, isNotNull);
      expect(tester.takeException(), isNull);
      expect(find.text('Open in Builder'), findsNothing);
      expect(w.lineTrainer.lessonToRead!.place, ReadIn.moves);
      await tester.tap(find.text('Read line'));
      await tester.pumpAndSettle();
      expect(w.requests.mode, Mode.study);
      expect(w.lineTrainer.lesson, isNull);
    },
  );
}
