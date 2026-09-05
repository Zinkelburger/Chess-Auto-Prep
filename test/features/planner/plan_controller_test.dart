import 'package:chess_auto_prep/features/planner/controllers/plan_controller.dart';
import 'package:chess_auto_prep/features/planner/models/plan_models.dart';
import 'package:chess_auto_prep/features/planner/services/eco_trie.dart';
import 'package:chess_auto_prep/features/planner/services/plan_data_source.dart';
import 'package:chess_auto_prep/features/planner/services/plan_knowledge.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:dartchess/dartchess.dart';
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
      // Only the ticked replies exist; nothing has been built yet, so no
      // chapter shows (they appear as lines get their generate points).
      expect(c.chapters, isEmpty);

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
        final plan = await c.finish();
        final families = plan.chapters.map((ch) => ch.family).toList();
        // The QGD root chapter, plus the Catalan (10% ≥ chapterMass and
        // another family). 3.Nc3 and 3.Nf3 stay QGD → no chapters of their
        // own; cxd5 was not ticked, so nothing is built for it.
        expect(families, ["Queen's Gambit Declined", 'Catalan']);
        final builds = plan.chapters
            .expand((ch) => ch.buildPaths)
            .map((p) => p.join(' '))
            .toSet();
        expect(builds, isNot(contains('d4 d5 c4 e6 cxd5')));
        expect(builds, isNot(contains('d4 d5 c4 e6')));
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

  test('chapters opened for families passed through are not shown', () async {
    // Every our-move fork with a family change opens a chapter eagerly, but
    // only chapters that received a build point are chapters.
    final c = PlanController(
      source: _FakeSource(trie, shares),
      isWhite: false,
      tabiyaThreshold: 6,
    )..engineFillLimit = 0;
    await c.start(['d4', 'd5', 'c4']);
    await c.choose(['e6']); // Queen's Gambit → Queen's Gambit Declined
    expect(c.chapters, isEmpty); // nothing built yet — nothing to show
    await c.acceptCoverage(['Nc3']);
    await c.confirmLeaf();
    final plan = await c.finish();
    expect(plan.chapters.map((ch) => ch.family), ["Queen's Gambit Declined"]);
  });

  group('PlanController · my games', () {
    /// A small corpus of the user's games as Black ("me"), by line count:
    /// 6× QGD, 3× Slav, 1× QGA, 1× 2…Nc6 (a move no source lists), 2× London.
    String game(List<String> sans) {
      // Games are split on their [Event] tag, so every game needs one.
      final b = StringBuffer(
        '[Event "?"]\n[White "opp"]\n[Black "me"]\n[Result "*"]\n\n',
      );
      for (var i = 0; i < sans.length; i++) {
        if (i.isEven) b.write('${i ~/ 2 + 1}. ');
        b.write('${sans[i]} ');
      }
      return '$b*\n\n';
    }

    final corpus = StringBuffer();
    for (var i = 0; i < 6; i++) {
      corpus.write(game(['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6']));
    }
    for (var i = 0; i < 3; i++) {
      corpus.write(game(['d4', 'd5', 'c4', 'c6', 'Nf3', 'Nf6']));
    }
    corpus.write(game(['d4', 'd5', 'c4', 'dxc4', 'Nf3']));
    corpus.write(game(['d4', 'd5', 'c4', 'Nc6']));
    for (var i = 0; i < 2; i++) {
      corpus.write(game(['d4', 'd5', 'Bf4', 'Nf6']));
    }
    // A game as White must not count towards a Black repertoire.
    corpus.write(
      '[Event "?"]\n[White "me"]\n[Black "opp"]\n[Result "*"]\n\n'
      '1. e4 e5 2. Nf3 *\n\n',
    );

    final counted = PlanKnowledge.countOwnGamesSync(
      corpus.toString(),
      heroNames: 'me',
      isWhite: false,
    );
    final knowledge = PlanKnowledge(
      ownMoves: counted.moves,
      ownReplies: counted.replies,
    );

    PlanController make() => PlanController(
      source: _FakeSource(trie, shares),
      isWhite: false,
      knowledge: knowledge,
      basis: PlanBasis.ownGames,
      tabiyaThreshold: 6,
      chapterShare: 0.08,
      minShare: 0.05,
    );

    test('counts only the games played as the repertoire colour', () {
      expect(counted.games, 13);
      final afterD4d5 = playSanOrNullMove(
        playSanOrNullMove(Chess.initial, 'd4')!,
        'd5',
      )!.fen;
      expect(knowledge.ownCountsAt(afterD4d5), {'c4': 11, 'Bf4': 2});
      expect(knowledge.ownGamesAt(afterD4d5), 13);
    });

    test(
      'asks at every position your games reached, thin ones excepted',
      () async {
        final c = make();
        await c.start(['d4', 'd5']);
        // 13 games at the root → a question needs max(3, 8% of 13) = 3.
        expect(c.ownFloor, 3);

        // 1.d4 d5: opponents played c4 (11) and Bf4 (2). Only c4 clears the
        // floor, so only it comes ticked — the book's tabiya score is not
        // consulted at all when walking your games.
        expect(c.step!.kind, PlanStepKind.theirMove);
        expect(c.step!.ownGames, 13);
        expect(c.step!.preselected, {'c4'});
        expect(c.step!.candidates.first.san, 'c4');
        expect(c.step!.candidates.first.ownGames, 13);

        await c.acceptCoverage(['c4']);
        // Reach follows your games, not Maia: 11 of 13 met 2.c4.
        expect(c.reachOf(['d4', 'd5', 'c4']), closeTo(11 / 13, 1e-9));

        // 1.d4 d5 2.c4: your move; what you played comes first, most often
        // on top, and the one you played most is the default answer. 2…Nc6,
        // which no source lists, still gets a row because you played it.
        final ours = c.step!;
        expect(ours.kind, PlanStepKind.ourMove);
        expect(ours.ownGames, 11);
        expect(ours.candidates.take(4).map((x) => x.san), [
          'e6',
          'c6',
          'dxc4',
          'Nc6',
        ]);
        expect(ours.candidates.map((x) => x.san), contains('Nf6'));
        expect(ours.preselected, {'e6'});

        // Take the Slav: 3 games, right on the floor → still a question at
        // White's move (3.Nf3 ticked), and again at yours (…Nf6).
        await c.choose(['c6']);
        expect(c.step!.moves, ['d4', 'd5', 'c4', 'c6']);
        expect(c.step!.kind, PlanStepKind.theirMove);
        expect(c.step!.preselected, {'Nf3'});
        await c.acceptCoverage(['Nf3']);
        expect(c.step!.kind, PlanStepKind.ourMove);
        expect(c.step!.preselected, {'Nf6'});
        await c.choose(['Nf6']);

        // Your games end here: the walk stops, but asks first.
        final leaf = c.step!;
        expect(leaf.kind, PlanStepKind.confirmLeaf);
        expect(leaf.moves, ['d4', 'd5', 'c4', 'c6', 'Nf3', 'Nf6']);
        expect(leaf.ownGames, 0);
        await c.confirmLeaf();

        final plan = await c.finish();
        final builds = plan.chapters
            .expand((ch) => ch.buildPaths)
            .map((p) => p.join(' '))
            .toSet();
        expect(builds, contains('d4 d5 c4 c6 Nf3 Nf6'));
        // Nothing was ticked for 2.Bf4, so nothing is built for it.
        expect(builds.where((b) => b.contains('Bf4')), isEmpty);
      },
    );

    test(
      'a chapter that already answers a position still decides it',
      () async {
        final c = make()
          ..knowledge = knowledge.copyWith(
            chapterMoves: PlanKnowledge.countOurMovesInLines([
              ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6'],
            ], isWhite: false),
          );
        await c.start(['d4', 'd5', 'c4']);
        // …e6 is settled by the chapter; the next question is White's reply.
        expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6']);
        expect(c.step!.kind, PlanStepKind.theirMove);
        expect(c.decisions.first, contains('already in your chapters'));
      },
    );

    test('the book walk is unchanged by the games being present', () async {
      final c = PlanController(
        source: _FakeSource(trie, shares),
        isWhite: false,
        knowledge: knowledge,
        tabiyaThreshold: 6,
        chapterShare: 0.08,
        minShare: 0.05,
      );
      await c.start(['d4', 'd5']);
      // Book basis: Maia's shares decide the ticks (c4 and Bf4 ≥ 8%), and
      // your games only fill the "You" column.
      expect(c.step!.preselected, containsAll(['c4', 'Bf4']));
      expect(c.step!.candidates.firstWhere((x) => x.san == 'Bf4').ownGames, 13);
    });
  });
}
