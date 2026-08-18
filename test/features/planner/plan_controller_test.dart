import 'package:chess_auto_prep/features/planner/controllers/plan_controller.dart';
import 'package:chess_auto_prep/features/planner/models/plan_models.dart';
import 'package:chess_auto_prep/features/planner/services/eco_trie.dart';
import 'package:chess_auto_prep/features/planner/services/plan_data_source.dart';
import 'package:chess_auto_prep/features/planner/services/plan_knowledge.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tiny book: enough lines through 1.d4 d5 2.c4 to make it a Black fork,
/// and enough White replies after 2...e6 to make that a tabiya, then thin.
const _tsv = '''
eco	name	pgn
D06	Queen's Gambit	1. d4 d5 2. c4
D30	Queen's Gambit Declined	1. d4 d5 2. c4 e6
D31	Queen's Gambit Declined: 3.Nc3	1. d4 d5 2. c4 e6 3. Nc3
D35	Queen's Gambit Declined: Exchange	1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. cxd5
D37	Queen's Gambit Declined: 4.Nf3	1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Nf3
D50	Queen's Gambit Declined: 4.Bg5	1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Bg5
D30	Queen's Gambit Declined: 3.Nf3	1. d4 d5 2. c4 e6 3. Nf3
D30	Queen's Gambit Declined: 3.Nf3 Nf6	1. d4 d5 2. c4 e6 3. Nf3 Nf6
E00	Catalan	1. d4 d5 2. c4 e6 3. g3
E01	Catalan Closed	1. d4 d5 2. c4 e6 3. g3 Nf6 4. Bg2
D10	Slav Defense	1. d4 d5 2. c4 c6
D11	Slav: 3.Nf3	1. d4 d5 2. c4 c6 3. Nf3
D15	Slav: 3.Nc3	1. d4 d5 2. c4 c6 3. Nc3
D20	Queen's Gambit Accepted	1. d4 d5 2. c4 dxc4
D21	Queen's Gambit Accepted: 3.Nf3	1. d4 d5 2. c4 dxc4 3. Nf3
D02	London System	1. d4 d5 2. Bf4
D02	London: 2...Nf6	1. d4 d5 2. Bf4 Nf6
D02	London: 2...c5	1. d4 d5 2. Bf4 c5
''';

/// Book-only source with scripted database shares per position.
class _FakeSource implements PlanDataSource {
  _FakeSource(this.trie, this.shares);
  final EcoTrie trie;

  /// moves-key ("d4 d5 c4") → san → share
  final Map<String, Map<String, double>> shares;

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
    final list = [
      for (final san in sans)
        PlanCandidate(
          san: san,
          name: node?.children[san]?.nearestName?.name,
          dbShare: here[san],
          bookBelow: node?.children[san]?.entriesBelow ?? 0,
        ),
    ]..sort((a, b) => (b.share ?? 0).compareTo(a.share ?? 0));
    return list;
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
  final trie = EcoTrie.build([_tsv]);
  final shares = <String, Map<String, double>>{
    'd4 d5': {'c4': 0.80, 'Bf4': 0.15, 'Nf3': 0.05},
    'd4 d5 c4': {'e6': 0.40, 'c6': 0.30, 'dxc4': 0.15, 'Nf6': 0.05},
    'd4 d5 c4 e6': {'Nc3': 0.50, 'Nf3': 0.35, 'g3': 0.10, 'cxd5': 0.05},
  };

  group('EcoTrie', () {
    test('scores forks higher than forced lines', () {
      expect(trie.entryCount, 18);
      final atC4 = trie.tabiyaScoreAt(['d4', 'd5', 'c4']);
      final atSlav3 = trie.tabiyaScoreAt(['d4', 'd5', 'c4', 'c6', 'Nf3']);
      expect(atC4, greaterThan(atSlav3));
      expect(trie.tabiyaScoreAt(['e4']), 0);
    });

    test('names the deepest book position on a path', () {
      expect(
        trie.nameFor(['d4', 'd5', 'c4', 'e6', 'Nc3'])?.name,
        "Queen's Gambit Declined: 3.Nc3",
      );
      // Off-book continuation keeps the last name.
      expect(
        trie.nameFor(['d4', 'd5', 'c4', 'e6', 'Nc3', 'a6'])?.name,
        "Queen's Gambit Declined: 3.Nc3",
      );
    });
  });

