import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/trainer/lesson_view.dart';
import 'package:chess_auto_prep/features/trainer/train_pane.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/features/trainer/trainer_state.dart';
import 'package:chess_auto_prep/features/trainer/training_outline.dart';
import 'package:chess_auto_prep/features/trainer/training_scope.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/storage/training_progress.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/ui/toggle_chip.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/board/move_field.dart';
import 'package:chess_auto_prep/workspace/book/repertoire_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/books_fixture.dart';
import '../../support/scripted_files.dart';
import '../../support/scripted_progress.dart';
import '../../support/scripted_store.dart';
import '../../support/session_fixture.dart';

/// The trainer mode's desk: the outline of the chosen repertoire beside the
/// Train tab's home, as the shell puts them.

const _main = '''
// Color: White

[Event "Ruy"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *

[Event "Italian"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 *
''';

/// One line to train, of one move of the user's; a model game to read; and a
/// line with none of the user's moves: only the first is a line to train.
const _other = '''
// Color: White

[Event "Queen's Gambit"]

1. d4 d5 *

[Event "Model"]
[ModelGameResult "1-0"]

1. d4 Nf6 2. c4 *

[Event "Stub"]
[SetUp "1"]
[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"]

1... c5 *
''';

final _now = DateTime.utc(2026, 9, 22, 12);

