import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/planner/models/plan_models.dart';
import 'package:chess_auto_prep/features/planner/services/eco_trie.dart';
import 'package:chess_auto_prep/features/planner/services/plan_data_source.dart';
import 'package:chess_auto_prep/features/planner/widgets/plan_build_screen.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
    // prefill on by default with a plain way to turn the games part off.
    expect(find.text('Where should this start?'), findsOneWidget);
    expect(find.text('1.d4 d5 2.c4'), findsWidgets);
    // Nothing else competes for attention on this screen.
    expect(find.textContaining('replies'), findsNothing);
    expect(find.textContaining('rating'), findsNothing);

    // ← undoes a start move on the board, → redoes it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1.d4 d5'), findsWidgets);
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
    // Row 1 via keyboard: …e6 becomes the single choice; Enter continues.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // Now the White tabiya after 2…e6: coverage card, big replies pre-ticked.
    expect(find.text('Which replies do you want to set up?'), findsOneWidget);
    expect(find.textContaining('Catalan'), findsOneWidget);
    await tester.tap(find.text('Continue  (Enter)'));
    await tester.pumpAndSettle();

    // Below the tabiya the book runs out — but the walk never stops
    // silently: each end is shown and confirmed. Enter confirms; a leaf
    // confirmation is one per ticked reply.
    expect(find.text('Generate from here  (Enter)'), findsOneWidget);
    for (
      var i = 0;
      i < 6 && find.text('Generate from here  (Enter)').evaluate().isNotEmpty;
      i++
    ) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
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
}
