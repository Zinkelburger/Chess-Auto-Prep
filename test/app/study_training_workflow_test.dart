import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:dartchess/dartchess.dart' show Side;
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
    'missing sides can be filled without changing the board and chapter scope survives edits',
    (tester) async {
      final w = WindowFixture();
      addTearDown(w.dispose);
      final ref = studyRef('Openings');
      w.store.documents[ref] = Opened(
        threeChapterStudy,
        scriptedRevision(threeChapterStudy),
      );
      w.studyFiles.listing = StudiesListed([ref]);
      await w.pumpShell(tester);
      await w.requests.openStudy(ref, chapter: 1);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Train study'));
      await tester.pumpAndSettle();
      expect(w.lineTrainer.state, isA<TrainerEmpty>());
      await tester.tap(find.text('Training sides…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set missing to White'));
      await tester.pump();
      await tester.tap(find.text('Save sides'));
      await tester.pumpAndSettle();
      expect((w.lineTrainer.state as TrainerReady).lines, hasLength(3));
      expect(
        w.lineTrainer.studyDocument!.lines.map(studyOrientation),
        everyElement(Side.white),
      );
      await tester.tap(find.text('This chapter'));
      await tester.pumpAndSettle();
      expect((w.lineTrainer.state as TrainerReady).lines.single.game, 1);
      final document = w.lineTrainer.studyDocument!;
      expect(w.lineTrainer.setStudySides(document, {1: Side.black}), isNull);
      await tester.pumpAndSettle();
      expect((w.lineTrainer.state as TrainerReady).lines.single.game, 1);
      expect(
        (w.lineTrainer.state as TrainerReady).lines.single.side,
        Side.black,
      );
      expect(
        studyOrientation(w.lineTrainer.studyDocument!.lines[1]),
        Side.white,
      );
      expect(w.lineTrainer.setStudySides(document, {0: Side.black}), isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Annotate exposes position glyphs and quiz markers', (
    tester,
  ) async {
    final w = WindowFixture();
    addTearDown(w.dispose);
    final ref = studyRef('Endgames');
    w.store.documents[ref] = Opened(
      twoChapterStudy,
      scriptedRevision(twoChapterStudy),
    );
    w.studyFiles.listing = StudiesListed([ref]);
    await w.pumpShell(tester);
    await w.requests.openStudy(ref, chapter: 0);
    await tester.pumpAndSettle();
    w.session.goTo(NodePath.of([0]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annotate'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Good move'));
    await tester.tap(find.byTooltip('White is better'));
    await tester.tap(find.text('Quiz starts here'));
    await tester.tap(find.text('Quiz ends here'));
    await tester.pumpAndSettle();
    expect(w.session.currentMove!.nags, containsAll([1, 16]));
    expect(w.session.currentMove!.comment, contains('[%tstart]'));
    expect(w.session.currentMove!.comment, contains('[%tend]'));
    w.session.goTo(NodePath.of([0, 0]));
    await tester.pump();
    await tester.tap(find.text('Quiz ends here'));
    await tester.pumpAndSettle();
    expect(w.session.currentMove!.comment, contains('[%tend]'));
    expect(w.session.currentMove!.comment, isNot(contains('[%tstart]')));
    w.session.goTo(const NodePath.root());
    await tester.pump();
    expect(find.text('Quiz ends here'), findsNothing);
    w.session.goTo(NodePath.of([0]));
    await tester.pump();
    expect(find.text('Quiz ends here'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

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
      expect(find.text('Whole study'), findsOneWidget);
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