void main() {
  late SessionFixture session;
  late ScriptedProgress progress;
  late EngineAnalysis analysis;
  late RepertoireCatalog catalog;
  late SettingsStore settings;
  late MoveEntry moves;
  late Trainer trainer;
  late List<LineToRead> reads;

  final kidMain = ref('KID', 'Main');
  final kidOther = ref('KID', 'Other');

  // Built inside each test, so the trainer's futures run in the test's
  // zone and pumping lands its writes.
  Future<void> start(List<Attempt> attempts) async {
    session = await openSession(_main);
    session.store.documents[kidOther] = Opened(
      _other,
      scriptedRevision(_other),
    );
    final files = ScriptedFiles(
      listing: Repertoires([
        folder('KID', ['Main', 'Other']),
      ]),
    );
    progress = ScriptedProgress()..attempts.addAll(attempts);
    analysis = EngineAnalysis(
      session.session,
      () async => const StartFailed('test'),
    );
    catalog = RepertoireCatalog(files: files, root: '/repertoires');
    await catalog.refresh();
    settings = SettingsStore();
    moves = MoveEntry();
    reads = [];
    trainer = Trainer(
      session: session.session,
      chapters: ScopeReader(files: files, documents: session.store),
      files: progress,
      analysis: analysis,
      catalog: catalog,
      settings: settings,
      time: (now: () => _now, jitter: () => 0),
      books: booksWith(),
    );
    trainer.selection.choose(catalog.repertoires.single);
    await trainer.reload();
  }

  tearDown(() {
    trainer.dispose();
    moves.dispose();
    settings.dispose();
    catalog.dispose();
    analysis.dispose();
    session.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    List<Attempt> attempts = const [],
  }) async {
    await start(attempts);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 400,
                child: TrainingOutline(
                  trainer: trainer,
                  onRead: reads.add,
                  onImport: () {},
                  trailing: const SizedBox.shrink(),
                ),
              ),
              Expanded(
                child: TrainPane(
                  trainer: trainer,
                  moves: moves,
                  onRead: reads.add,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TrainerReady ready() => trainer.state as TrainerReady;

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String tooltip, String item) async {
    await tap(tester, find.byTooltip(tooltip).first);
    await tap(tester, find.text(item));
  }

  testWidgets('the whole repertoire is counted and offered to learn', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('2 chapters · 3 lines'), findsOneWidget);
    expect(find.text('0 of 3 learned · 0 due'), findsOneWidget);
    expect(find.text('3 new to learn · 0 to review'), findsOneWidget);
    expect(find.text('Next to learn'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Review'))
          .onPressed,
      isNull,
      reason: 'nothing is due',
    );

    await tap(tester, find.widgetWithText(FilledButton, 'Learn'));
    expect(find.byType(LessonView), findsOneWidget);
    expect(trainer.lesson!.left, 2);
  });

  testWidgets('a chapter chosen in the outline narrows the desk to it', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, find.text('Other'));
    expect(trainer.selection.chapter, kidOther);
    expect(find.text('0 of 1 learned · 0 due'), findsOneWidget);
    expect(find.text("Queen's Gambit"), findsWidgets);

    await tap(tester, find.byTooltip('Back to KID'));
    expect(trainer.selection.chapter, isNull);
    expect(find.text('0 of 3 learned · 0 due'), findsOneWidget);
  });

  testWidgets('a line chosen in the outline goes on the board and can be '
      'learned alone', (tester) async {
    await pump(tester);
    await tap(tester, find.byTooltip('Expand chapter').first);
    await tap(tester, find.text('Italian'));
    expect(trainer.selection.line, ready().lines[1].key);
    expect(reads.last.place, ReadIn.board);
    expect(reads.last.sans, ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4']);
    expect(find.widgetWithText(FilledButton, 'Learn this line'), findsOne);

    await tap(tester, find.text('Read moves and notes'));
    expect(reads.last.place, ReadIn.moves);

    await tap(tester, find.widgetWithText(FilledButton, 'Learn this line'));
    expect(trainer.lesson!.line.name, 'Italian');
    expect(trainer.lesson!.left, 0);
  });

  testWidgets('a line ticked in the outline is learned; untick forgets it', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, find.byTooltip('Expand chapter').first);
    await tap(tester, find.byType(Checkbox).first);
    final ruy = ready().lines.first;
    expect(ready().progress.reviewOf(ruy).untrained, isFalse);
    expect(find.text('1 of 3 learned · 0 due'), findsOneWidget);
    expect(find.text('1/2 learned'), findsOneWidget);

    await tap(tester, find.byType(Checkbox).first);
    expect(ready().progress.reviewOf(ruy).untrained, isTrue);
  });

  testWidgets('choosing lines trains only the ones picked', (tester) async {
    await pump(tester);
    await tap(tester, find.text('Choose lines'));
    expect(trainer.selection.choosing, isTrue);
    expect(
      find.text('Select lines in the outline to learn or review.'),
      findsOneWidget,
    );
    await tap(tester, find.byTooltip('Expand chapter').at(1));
    await tap(tester, find.text("Queen's Gambit"));
    expect(trainer.selection.picked, {
      ready().lines.firstWhere((l) => l.name == "Queen's Gambit").key,
    });
    expect(find.text('1 selected'), findsOneWidget);
    expect(reads, isEmpty, reason: 'picking reads nothing');

    await tap(tester, find.widgetWithText(FilledButton, 'Learn'));
    expect(trainer.lesson!.line.name, "Queen's Gambit");
    expect(trainer.lesson!.left, 0);
  });

  testWidgets('a paused repertoire offers Resume and keeps its lines out', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, find.text('Pause repertoire training'));
    expect(trainer.selection.repertoirePaused, isTrue);
    expect(find.text('This repertoire is paused.'), findsOneWidget);
    expect(find.text('Your progress is kept.'), findsOneWidget);
    expect(trainer.learnCount, 0);

    await tap(tester, find.widgetWithText(FilledButton, 'Resume'));
    expect(trainer.selection.repertoirePaused, isFalse);
    expect(trainer.learnCount, 3);
  });

  testWidgets('a paused chapter is said in the outline and resumed from the '
      'desk', (tester) async {
    await pump(tester);
    await tap(tester, find.text('Other'));
    await tap(tester, find.text('Pause chapter training'));
    expect(trainer.selection.chapterPaused(kidOther), isTrue);
    expect(find.text('Paused · 0/1 learned'), findsOneWidget);
    expect(find.text('Training is paused for this chapter.'), findsOneWidget);

    await tap(tester, find.widgetWithText(FilledButton, 'Resume'));
    expect(trainer.selection.chapterPaused(kidOther), isFalse);
  });

  testWidgets('a paused line is excluded, and Resume puts it back', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, find.byTooltip('Expand chapter').first);
    await tap(tester, find.text('Italian'));
    await tap(tester, find.text('Pause line training'));
    final italian = ready().lines[1];
    expect(ready().progress.reviewOf(italian).excluded, isTrue);
    expect(find.text('Training is paused for this line.'), findsOneWidget);

    await tap(tester, find.widgetWithText(FilledButton, 'Resume'));
    expect(ready().progress.reviewOf(italian).excluded, isFalse);
  });

  testWidgets('the outline\'s chapter menu learns and pauses that chapter', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, find.byTooltip('Chapter training actions').at(1));
    await tap(tester, find.text('Pause chapter training'));
    expect(trainer.selection.chapterPaused(kidOther), isTrue);
    await tap(tester, find.byTooltip('Chapter training actions').at(1));
    await tap(tester, find.text('Resume chapter training'));
    expect(trainer.selection.chapterPaused(kidOther), isFalse);

    await menu(tester, 'Chapter training actions', 'Learn this chapter');
    expect(trainer.selection.chapter, kidMain);
    expect(trainer.lesson!.left, 1, reason: 'the two lines of Main');
  });

  testWidgets('a line\'s menu excludes it and brings it back', (tester) async {
    await pump(tester);
    await tap(tester, find.byTooltip('Expand chapter').first);
    await menu(tester, 'Line training actions', 'Exclude from training');
    final ruy = ready().lines.first;
    expect(ready().progress.reviewOf(ruy).excluded, isTrue);
    expect(find.text('Paused'), findsOneWidget);
    await menu(tester, 'Line training actions', 'Include in training');
    expect(ready().progress.reviewOf(ruy).excluded, isFalse);
  });

  testWidgets('searching the outline finds a line inside a chapter', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).last, 'd4');
    await tester.pumpAndSettle();
    expect(find.text("Queen's Gambit"), findsWidgets);
    expect(find.text('Main'), findsNothing);
    await tester.enterText(find.byType(TextField).last, 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "zzz".'), findsOneWidget);
  });

  testWidgets('the scope\'s mistakes are listed and put their position on the '
      'board', (tester) async {
    final italian = (source: kidMain.path, id: 'line_ZTQgZTUgTmYzIE5jNiBCYz');
    final mistake = Attempt(
      key: italian,
      ply: 4,
      fen: Fen.initial,
      played: 'Bb5',
      expected: 'Bc4',
      correct: false,
      phase: AttemptPhase.drilling,
      at: _now,
    );
    await pump(tester, attempts: [mistake]);
    await tap(tester, find.text('Mistakes · 1'));
    await tap(tester, find.text('Played Bb5 · expected Bc4'));
    expect(reads.last.place, ReadIn.board);
    expect(reads.last.sans, ['e4', 'e5', 'Nf3', 'Nc6']);
    await tap(tester, find.text('Hide mistakes'));
    expect(find.text('Played Bb5 · expected Bc4'), findsNothing);

    await tap(tester, find.text('Other'));
    expect(find.text('Mistakes · 0'), findsOneWidget);
  });

  testWidgets('reviews take every learned line when told, and are rated by '
      'hand when told', (tester) async {
    await pump(tester);
    await menu(tester, 'Training actions', 'Mark scope as learned');
    expect(find.text('3 of 3 learned · 0 due'), findsOneWidget);
    expect(trainer.reviewCount, 0);
    expect(
      find.text(
        'No new lines in this scope. Review learned lines or choose another '
        'chapter.',
      ),
      findsOneWidget,
    );

    await tap(tester, find.text('All learned'));
    expect(trainer.options.reviewAll, isTrue);
    expect(trainer.reviewCount, 3);
    await tap(tester, find.text('Due'));
    expect(trainer.options.reviewAll, isFalse);

    await tap(tester, find.text('Rate difficulty myself'));
    expect(trainer.options.rateReviews, isTrue);
    expect(settings.value.training.rateReviews, isTrue);

    await menu(tester, 'Training actions', 'Mark scope as new');
    expect(find.text('0 of 3 learned · 0 due'), findsOneWidget);
  });

  testWidgets('the review chips show which lines a review takes', (
    tester,
  ) async {
    bool chip(String label) => tester
        .widget<ToggleChip>(find.widgetWithText(ToggleChip, label))
        .selected;
    await pump(tester);
    expect(
      (chip('Due'), chip('All learned'), chip('Choose lines')),
      (true, false, false),
    );
    await tap(tester, find.text('All learned'));
    expect((chip('Due'), chip('All learned')), (false, true));
    await tap(tester, find.text('Choose lines'));
    expect((chip('Due'), chip('All learned')), (false, false));
    expect(chip('0 selected'), isTrue);

    await tap(tester, find.text('Due'));
    expect(trainer.selection.choosing, isFalse);
    expect(
      (chip('Due'), chip('All learned'), chip('Choose lines')),
      (true, false, false),
    );
  });

  testWidgets('a model game and a line with none of the user\'s moves are '
      'read only', (tester) async {
    await pump(tester);
    await tap(tester, find.byTooltip('Expand chapter').at(1));
    expect(find.text('Read only'), findsNWidgets(2));
    expect(find.text('New'), findsOneWidget, reason: "the Queen's Gambit");
    expect(
      find.descendant(
        of: find.byType(TrainingOutline),
        matching: find.byType(Checkbox),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the outline marks the scope on the desk', (tester) async {
    bool selected(String title) => tester
        .widget<ListTile>(find.widgetWithText(ListTile, title).first)
        .selected;
    await pump(tester);
    expect((selected('Whole repertoire'), selected('Main')), (true, false));
    await tap(tester, find.text('Main'));
    expect((selected('Whole repertoire'), selected('Main')), (false, true));
    expect(selected('Ruy'), isFalse);
    await tap(tester, find.text('Ruy').first);
    expect((selected('Main'), selected('Ruy')), (false, true));
    expect(selected('Italian'), isFalse);
  });

  testWidgets('searching by a chapter\'s name shows all its lines; by a move, '
      'only the lines that play it', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).last, 'other');
    await tester.pumpAndSettle();
    expect(find.text('Other'), findsOneWidget);
    expect(find.text("Queen's Gambit"), findsWidgets);
    expect(find.text('Stub'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'd4');
    await tester.pumpAndSettle();
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Stub'), findsNothing);
  });

  testWidgets('an excluded line cannot be learned from its menu', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, find.byTooltip('Expand chapter').first);
    await menu(tester, 'Line training actions', 'Exclude from training');
    await tap(tester, find.byTooltip('Line training actions').first);
    final learn = tester.widget<MenuItemButton>(
      find.widgetWithText(MenuItemButton, 'Learn this line'),
    );
    expect(learn.onPressed, isNull);
  });

  testWidgets('a line marked learned from the desk', (tester) async {
    await pump(tester);
    await tap(tester, find.byTooltip('Expand chapter').first);
    await tap(tester, find.text('Ruy').first);
    await tap(tester, find.text('Learned'));
    expect(ready().progress.reviewOf(ready().lines.first).untrained, isFalse);
  });

  testWidgets('a progress change that did not save is said', (tester) async {
    await pump(tester);
    progress.nextWrite = const ProgressFailed('disk full');
    await menu(tester, 'Training actions', 'Mark scope as learned');
    expect(
      find.text(
        'Training progress could not be saved. Reload progress and try again.',
      ),
      findsOneWidget,
    );
  });
}
