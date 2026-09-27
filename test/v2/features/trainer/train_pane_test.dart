import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/training/line_order.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/features/trainer/training_scope.dart';
import 'package:chess_auto_prep/v2/features/trainer/lesson_view.dart';
import 'package:chess_auto_prep/v2/features/trainer/train_pane.dart';
import 'package:chess_auto_prep/v2/chess/training/training_options.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/move_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_files.dart';
import '../../support/scripted_progress.dart';
import '../../support/session_fixture.dart';
import '../../support/books_fixture.dart';

const _chapter = '''
// Color: White

[Event "Ruy"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *

[Event "Italian"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 {The Italian.} *
''';

void main() {
  late SessionFixture fixture;
  late ScriptedProgress files;
  late EngineAnalysis analysis;
  late Trainer trainer;
  late List<LineToRead> reads;
  late MoveEntry moves;

  setUp(() async {
    fixture = await openSession(_chapter);
    files = ScriptedProgress();
    moves = MoveEntry();
    analysis = EngineAnalysis(
      fixture.session,
      () async => const StartFailed('no engine in this test'),
    );
  });

  tearDown(() {
    trainer.dispose();
    moves.dispose();
    analysis.dispose();
    fixture.dispose();
  });

  Future<void> pump(WidgetTester tester, {bool rateReviews = false}) async {
    reads = [];
    final settings = SettingsStore(
      initial: Settings(training: TrainingOptions(rateReviews: rateReviews)),
    );
    addTearDown(settings.dispose);
    trainer = Trainer(
      session: fixture.session,
      settings: settings,
      chapters: ScopeReader(files: ScriptedFiles(), documents: fixture.store),
      files: files,
      analysis: analysis,
      time: (now: DateTime.now, jitter: () => 0),
      books: booksWith(),
    );
    await tester.binding.setSurfaceSize(const Size(700, 700));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: TrainPane(trainer: trainer, moves: moves, onRead: reads.add),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  testWidgets('a rating that did not save does not stop the next sitting', (
    tester,
  ) async {
    await pump(tester);
    final ready = trainer.state as TrainerReady;
    files.nextWrite = const ProgressFailed('disk full');
    await ready.progress.finished(ready.lines.first, Rating.good, clean: true);
    await trainer.reload();
    await tester.pumpAndSettle();
    expect(trainer.state, isA<TrainerReady>());
    await tester.tap(find.text('Learn 2'));
    await tester.pumpAndSettle();
    expect(trainer.lesson, isNotNull);
    expect(find.byType(LessonView), findsOneWidget);
  });

  /// Plays [uci] for the lesson, as the board would, and lets it settle.
  Future<void> play(WidgetTester tester, String uci) async {
    trainer.lesson!.play(uci);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'saving the chapter leaves the lesson, its keys and focus alone',
    (tester) async {
      await pump(tester);
      trainer.learn();
      await tester.pumpAndSettle();
      final lessonState = tester.state(find.byType(LessonView));
      final focus = FocusManager.instance.primaryFocus;
      final lesson = trainer.lesson;
      fixture.saver.save('$_chapter\n', const WholeDocument());
      await fixture.saver.flush();
      await tester.pumpAndSettle();
      expect(fixture.saver.settled, isTrue);
      expect(trainer.lesson, same(lesson));
      expect(tester.state(find.byType(LessonView)), same(lessonState));
      expect(FocusManager.instance.primaryFocus, same(focus));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(trainer.lesson, isNull, reason: 'the keys still reach the lesson');
    },
  );

  testWidgets('the lines, where they stand, and the ways in', (tester) async {
    await pump(tester);
    expect(find.text('0 learned · 0 due · 2 untrained'), findsOneWidget);
    expect(find.text('Nothing due'), findsOneWidget);
    expect(find.text('Learn 2'), findsOneWidget);
    expect(find.text('Ruy'), findsOneWidget);
    expect(
      find.text('…3.Bc4'),
      findsOneWidget,
      reason: 'from where it branches',
    );
    expect(find.text('Untrained'), findsNWidgets(2));
  });

  testWidgets('learning shows a move, Space asks for it, Escape leaves', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Learn 2'));
    await tester.pumpAndSettle();
    expect(find.text('Remember 1.e4'), findsOneWidget);
    expect(find.text('Ruy'), findsOneWidget);
    expect(find.text('Main · Learning · 1 more after this'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.space);
    expect(find.text('Your move'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    await key(tester, LogicalKeyboardKey.escape);
    expect(trainer.lesson, isNull);
    expect(find.text('Learn 2'), findsOneWidget);
  });

  testWidgets('a sitting started over the one on screen takes the keys, '
      'wherever the focus went', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Learn 2'));
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    // As the recap's Learn more does, with the lesson view still up.
    trainer.learn();
    await tester.pumpAndSettle();
    expect(find.text('Remember 1.e4'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.space);
    expect(find.text('Your move'), findsOneWidget);
  });

  testWidgets('a wrong move is said with the right one', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Learn 2'));
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.space);
    trainer.lesson!.play('d2d4');
    await tester.pump();
    expect(find.text('Play 1.e4'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Your move'), findsOneWidget, reason: 'asked again');
  });

  Review dueItalian(LineKey italian) => Review(
    key: italian,
    lineName: 'Italian',
    intervalDays: 4,
    lastRating: 'good',
    due: DateTime.now().subtract(const Duration(hours: 1)),
  );

  testWidgets('rating myself, a review ends in the four ratings with the '
      "mistakes' grade filled, and a key picks one", (tester) async {
    final italian = (
      source: fixture.ref.path,
      id: 'line_ZTQgZTUgTmYzIE5jNiBCYz',
    );
    files.reviews[italian] = dueItalian(italian);
    await pump(tester, rateReviews: true);
    expect(find.text('Due now'), findsOneWidget);
    await tester.tap(find.text('Review 1'));
    await tester.pumpAndSettle();
    for (final uci in ['e2e4', 'g1f3', 'f1c4']) {
      await play(tester, uci);
    }
    expect(find.text('Line complete!'), findsOneWidget);
    expect(find.text('The Italian.'), findsOneWidget, reason: 'the note');
    expect(
      find.widgetWithText(FilledButton, 'Good · 10d'),
      findsOneWidget,
      reason: 'a clean line earns Good, which Space would take',
    );
    expect(find.widgetWithText(OutlinedButton, 'Again · now'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.digit3);
    expect(files.reviews[italian]!.intervalDays, 10);
    expect(find.text('Review session done.'), findsOneWidget);
    expect(find.text('1 line · 3 right · 0 wrong'), findsOneWidget);
    await tester.tap(find.text('Back to lines'));
    await tester.pumpAndSettle();
    expect(find.text('Learned · in 10d'), findsOneWidget);
  });

  testWidgets('by default a review is graded without asking', (tester) async {
    final italian = (
      source: fixture.ref.path,
      id: 'line_ZTQgZTUgTmYzIE5jNiBCYz',
    );
    files.reviews[italian] = dueItalian(italian);
    await pump(tester);
    await tester.tap(find.text('Review 1'));
    await tester.pumpAndSettle();
    for (final uci in ['e2e4', 'g1f3', 'f1c4']) {
      await play(tester, uci);
    }
    expect(find.textContaining('Good ·'), findsNothing);
    expect(files.reviews[italian]!.lastRating, 'good');
    expect(find.text('Review session done.'), findsOneWidget);
  });

  testWidgets('a line is left out of training from its menu', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exclude from training'));
    await tester.pumpAndSettle();
    expect(find.text('Excluded'), findsOneWidget);
    expect(find.text('Learn 1'), findsOneWidget);
  });

  testWidgets('the lines in another order; likeliest only when told', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Training order'), findsOneWidget);
    expect(find.text('Most likely first'), findsNothing);
    await tester.tap(find.text('Course order'));
    await tester.pumpAndSettle();
    expect(trainer.order, LineOrder.course);
  });

  testWidgets('a line is read from its menu, in the builder or here', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(reads.single.place, ReadIn.moves);
    expect(reads.single.ref, fixture.ref);
    expect(reads.single.sans, ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4']);
    await tester.tap(find.byTooltip('Actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in Builder'));
    await tester.pumpAndSettle();
    expect(reads.last.place, ReadIn.builder);
  });

  testWidgets('a mistake puts its position on the board', (tester) async {
    files.attempts.add(
      Attempt(
        key: (source: fixture.ref.path, id: 'line_ZTQgZTUgTmYzIE5jNiBCYz'),
        ply: 4,
        fen: const Fen(
          'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3',
        ),
        played: 'd4',
        expected: 'Bc4',
        correct: false,
        phase: AttemptPhase.drilling,
        at: DateTime.now(),
      ),
    );
    await pump(tester);
    await tester.tap(find.text('Mistakes · 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book: 3.Bc4  ·  You: 3.d4'));
    await tester.pumpAndSettle();
    expect(reads.single.place, ReadIn.board);
    expect(reads.single.sans, ['e4', 'e5', 'Nf3', 'Nc6']);
    expect(find.text('Book: 3.Bc4  ·  You: 3.d4'), findsOneWidget);
  });
}
