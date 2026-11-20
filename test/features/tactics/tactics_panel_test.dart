import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle_queue.dart';
import 'package:chess_auto_prep/features/tactics/puzzle_filters.dart';
import 'package:chess_auto_prep/features/tactics/tactics_panel.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/status_host.dart';
import '../../support/tactics_fixture.dart';
import '../../support/window_fixture.dart';

/// The Tactics column over the app's own set, trainer and review, with the
/// set the window fixture holds: two blunders, a mistake, an inaccuracy
/// the default filter leaves out and a custom puzzle.
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  final played = <Puzzle?>[];

  Future<void> pumpPanel(WidgetTester tester) async {
    played.clear();
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: TacticsPanel(
              set: w.tactics,
              trainer: w.trainer,
              myGames: w.myGames,
              sources: w.parts.training.sources,
              onPlay: ({first}) => played.add(first),
              onAnalyze: (_) {},
              onAddToStudy: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  Future<void> setFilter(PuzzleFilter filter) =>
      w.settings.update(w.settings.value.copyWith(puzzles: filter));

  Finder playButton() => find.byWidgetPredicate(
    (widget) => widget is FilledButton,
    description: 'Play',
  );

  String playLabel(WidgetTester tester) {
    final label = find.descendant(
      of: playButton().first,
      matching: find.byType(Text),
    );
    return tester.widget<Text>(label.last).data!;
  }

  testWidgets('the puzzles are read on opening; Play plays the list, and '
      'reads Show puzzle while one is up and Resume while one is put '
      'down', (tester) async {
    await pumpPanel(tester);
    expect(find.text('Reading puzzles…'), findsOneWidget);
    await tester.pump();
    expect(playLabel(tester), 'Play (4)');
    await tester.tap(playButton().first);
    expect(played, [null]);

    await w.trainer.start();
    await tester.pump();
    expect(playLabel(tester), 'Show puzzle');
    w.trainer.putDown();
    await tester.pump();
    expect(playLabel(tester), 'Resume');

    // A search that finds nothing leaves a sitting to resume.
    await tester.enterText(find.byType(TextField), 'no such opponent');
    await tester.pump();
    expect(find.text('Nothing matches "no such opponent".'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(playButton().first).onPressed,
      isNotNull,
    );
    w.trainer.end();
    await tester.pump();
    expect(playLabel(tester), 'Play (0)');
    expect(tester.widget<FilledButton>(playButton().first).onPressed, isNull);
  });

  testWidgets('a puzzle clicked in the list is played from, and the one up '
      'is marked with how it went', (tester) async {
    await pumpPanel(tester);
    await tester.pump();
    final mistake = w.tactics.queue.firstWhere(
      (puzzle) => puzzle.kind == MistakeKind.mistake,
    );
    await tester.tap(find.text(mistake.label));
    expect(played, [mistake]);

    await w.trainer.start(first: mistake);
    w.trainer.play('a7a6');
    await tester.pump();
    expect(find.text('failed'), findsOneWidget);
  });

  testWidgets('the count says what the queue holds, worst first, and the '
      'filters open beside it', (tester) async {
    await pumpPanel(tester);
    await tester.pump();
    expect(find.text('4 of 5'), findsOneWidget);
    expect(find.text('2 blunders, 1 mistake, 1 custom'), findsOneWidget);
    expect(find.byType(PuzzleFilters), findsNothing);
    await tester.tap(find.text('Filters'));
    await tester.pump();
    expect(find.byType(PuzzleFilters), findsOneWidget);
    await tester.tap(find.text('Inaccuracies ?!'));
    await tester.pump();
    expect(find.text('5 of 5'), findsOneWidget);
    expect(
      find.text('2 blunders, 1 mistake, 1 inaccuracy, 1 custom'),
      findsOneWidget,
    );
    await tester.tap(find.text('Filters'));
    await tester.pump();
    expect(find.byType(PuzzleFilters), findsNothing);
  });

  testWidgets('filters that let nothing through say so, and a day window '
      'offers the older puzzles back', (tester) async {
    await pumpPanel(tester);
    await tester.pump();
    await setFilter(const PuzzleFilter(kinds: {}));
    await tester.pump();
    expect(find.text('none'), findsOneWidget);
    expect(
      find.text(
        'Your filters rule out every puzzle you have. Open Filters to '
        'loosen them.',
      ),
      findsOneWidget,
    );

    await setFilter(
      const PuzzleFilter(
        days: 1,
        kinds: {MistakeKind.blunder, MistakeKind.mistake},
      ),
    );
    await tester.pump();
    expect(find.text('No puzzles from the last 1 days.'), findsOneWidget);
    await tester.tap(find.text('Include older puzzles'));
    await tester.pump();
    expect(w.settings.value.puzzles.days, isNull);
    expect(find.text('3 of 5'), findsOneWidget);
  });

  testWidgets('a puzzle tried before shows how often it was solved', (
    tester,
  ) async {
    final tried = tacticsSet.replaceFirst(
      '[FlawTags "opening hasty"]',
      '[FlawTags "opening hasty"]\n[ReviewCount "3"]\n[SuccessCount "2"]',
    );
    w.store.documents[tacticsRef] = Opened(tried, scriptedRevision(tried));
    await pumpPanel(tester);
    await tester.pump();
    expect(find.text('2/3'), findsOneWidget);
    expect(find.byTooltip('Solved 2 of 3 tries'), findsOneWidget);
    expect(find.text('0/0'), findsNothing, reason: 'new puzzles say nothing');
  });

  testWidgets('with no set yet it says how to get one, unless the block '
      'above already asks for a username', (tester) async {
    w.store.documents.remove(tacticsRef);
    await pumpPanel(tester);
    await tester.pump();
    const words = 'Get games to turn your mistakes into puzzles.';
    expect(find.text(words), findsNothing);
    w.accounts.accounts[GameSite.lichess] = const Account('Me');
    await w.myGames.load();
    await tester.pump();
    expect(find.text(words), findsOneWidget);
  });

  testWidgets('a set that cannot be read says why and reads it again on '
      'Try again', (tester) async {
    w.store.documents[tacticsRef] = const Unreadable('disk error');
    await pumpPanel(tester);
    await tester.pump();
    expect(find.text('Could not read the puzzles: disk error'), findsOneWidget);
    w.store.documents[tacticsRef] = Opened(
      tacticsSet,
      scriptedRevision(tacticsSet),
    );
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    expect(find.text('4 of 5'), findsOneWidget);
  });

  testWidgets('a puzzle from no saved game copies its own game; a delete '
      'that fails says why, and Cancel deletes nothing', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpPanel(tester);
    await tester.pump();
    final first = w.tactics.queue.first;
    Future<void> menu(String entry) async {
      await tester.tap(find.byTooltip('Puzzle actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry));
      await tester.pumpAndSettle();
    }

    await menu('Copy game PGN');
    expect(copied.single, w.tactics.textOf(first));
    expect(copied.single, contains(first.fen.value));

    await menu('Delete puzzle…');
    expect(find.text('Delete this puzzle?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(w.tactics.puzzles, hasLength(5));
    expect(w.store.requestedSaves, isEmpty);

    w.store.saves.add(const Conflict(null));
    await menu('Delete puzzle…');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Could not delete the puzzle: The puzzles changed on disk. Try again.',
      ),
      findsOneWidget,
    );
    expect(w.tactics.puzzles, hasLength(5));
  });
}
