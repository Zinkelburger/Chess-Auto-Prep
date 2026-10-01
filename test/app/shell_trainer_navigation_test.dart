import 'dart:async';

import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/features/trainer/lesson_view.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/move_tree_view.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Future<void> start(WidgetTester tester, Mode mode) async {
    await w.pumpShell(tester);
    unawaited(w.requests.open(kidMain));
    await tester.pumpAndSettle();
    w.requests.switchTo(mode);
    await tester.pumpAndSettle();
    if (find.text('Train').evaluate().isEmpty) {
      await tester.tap(find.byTooltip('Open tab').first);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Train'));
    await tester.pumpAndSettle();
    w.lineTrainer.learn();
    await tester.pumpAndSettle();
    expect(find.byType(LessonView), findsOneWidget);
  }

  for (final mode in [Mode.trainer, Mode.repertoires]) {
    testWidgets(
      'lesson in ${mode.label} opens the shown custom-start position',
      (tester) async {
        await start(tester, mode);
        final shown = w.lineTrainer.lesson!.drill.fen;
        final before = (w.store.documents[kidMain] as Opened).text;
        await tester.ensureVisible(find.text('Open in Builder'));
        await tester.tap(find.text('Open in Builder'));
        await tester.pumpAndSettle();
        expect(w.requests.mode, Mode.repertoires);
        expect(w.session.source, kidMain);
        expect(w.session.fen, shown);
        expect(w.session.currentMove?.san, 'c5');
        expect(w.lineTrainer.lesson, isNull);
        expect(w.lineTrainer.board.value, isNull);
        expect(find.byType(MoveTreeView), findsOneWidget);
        expect((w.store.documents[kidMain] as Opened).text, before);
        await tester.pump(const Duration(seconds: 10));
        expect(w.progress.reviews, isEmpty);
      },
    );
  }

  final course = ChapterRef.at('/repertoires/benko/Course.pgn');
  final second = ChapterRef.at(course.path, section: 'Second');
  const courseText = '''
// Color: White

[Event "First line"]
[ChapterName "First"]

1. e4 e5 *

[Event "Second line"]
[ChapterName "Second"]

1. d4 d5 2. c4 *
''';

  Future<void> bookLesson(WidgetTester tester) async {
    w.store.documents[course] = Opened(
      courseText,
      scriptedRevision(courseText),
    );
    w.chapterFiles.listing = Repertoires([
      RepertoireFolder(
        name: 'benko',
        path: '/repertoires/benko',
        modified: DateTime(2026),
        chapters: [
          ChapterRef.at(course.path, section: 'First'),
          second,
        ],
      ),
      folder('KID', ['Main']),
    ]);
    await start(tester, Mode.trainer);
    w.lineTrainer.setScope(TrainScope.book);
    await tester.pumpAndSettle();
    final ready = w.lineTrainer.state as TrainerReady;
    w.lineTrainer.trainLine(
      ready.lines.firstWhere((l) => l.name == 'Second line'),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'book lesson opens its course section, then reopens saved content',
    (tester) async {
      await bookLesson(tester);
      final shown = w.lineTrainer.lesson!.drill.fen;
      await tester.tap(find.text('Open in Builder'));
      await tester.pumpAndSettle();
      expect(w.session.source, second);
      expect(w.session.fen, shown);
      expect(w.session.currentMove?.san, 'd4');
      unawaited(w.requests.back());
      await tester.pumpAndSettle();
      expect(w.requests.mode, Mode.trainer);
      expect(w.session.source, kidMain);
      unawaited(w.requests.open(second));
      await tester.pumpAndSettle();
      expect(w.session.chapter?.lines.single.nameAt(0), 'Second line');
      expect((w.store.documents[course] as Opened).text, courseText);
      expect(w.progress.reviews, isEmpty);
    },
  );

  testWidgets('a missing lesson source keeps the current document and mode', (
    tester,
  ) async {
    await bookLesson(tester);
    w.store.documents.remove(course);
    await tester.tap(find.text('Open in Builder'));
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.trainer);
    expect(w.session.source, kidMain);
    expect(w.requests.status, isNotNull);
    expect(w.lineTrainer.lesson, isNull);
    expect(w.progress.reviews, isEmpty);
  });

  testWidgets('a newer open cancels a lesson handoff still reading its file', (
    tester,
  ) async {
    await bookLesson(tester);
    w.store.hold = true;
    await tester.tap(find.text('Open in Builder'));
    await tester.pumpAndSettle();
    expect(w.store.waiting, greaterThan(0));
    unawaited(w.requests.open(kidMain));
    await tester.pumpAndSettle();
    w.store.hold = false;
    w.store.releaseAll();
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.trainer);
    expect(w.session.source, kidMain);
    expect(w.progress.reviews, isEmpty);
  });

  testWidgets('declining to leave an unsaved draft cancels the handoff', (
    tester,
  ) async {
    await bookLesson(tester);
    w.store.saves.add(const IoFailure('disk full'));
    w.session.playMove('g8f6');
    await tester.pumpAndSettle();
    expect(w.saver.settled, isFalse);
    final draft = w.session.tree;
    w.store.saves.add(const IoFailure('disk still full'));
    await tester.tap(find.text('Open in Builder'));
    await tester.pumpAndSettle();
    expect(w.question.asked, isNotEmpty);
    expect(w.session.source, kidMain);
    expect(w.session.tree, same(draft));
    expect(w.saver.settled, isFalse);
    expect(w.requests.mode, Mode.trainer);
    expect(w.progress.reviews, isEmpty);
  });
}
