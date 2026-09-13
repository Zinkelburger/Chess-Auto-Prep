import 'package:chess_auto_prep/services/opening_catalog.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/planner/models/plan_models.dart';
import 'package:chess_auto_prep/features/planner/services/eco_trie.dart';
import 'package:chess_auto_prep/features/planner/services/plan_data_source.dart';
import 'package:chess_auto_prep/features/planner/widgets/plan_build_screen.dart';
import 'package:chess_auto_prep/services/analysis_games_service.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/board_engine_fixture.dart';

/// The planner screen end to end with a scripted book and database: start,
/// answer a fork, split a tabiya, review the chapters, commit.
const _tsv = '''
eco	name	pgn
D06	Queen's Gambit	1. d4 d5 2. c4
D30	Queen's Gambit Declined	1. d4 d5 2. c4 e6
D31	Queen's Gambit Declined: 3.Nc3	1. d4 d5 2. c4 e6 3. Nc3
D35	Queen's Gambit Declined: Exchange	1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. cxd5
D37	Queen's Gambit Declined: 4.Nf3	1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Nf3
D50	Queen's Gambit Declined: 4.Bg5	1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Bg5
D30	Queen's Gambit Declined: 3.Nf3	1. d4 d5 2. c4 e6 3. Nf3
E00	Catalan	1. d4 d5 2. c4 e6 3. g3
D10	Slav Defense	1. d4 d5 2. c4 c6
D11	Slav: 3.Nf3	1. d4 d5 2. c4 c6 3. Nf3
D20	Queen's Gambit Accepted	1. d4 d5 2. c4 dxc4
D21	Queen's Gambit Accepted: 3.Nf3	1. d4 d5 2. c4 dxc4 3. Nf3
''';

class _FakeSource implements PlanDataSource {
  _FakeSource(this.trie);
  final EcoTrie trie;
  final shares = <String, Map<String, double>>{
    'd4 d5 c4': {'e6': 0.40, 'c6': 0.30, 'dxc4': 0.15},
    'd4 d5 c4 e6': {'Nc3': 0.50, 'Nf3': 0.35, 'g3': 0.10, 'cxd5': 0.05},
  };

  @override
  Future<List<PlanCandidate>> candidates({
    required String fen,
    required List<String> moves,
    required bool ourMove,
    required int elo,
  }) async {
    final node = trie.nodeAt(moves);
    final here = shares[moves.join(' ')] ?? const {};
    final sans = {...?node?.children.keys, ...here.keys};
    return [
      for (final san in sans)
        PlanCandidate(
          san: san,
          name: node?.children[san]?.nearestName?.name,
          dbShare: here[san],
          evalCp: san == 'dxc4' ? 40 : 20,
          bookBelow: node?.children[san]?.entriesBelow ?? 0,
        ),
    ]..sort((a, b) => (b.share ?? 0).compareTo(a.share ?? 0));
  }

  @override
  Future<String?> nameFor(List<String> moves) async =>
      trie.nameFor(moves)?.name;

  @override
  Future<int> tabiyaScore(List<String> moves) async =>
      trie.tabiyaScoreAt(moves);

  @override
  Future<({int cp, int depth})?> engineEval(String fen) async =>
      (cp: 15, depth: 12);

  @override
  Future<({int cp, int depth, String source})?> dbEval(String fen) async =>
      null;
}

/// Serves one fixed PGN for any account instead of reading the corpus store.
class _FakeGames extends AnalysisGamesService {
  _FakeGames(this.pgn);
  final String pgn;
  @override
  Future<String?> loadAnalysisGames(String platform, String username) async =>
      pgn;
}