  group('PlanController', () {
    PlanController make({PlanKnowledge knowledge = PlanKnowledge.empty}) =>
        PlanController(
          source: _FakeSource(trie, shares),
          isWhite: false,
          knowledge: knowledge,
          tabiyaThreshold: 6,
          chapterShare: 0.08,
          minShare: 0.05,
        );

    test('walks 1.d4 d5 → asks at 2.c4 fork for Black', () async {
      final c = make();
      await c.start(['d4', 'd5']);
      // 1.d4 d5: White to move, a tabiya (c4 / Bf4 / Nf3) → coverage step.
      expect(c.step!.kind, PlanStepKind.theirMove);
      expect(c.step!.preselected, containsAll(['c4', 'Bf4']));
      expect(c.step!.preselected, isNot(contains('Nf3')));

      await c.acceptCoverage(c.step!.preselected);
      // Nf3 (5%) is at the floor → an "other replies" build point at
      // 1.d4 d5, inside the root chapter; the London (15%, another family)
      // became its own chapter.
      final root = c.chapters.first;
      expect(root.points.where((pt) => pt.isSidelines), hasLength(1));
      expect(root.points.single.excludeReplies, containsAll(['c4', 'Bf4']));
      expect(c.chapters.map((ch) => ch.family), contains('London System'));

      // Next: 1.d4 d5 2.c4, Black to move, a fork → our-move question.
      expect(c.step!.moves, ['d4', 'd5', 'c4']);
      expect(c.step!.kind, PlanStepKind.ourMove);
      expect(c.step!.candidates.first.san, 'e6');
      expect(c.step!.candidates.first.name, "Queen's Gambit Declined");
    });

    test('a known chapter move is taken without asking', () async {
      final knowledge = PlanKnowledge(
        chapterMoves: PlanKnowledge.countOurMovesInLines([
          ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6'],
        ], isWhite: false),
      );
      final c = make(knowledge: knowledge);
      await c.start(['d4', 'd5', 'c4']);
      // …e6 is decided by the chapters; the walk lands on the White tabiya
      // after 2…e6 without asking about 2.c4.
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6']);
      expect(c.step!.kind, PlanStepKind.theirMove);
      expect(c.decisions.first, contains('e6 (already in your chapters)'));
    });

    test(
      'splitting an opponent tabiya yields sibling chapters + sidelines',
      () async {
        final c = make();
        await c.start(['d4', 'd5', 'c4', 'e6']);
        expect(c.step!.kind, PlanStepKind.theirMove);
        expect(c.step!.preselected, {'Nc3', 'Nf3', 'g3'});
        await c.acceptCoverage(['Nc3', 'Nf3', 'g3']);
        // cxd5 at 5% keeps an "other replies" build point at the tabiya.
        final plan = await c.finish();
        final families = plan.chapters.map((ch) => ch.family).toList();
        // The QGD root chapter, plus the Catalan (10% ≥ chapterMass and
        // another family). 3.Nc3 and 3.Nf3 stay QGD → no chapters of their
        // own.
        expect(families, ["Queen's Gambit Declined", 'Catalan']);
        final root = plan.chapters.firstWhere(
          (ch) => ch.family == "Queen's Gambit Declined",
        );
        final side = root.points.firstWhere((pt) => pt.isSidelines);
        expect(side.moves, ['d4', 'd5', 'c4', 'e6']);
        expect(side.excludeReplies, ['Nc3', 'Nf3', 'g3']);
      },
    );

    test('choosing two moves makes two branches, and back undoes it', () async {
      final c = make();
      await c.start(['d4', 'd5', 'c4']);
      expect(c.step!.kind, PlanStepKind.ourMove);
      await c.choose(['e6', 'c6']);
      expect(c.openBranches, 2);
      expect(c.canGoBack, isTrue);
      await c.back();
      expect(c.step!.moves, ['d4', 'd5', 'c4']);
      expect(c.chapters.every((ch) => ch.points.isEmpty), isTrue);
    });

    test('stop here cuts a chapter at the question position', () async {
      final c = make();
      await c.start(['d4', 'd5', 'c4']);
      await c.stopHere();
      final plan = await c.finish();
      expect(plan.chapters.single.points.single.moves, ['d4', 'd5', 'c4']);
      expect(plan.chapters.single.name, "Queen's Gambit");
    });

    test('lines inside one family stay in one chapter', () async {
      final c = make();
      await c.start(['d4', 'd5', 'c4', 'e6']);
      await c.acceptCoverage(['Nc3', 'Nf3']);
      final plan = await c.finish();
      // 3.Nf3 keeps the QGD family → a build point in the QGD chapter, not a
      // chapter of its own; every chapter's points are its set-up lines.
      final qgd = plan.chapters.firstWhere(
        (ch) => ch.family == "Queen's Gambit Declined",
      );
      expect(
        qgd.points.map((pt) => pt.moves.join(' ')),
        contains('d4 d5 c4 e6 Nf3'),
      );
      expect(plan.chapters.every((ch) => ch.points.isNotEmpty), isTrue);
    });
  });

  test(
    'a capture-vs-retreat split is a fork even when the book is thin',
    () async {
      // After 1.d4 d5 2.c4 e6 3.Nc3 Nf6 4.Bg5 Be7 5.e3 O-O 6.Nf3 h6 the book
      // has one continuation, but the database has both 7.Bh4 and 7.Bxf6.
      final path = [
        'd4',
        'd5',
        'c4',
        'e6',
        'Nc3',
        'Nf6',
        'Bg5',
        'Be7',
        'e3',
        'O-O',
        'Nf3',
        'h6',
      ];
      final source = _FakeSource(trie, {
        ...shares,
        path.join(' '): {'Bh4': 0.55, 'Bxf6': 0.40, 'Bf4': 0.05},
      });
      final c = PlanController(
        source: source,
        isWhite: false,
        tabiyaThreshold: 6,
        chapterShare: 0.08,
        minShare: 0.05,
        maxPly: 30,
      );
      await c.start(path);
      expect(c.step, isNotNull);
      expect(c.step!.kind, PlanStepKind.theirMove);
      expect(c.step!.preselected, {'Bh4', 'Bxf6'});
    },
  );