const _blackGames = '''
[Event "?"]
[White "opp"]
[Black "me"]
[Result "*"]

1. d4 d5 2. c4 e6 3. Nc3 Nf6 *

[Event "?"]
[White "opp"]
[Black "me"]
[Result "*"]

1. d4 d5 2. c4 e6 3. Nf3 Nf6 *

[Event "?"]
[White "opp"]
[Black "me"]
[Result "*"]

1. d4 d5 2. c4 c6 3. Nf3 Nf6 *

[Event "?"]
[White "opp"]
[Black "me"]
[Result "*"]

1. d4 d5 2. c4 c6 3. Nc3 Nf6 *
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    useScriptedBoardEngine();
  });

  /// Pumps the host and opens the planner; the route's result lands in
  /// [holder] when the planner pops.
  Future<void> pumpPlanner(
    WidgetTester tester,
    List<PlanBuildResult?> holder,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                holder[0] = await Navigator.of(context).push<PlanBuildResult>(
                  MaterialPageRoute(
                    builder: (_) => PlanBuildScreen(
                      isWhite: false,
                      repertoireName: 'French',
                      outline: null,
                      initialMoves: const ['d4', 'd5', 'c4'],
                      baseConfig: const TreeBuildConfig(
                        startFen: kStandardStartFen,
                        playAsWhite: false,
                      ),
                      dataSource: _FakeSource(EcoTrie.build([_tsv])),
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('start → fork question → tabiya → review → commit', (
    tester,
  ) async {
    final holder = <PlanBuildResult?>[null];
    await pumpPlanner(tester, holder);

    // Start screen: root position only, moves the board was on, and the
    // choice of what to walk — the book by default, or your games.
    expect(find.text('Starting positions'), findsOneWidget);
    expect(find.text('1.d4 d5 2.c4'), findsWidgets);
    expect(find.text('Opening book'), findsOneWidget);
    expect(find.text('My games'), findsOneWidget);
    expect(find.text('Prefer lines I play in my games'), findsNothing);
    // Nothing else competes for attention on this screen.
    expect(find.textContaining('Reply coverage'), findsNothing);
    expect(find.textContaining('rating'), findsNothing);

    // Retired arrow shortcuts leave the setup unchanged.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1.d4 d5 2.c4'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('1.d4 d5 2.c4'), findsWidgets);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 1.d4 d5 2.c4, Black to move: our fork with named candidates.
    expect(find.text('How do you play here?'), findsOneWidget);
    expect(find.textContaining("Queen's Gambit Declined"), findsOneWidget);
    expect(find.textContaining('Slav Defense'), findsOneWidget);
    // Maia share and cumulative reach (root → 100%) both show.
    expect(find.text('40%'), findsNWidgets(2));

    // Tapping a row selects it (one at our move) and shows it on the board.
    await tester.tap(find.textContaining('Slav Defense'));
    await tester.pumpAndSettle();
    expect(find.text('back to question'), findsOneWidget);
    // Number keys no longer select a row; use the visible choice and button.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining("Queen's Gambit Declined"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Now the White tabiya after 2…e6: coverage card, big replies pre-ticked.
    expect(find.text('Which replies do you want to set up?'), findsOneWidget);
    expect(find.textContaining('Catalan'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Below the tabiya the book runs out — but the walk never stops
    // silently: each end is shown and confirmed with its button; a leaf
    // confirmation is one per ticked reply.
    expect(find.text('Generate from here'), findsOneWidget);
    for (
      var i = 0;
      i < 6 && find.text('Generate from here').evaluate().isNotEmpty;
      i++
    ) {
      await tester.tap(find.text('Generate from here'));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining(RegExp(r'chapters? to create')), findsOneWidget);

    await tester.tap(find.textContaining('& generate'));
    await tester.pumpAndSettle();

    final result = holder[0];
    expect(result, isNotNull);
    expect(result!.generate, isTrue);
    expect(result.plan.isWhite, isFalse);
    // Every common reply at the tabiya (down to 3%) is a set-up line —
    // a build point — but only differently named systems are chapters.
    final builds = result.plan.chapters
        .expand((c) => c.buildPaths)
        .map((p) => p.join(' '))
        .toSet();
    for (final reply in ['Nc3', 'Nf3', 'g3', 'cxd5']) {
      expect(builds, contains('d4 d5 c4 e6 $reply'), reason: reply);
    }
    expect(result.plan.chapters.length, lessThan(builds.length));
  });

  testWidgets(
    'multiple named positions can skip the quiz and return a ChessDB batch',
    (tester) async {
      final holder = <PlanBuildResult?>[null];
      await pumpPlanner(tester, holder);
      final input = find.byKey(const ValueKey('plan-starting-lines'));
      await tester.enterText(
        input,
        'Main KID | 1.d4 Nf6 2.c4 g6 3.Nc3 Bg7 4.e4 d6\nFianchetto KID | 1.d4 Nf6 2.c4 g6 3.Nf3 Bg7 4.g3 d6\nLondon | 1.d4 Nf6 2.Bf4 d5',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plan-preview-1')));
      await tester.pumpAndSettle();
      expect(find.text('1.d4 Nf6 2.c4 g6 3.Nf3 Bg7 4.g3 d6'), findsOneWidget);
      await tester.ensureVisible(find.text('Use these positions'));
      await tester.tap(find.text('Use these positions'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review & build'));
      await tester.tap(find.text('Review & build'));
      await tester.pumpAndSettle();
      expect(find.text('3 chapters to create'), findsOneWidget);
      await tester.tap(find.text('Edit starting lines'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        contains('Fianchetto KID'),
      );
      await tester.ensureVisible(find.text('Review & build'));
      await tester.tap(find.text('Review & build'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create 3 & generate'));
      await tester.pumpAndSettle();
      final result = holder.single!;
      expect(result.config.buildMode, BuildMode.chessDbBook);
      expect(result.plan.isWhite, isFalse);
      expect(result.plan.chapters.map((c) => c.name), [
        'Main KID',
        'Fianchetto KID',
        'London',
      ]);
      expect(result.plan.chapters.map((c) => c.points.single.moves.length), [
        8,
        8,
        4,
      ]);
    },
  );

  testWidgets(
    'adding and removing a board starting position preserves the other line',
    (tester) async {
      await pumpPlanner(tester, <PlanBuildResult?>[null]);
      await tester.tap(find.byKey(const ValueKey('plan-add-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '1.e4'));
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('plan-starting-lines')),
      );
      expect(input.controller!.text, contains('1.d4 d5 2.c4'));
      expect(input.controller!.text, contains('Line 2 | 1.e4'));
      await tester.tap(find.byKey(const ValueKey('plan-remove-start')));
      await tester.pumpAndSettle();
      expect(input.controller!.text, '1.d4 d5 2.c4');
    },
  );

  testWidgets(
    'ECO selection adds an edited named start alongside existing starts',
    (tester) async {
      await tester.runAsync(OpeningCatalog.load);
      await pumpPlanner(tester, [null]);
      final choose = find.byKey(const ValueKey('plan-choose-eco'));
      await tester.ensureVisible(choose);
      await tester.tap(choose);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('opening-search')),
        'B00 Barnes',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('opening-moves')),
        '1.e4 c5',
      );
      await tester.tap(find.text('Add starting lines (1)'));
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('plan-starting-lines')),
      );
      expect(input.controller!.text, contains('1.d4 d5 2.c4'));
      expect(input.controller!.text, contains('B00 Barnes Defense | 1.e4 c5'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid and overlapping starting lines cannot advance', (
    tester,
  ) async {
    await pumpPlanner(tester, <PlanBuildResult?>[null]);
    final input = find.byKey(const ValueKey('plan-starting-lines'));
    for (final text in ['1.d4 Nf6 2.Kxe8', '1.d4\n1.d4 Nf6']) {
      await tester.enterText(input, text);
      await tester.pumpAndSettle();
      final next = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Next'),
      );
      expect(next.onPressed, isNull);
    }
    await tester.enterText(input, '1.d4 Nf6');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('Finish now mid-walk goes to review without errors', (
    tester,
  ) async {
    final holder = <PlanBuildResult?>[null];
    await pumpPlanner(tester, holder);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('How do you play here?'), findsOneWidget);

    await tester.tap(find.text('Finish now'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining(RegExp(r'chapters? to create')), findsOneWidget);

    // Nothing was answered, so there is nothing to go back to: the button
    // is disabled rather than leaving the screen on a spinner.
    final back = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '‹ Back to choices'),
    );
    expect(back.onPressed, isNull);
  });

  testWidgets('a short, narrow window does not overflow', (tester) async {
    tester.view.physicalSize = const Size(960, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: PlanBuildScreen(
          isWhite: false,
          repertoireName: 'French',
          outline: null,
          initialMoves: const ['d4', 'd5', 'c4'],
          baseConfig: const TreeBuildConfig(
            startFen: kStandardStartFen,
            playAsWhite: false,
          ),
          dataSource: _FakeSource(EcoTrie.build([_tsv])),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The start card scrolls in a window this short; Next is below the fold.
    await tester.dragUntilVisible(
      find.text('Next'),
      find.byType(ListView),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('My games', () {
    Future<void> pump(
      WidgetTester tester, {
      String? lichessUsername,
      AnalysisGamesService? games,
    }) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: PlanBuildScreen(
            isWhite: false,
            repertoireName: 'French',
            outline: null,
            initialMoves: const ['d4', 'd5'],
            baseConfig: const TreeBuildConfig(
              startFen: kStandardStartFen,
              playAsWhite: false,
            ),
            dataSource: _FakeSource(EcoTrie.build([_tsv])),
            lichessUsername: lichessUsername,
            gamesService: games,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The games are counted on another isolate — real time, outside the
      // test's fake clock — so give that work a moment to land.
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (find.textContaining('of your games').evaluate().isNotEmpty ||
            find.textContaining('No accounts').evaluate().isNotEmpty) {
          break;
        }
      }
    }

    testWidgets('without an account the games walk says why it cannot run', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('My games'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No accounts in Settings'), findsOneWidget);
      final next = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Next'),
      );
      expect(next.onPressed, isNull);
    });

    testWidgets('walks the positions your games reached', (tester) async {
      await pump(tester, lichessUsername: 'me', games: _FakeGames(_blackGames));
      await tester.tap(find.text('My games'));
      await tester.pumpAndSettle();
      expect(find.textContaining('4 of your games as Black'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      // 1.d4 d5: all four games saw 2.c4 — one reply, ticked, and the card
      // says how many games this is.
      expect(find.text('Which replies do you want to set up?'), findsOneWidget);
      expect(find.textContaining('4 of your games'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      // 2.c4: your move; …e6 (2 games) leads, …c6 (2 games) beside it.
      expect(find.text('How do you play here?'), findsOneWidget);
      expect(find.textContaining('50% · 4'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });
}