  test(
    'an on-demand engine run fills a blank eval with its provenance',
    () async {
      final c = PlanController(
        source: _FakeSource(trie, shares),
        isWhite: false,
        tabiyaThreshold: 6,
      )..engineFillLimit = 0; // no background fill: this tests the click path
      await c.start(['d4', 'd5', 'c4']);
      final san = c.step!.candidates.first.san;
      expect(c.step!.candidates.first.evalCp, isNull);
      await c.evaluateCandidate(san);
      final after = c.step!.candidates.firstWhere((x) => x.san == san);
      expect(after.evalCp, 15);
      expect(after.evalDepth, 12);
      expect(after.evalSource, 'Stockfish');
      expect(c.evaluating, isEmpty);
    },
  );

  test('blank evals are filled by the engine in the background', () async {
    final c = PlanController(
      source: _FakeSource(trie, shares),
      isWhite: false,
      tabiyaThreshold: 6,
    );
    await c.start(['d4', 'd5', 'c4']);
    // The fake engine answers immediately; give the fill loop a few turns.
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(c.step!.candidates.every((x) => x.evalCp != null), isTrue);
    expect(c.step!.candidates.first.evalSource, 'Stockfish');
  });

  test(
    '"keep setting up" turns off prompts for that line until generate',
    () async {
      final c = PlanController(
        source: _FakeSource(trie, shares),
        isWhite: false,
        tabiyaThreshold: 6,
      )..engineFillLimit = 0;
      await c.start(['d4', 'd5', 'c4', 'e6', 'Nc3']);
      expect(c.step!.kind, PlanStepKind.confirmLeaf);
      await c.continueSetup();
      expect(c.step!.kind, PlanStepKind.ourMove);
      expect(c.isManual(c.step!.moves), isTrue);
      await c.choose(['Nf6']);
      expect(c.step!.kind, isNot(PlanStepKind.confirmLeaf));
      expect(c.isManual(c.step!.moves), isTrue);
      await c.stopHere();
      expect(
        c.isManual(['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'Bg5']),
        isFalse,
      );
      expect(
        c.chapters.expand((ch) => ch.buildPaths).map((p) => p.join(' ')),
        contains('d4 d5 c4 e6 Nc3 Nf6'),
      );
    },
  );

  test(
    'a transposition into a set-up position is offered, not asked twice',
    () async {
      final c = PlanController(
        source: _FakeSource(trie, shares),
        isWhite: false,
        tabiyaThreshold: 6,
      )..engineFillLimit = 0;
      await c.start(['d4', 'd5', 'c4', 'e6']);
      await c.acceptCoverage(['Nc3', 'Nf3']);
      // Line A: 3.Nc3 Nf6 4.Nf3 — set up by hand, then generate from there.
      expect(c.step!.kind, PlanStepKind.confirmLeaf);
      await c.continueSetup();
      await c.choose(['Nf6']);
      expect(c.step!.kind, PlanStepKind.theirMove);
      await c.acceptCoverage(['Nf3']);
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'Nf3']);
      await c.stopHere();
      // Line B: 3.Nf3 Nf6 4.Nc3 — the same position by another order.
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6', 'Nf3']);
      await c.continueSetup();
      await c.choose(['Nf6']);
      c.addCandidate('Nc3');
      await c.acceptCoverage(['Nc3']);
      expect(c.step!.kind, PlanStepKind.transposition);
      expect(c.step!.transposesTo, [
        'd4',
        'd5',
        'c4',
        'e6',
        'Nc3',
        'Nf6',
        'Nf3',
      ]);
      final before = c.chapters.fold<int>(0, (n, ch) => n + ch.points.length);
      await c.skipTransposition();
      // Nothing cut for the duplicate; the walk moved on.
      expect(c.chapters.fold<int>(0, (n, ch) => n + ch.points.length), before);
      expect(c.decisions.last, contains('transposes to'));
    },
  );

  test(
    'finish() mid-question cuts the open step and pending branches',
    () async {
      final c = PlanController(
        source: _FakeSource(trie, shares),
        isWhite: false,
        tabiyaThreshold: 6,
      )..engineFillLimit = 0;
      await c.start(['d4', 'd5', 'c4']);
      expect(c.step!.kind, PlanStepKind.ourMove);
      final plan = await c.finish();
      expect(c.phase, PlanPhase.review);
      expect(plan.chapters, isNotEmpty);
      expect(plan.chapters.first.points.single.moves, ['d4', 'd5', 'c4']);
    },
  );
}
