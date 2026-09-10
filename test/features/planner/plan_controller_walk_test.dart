import 'dart:async';

import 'package:chess_auto_prep/features/planner/controllers/plan_controller.dart';
import 'package:chess_auto_prep/features/planner/models/plan_models.dart';
import 'package:chess_auto_prep/features/planner/models/plan_starting_line.dart';
import 'package:chess_auto_prep/features/planner/services/eco_trie.dart';
import 'package:chess_auto_prep/features/planner/services/plan_data_source.dart';
import 'package:chess_auto_prep/features/planner/services/plan_knowledge.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// Walk-state tests for [PlanController]: undo exactness, colour, answer
/// reuse across move orders, the own-games basis, chapter naming and the
/// async guards. The happy-path walk is covered in plan_controller_test.dart.
///
/// Book: 1.d4 d5 2.c4 forks four ways for Black (…e6, …c6, …dxc4, …Nf6); two
/// of those (…e6 and …Nf6) land in the same "Queen's Gambit Declined" family
/// so chapter names collide; 3.Nc3 Nf6 is a White fork; everything else is
/// thin so leaf confirmations appear early.
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
D10	Slav Defense	1. d4 d5 2. c4 c6
D11	Slav: 3.Nf3	1. d4 d5 2. c4 c6 3. Nf3
D15	Slav: 3.Nc3	1. d4 d5 2. c4 c6 3. Nc3
D20	Queen's Gambit Accepted	1. d4 d5 2. c4 dxc4
D06	Queen's Gambit Declined: Marshall Defense	1. d4 d5 2. c4 Nf6
D02	London System	1. d4 d5 2. Bf4
D02	London: 2...Nf6	1. d4 d5 2. Bf4 Nf6
''';

const _shares = <String, Map<String, double>>{
  'd4 d5': {'c4': 0.80, 'Bf4': 0.15, 'Nf3': 0.05},
  'd4 d5 c4': {'e6': 0.40, 'c6': 0.30, 'dxc4': 0.15, 'Nf6': 0.05},
  'd4 d5 c4 e6': {'Nc3': 0.50, 'Nf3': 0.35, 'g3': 0.10, 'cxd5': 0.05},
  'd4 d5 c4 e6 Nc3 Nf6': {'Bg5': 0.50, 'Nf3': 0.30, 'cxd5': 0.20},
};

/// Book-only source with scripted shares; [candidateGate] / [engineGate]
/// hold the corresponding answer until a test completes them.
class _Source implements PlanDataSource {
  _Source(this.trie, this.shares);
  final EcoTrie trie;
  final Map<String, Map<String, double>> shares;
  Completer<void>? candidateGate;
  Completer<void>? engineGate;

  @override
  Future<List<PlanCandidate>> candidates({
    required String fen,
    required List<String> moves,
    required bool ourMove,
    required int elo,
  }) async {
    if (candidateGate != null) await candidateGate!.future;
    final node = trie.nodeAt(moves);
    final here = shares[moves.join(' ')] ?? const {};
    final sans = {...?node?.children.keys, ...here.keys};
    return [
      for (final san in sans)
        PlanCandidate(
          san: san,
          name: node?.children[san]?.nearestName?.name,
          dbShare: here[san],
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
  Future<({int cp, int depth})?> engineEval(String fen) async {
    if (engineGate != null) await engineGate!.future;
    return (cp: 15, depth: 12);
  }

  @override
  Future<({int cp, int depth, String source})?> dbEval(String fen) async =>
      null;
}

String _fenAfter(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    pos = playSanOrNullMove(pos, san)!;
  }
  return pos.fen;
}

void main() {
  final trie = EcoTrie.build([_tsv]);

  PlanController make({
    bool isWhite = false,
    PlanKnowledge knowledge = PlanKnowledge.empty,
    PlanBasis basis = PlanBasis.book,
    _Source? source,
  }) => PlanController(
    source: source ?? _Source(trie, _shares),
    isWhite: isWhite,
    knowledge: knowledge,
    basis: basis,
    tabiyaThreshold: 6,
    chapterShare: 0.08,
    minShare: 0.05,
  )..engineFillLimit = 0;

  Set<String> buildPaths(RepertoirePlan plan) => plan.chapters
      .expand((ch) => ch.buildPaths)
      .map((p) => p.join(' '))
      .toSet();

  group('multiple starting systems', () {
    final roots = PlanStartingLine.parse(
      'Main KID | 1.d4 Nf6 2.c4 g6 3.Nc3 Bg7 4.e4 d6\nFianchetto KID | 1.d4 Nf6 2.c4 g6 3.Nf3 Bg7 4.g3 d6\nLondon | 1.d4 Nf6 2.Bf4 d5',
    );

    test(
      'direct plan keeps all named roots and their complete move paths',
      () async {
        final controller = make();
        addTearDown(controller.dispose);
        await controller.startMany(roots, askQuestions: false);
        final result = await controller.finish();
        expect(result.chapters.map((c) => c.name), roots.map((r) => r.name));
        expect(buildPaths(result), roots.map((r) => r.moves.join(' ')).toSet());
        expect(controller.phase, PlanPhase.review);
        expect(controller.canGoBack, isFalse);
      },
    );

    test(
      'quiz visits every root and Back restores the preceding root',
      () async {
        final controller = make();
        addTearDown(controller.dispose);
        await controller.startMany(roots);
        expect(controller.step!.moves, roots.first.moves);
        await controller.stopHere();
        expect(controller.step!.moves, roots[1].moves);
        await controller.back();
        expect(controller.step!.moves, roots.first.moves);
        expect(controller.chapters, isEmpty);
        await controller.stopHere();
        await controller.stopHere();
        expect(controller.step!.moves, roots[2].moves);
        await controller.stopHere();
        expect(
          buildPaths(await controller.finish()),
          roots.map((r) => r.moves.join(' ')).toSet(),
        );
      },
    );

    test(
      'own-games thresholds follow each root rather than the largest sample',
      () async {
        final controller = make(
          basis: PlanBasis.ownGames,
          knowledge: PlanKnowledge(
            ownReplies: {
              normalizeFen(_fenAfter(roots[0].moves)): {'Nf3': 1000},
              normalizeFen(_fenAfter(roots[1].moves)): {'Bg2': 10},
            },
          ),
        );
        addTearDown(controller.dispose);
        await controller.startMany(roots.take(2).toList());
        expect(controller.ownFloor, 80);
        await controller.stopHere();
        expect(controller.step!.moves, roots[1].moves);
        expect(controller.ownFloor, 3);
        expect(controller.step!.kind, PlanStepKind.theirMove);
      },
    );

    test('Finish now includes every unvisited root', () async {
      final controller = make();
      addTearDown(controller.dispose);
      await controller.startMany(roots);
      expect(
        buildPaths(await controller.finish()),
        roots.map((r) => r.moves.join(' ')).toSet(),
      );
    });
  });

  group('back() is exact', () {
    test(
      'after confirming a leaf, back reopens the leaf confirmation',
      () async {
        final c = make();
        await c.start(['d4', 'd5', 'c4', 'e6', 'Nc3']);
        expect(c.step!.kind, PlanStepKind.confirmLeaf);
        await c.confirmLeaf();
        expect(c.phase, PlanPhase.review);

        await c.back();
        expect(c.phase, PlanPhase.walking);
        expect(c.step, isNotNull);
        expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6', 'Nc3']);
        // The user was looking at "generate from here, or keep setting up?" —
        // not at a move question.
        expect(c.step!.kind, PlanStepKind.confirmLeaf);
        expect(c.chapters, isEmpty);
      },
    );

    test('back past "keep setting up" ends the manual stretch again', () async {
      final c = make();
      await c.start(['d4', 'd5', 'c4', 'e6', 'Nc3']);
      await c.continueSetup();
      expect(c.step!.kind, PlanStepKind.ourMove);
      await c.choose(['Nf6']);
      expect(c.step!.kind, PlanStepKind.theirMove);
      expect(c.decisions, ['move 3: you play Nf6']);

      await c.back(); // undo the …Nf6 choice
      expect(c.step!.kind, PlanStepKind.ourMove);
      expect(c.decisions, isEmpty);
      await c.back(); // undo "keep setting up"
      expect(c.step!.kind, PlanStepKind.confirmLeaf);
      expect(c.isManual(['d4', 'd5', 'c4', 'e6', 'Nc3']), isFalse);

      await c.confirmLeaf();
      final plan = await c.finish();
      expect(buildPaths(plan), {'d4 d5 c4 e6 Nc3'});
      expect(c.decisions, ['move 3: generate from here']);
    });

    test('back drops exactly the decisions the undone answer made', () async {
      final knowledge = PlanKnowledge(
        chapterMoves: PlanKnowledge.countOurMovesInLines([
          ['d4', 'd5', 'c4', 'e6'],
        ], isWhite: false),
      );
      final c = make(knowledge: knowledge);
      await c.start(['d4', 'd5', 'c4']);
      // …e6 was decided silently (no answer to undo), then a question.
      expect(c.decisions, ['move 2: e6 (already in your chapters)']);
      expect(c.step!.kind, PlanStepKind.theirMove);
      await c.acceptCoverage(['Nc3']);
      expect(c.step!.kind, PlanStepKind.confirmLeaf);
      // "Keep setting up" records no decision of its own…
      await c.continueSetup();
      expect(c.decisions, [
        'move 2: e6 (already in your chapters)',
        'move 3: set up Nc3',
      ]);
      // …so undoing it must not eat the coverage decision before it.
      await c.back();
      expect(c.decisions, [
        'move 2: e6 (already in your chapters)',
        'move 3: set up Nc3',
      ]);
      await c.back();
      expect(c.decisions, ['move 2: e6 (already in your chapters)']);
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6']);
      expect(c.step!.kind, PlanStepKind.theirMove);
    });

    test('a position visited only on an undone branch is not "seen"', () async {
      final c = make();
      await c.start(['d4', 'd5', 'c4', 'e6']);
      await c.acceptCoverage(['Nc3', 'Nf3']);
      await c.continueSetup(); // 3.Nc3: set up by hand
      await c.choose(['Nf6']);
      expect(c.step!.kind, PlanStepKind.theirMove);
      await c.acceptCoverage(['Nf3']);
      // The walk reached 3.Nc3 Nf6 4.Nf3 and is asking there…
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'Nf3']);
      // …but the user changes their mind: 4.Bg5 instead of 4.Nf3.
      await c.back();
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6']);
      await c.acceptCoverage(['Bg5']);
      await c.stopHere();

      // Line B: 3.Nf3 Nf6 4.Nc3 reaches the position of the *undone* 4.Nf3.
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6', 'Nf3']);
      await c.continueSetup();
      await c.choose(['Nf6']);
      c.addCandidate('Nc3');
      await c.acceptCoverage(['Nc3']);
      // Nothing in the plan covers it, so it must be an ordinary question,
      // not a transposition into a line that no longer exists.
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6', 'Nf3', 'Nf6', 'Nc3']);
      expect(c.step!.kind, PlanStepKind.ourMove);
      expect(c.step!.transposesTo, isNull);
    });

    test('back from a transposition card reopens that card', () async {
      final c = make();
      await c.start(['d4', 'd5', 'c4', 'e6']);
      await c.acceptCoverage(['Nc3', 'Nf3']);
      await c.continueSetup();
      await c.choose(['Nf6']);
      await c.acceptCoverage(['Nf3']);
      await c.stopHere();
      await c.continueSetup();
      await c.choose(['Nf6']);
      c.addCandidate('Nc3');
      await c.acceptCoverage(['Nc3']);
      expect(c.step!.kind, PlanStepKind.transposition);
      final target = c.step!.transposesTo;
      await c.skipTransposition();
      expect(c.phase, PlanPhase.review);

      await c.back();
      expect(c.step!.kind, PlanStepKind.transposition);
      expect(c.step!.transposesTo, target);
      // Refusing it now asks at this position as its own line.
      await c.setUpSeparately();
      expect(c.step!.kind, PlanStepKind.ourMove);
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6', 'Nf3', 'Nf6', 'Nc3']);
    });
  });

  group('transpositions', () {
    test(
      'an our-move fork reached by another order reuses the answer',
      () async {
        final c = make();
        await c.start(['d4', 'd5', 'c4', 'e6']);
        await c.acceptCoverage(['Nc3', 'Nf3']);
        await c.continueSetup();
        await c.choose(['Nf6']);
        await c.acceptCoverage(['Nf3']);
        // Line A answers 4.Nf3 with …Be7 and generates from there.
        await c.choose(['Be7']);
        expect(c.step!.kind, PlanStepKind.theirMove);
        await c.acceptCoverage([]);
        final a = ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'Nf3', 'Be7'];
        expect(
          c.chapters.expand((ch) => ch.buildPaths).map((p) => p.join(' ')),
          [a.join(' ')],
        );

        // Line B: 3.Nf3 Nf6 4.Nc3 is the same position as 3.Nc3 Nf6 4.Nf3.
        await c.continueSetup();
        await c.choose(['Nf6']);
        c.addCandidate('Nc3');
        await c.acceptCoverage(['Nc3']);
        // …Be7 is replayed without asking, and the position after it is then
        // offered as a transposition into line A's build point.
        expect(
          c.decisions.last,
          allOf(contains('same position as'), contains('Be7 again')),
        );
        expect(c.step!.kind, PlanStepKind.transposition);
        expect(c.step!.moves, [
          'd4',
          'd5',
          'c4',
          'e6',
          'Nf3',
          'Nf6',
          'Nc3',
          'Be7',
        ]);
        expect(c.step!.transposesTo, a);
        await c.skipTransposition();
        final plan = await c.finish();
        expect(buildPaths(plan), {a.join(' ')});
      },
    );
  });

  group('colour', () {
    test(
      'as White the start position is our move; as Black it is theirs',
      () async {
        final w = make(isWhite: true);
        await w.start([]);
        expect(w.step!.moves, isEmpty);
        expect(w.step!.kind, PlanStepKind.ourMove);
        expect(w.step!.candidates.map((x) => x.san), contains('d4'));
        await w.choose(['d4']);
        expect(w.decisions, ['move 1: you play d4']);
        expect(w.step!.moves, ['d4']);
        expect(w.step!.kind, PlanStepKind.theirMove);
        await w.acceptCoverage(['d5']);
        expect(w.step!.moves, ['d4', 'd5']);
        expect(w.step!.kind, PlanStepKind.ourMove);
        expect(
          w.step!.candidates.map((x) => x.san),
          containsAll(['c4', 'Bf4']),
        );

        final b = make();
        await b.start([]);
        expect(b.step!.kind, PlanStepKind.theirMove);
        // Ticking nothing at the root makes the root itself the build point.
        await b.acceptCoverage([]);
        final plan = await b.finish();
        expect(plan.chapters.single.points.single.moves, isEmpty);
        expect(plan.isWhite, isFalse);
      },
    );
  });

  group('chapters', () {
    test('two chapters of one family are told apart by their move', () async {
      final c = make();
      await c.start(['d4', 'd5', 'c4']);
      // …e6 and …Nf6 both land in the Queen's Gambit Declined family.
      await c.choose(['e6', 'Nf6']);
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6']);
      await c.acceptCoverage([]);
      expect(c.step!.moves, ['d4', 'd5', 'c4', 'Nf6']);
      expect(c.step!.kind, PlanStepKind.confirmLeaf);
      await c.confirmLeaf();
      expect(c.phase, PlanPhase.review);

      final plan = await c.finish();
      final names = plan.chapters.map((ch) => ch.name).toList();
      expect(names, hasLength(2));
      expect(names.toSet(), hasLength(2));
      expect(
        names.every((n) => n.startsWith("Queen's Gambit Declined")),
        isTrue,
      );
      expect(names.where((n) => n.contains('e6')), hasLength(1));
      expect(names.where((n) => n.contains('Nf6')), hasLength(1));
      // Every chapter has its own build point; the root chapter (nothing
      // built there) is not in the plan.
      expect(plan.chapters.every((ch) => ch.points.length == 1), isTrue);
    });

    test(
      'finish() mid-walk cuts the open step and every frontier path',
      () async {
        final c = make();
        await c.start(['d4', 'd5', 'c4']);
        await c.choose(['e6', 'c6']);
        expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6']);
        expect(c.openBranches, 2);
        final plan = await c.finish();
        expect(buildPaths(plan), {'d4 d5 c4 e6', 'd4 d5 c4 c6'});
        expect(plan.chapters.map((ch) => ch.family).toSet(), {
          "Queen's Gambit Declined",
          'Slav Defense',
        });
        expect(
          plan.chapters
              .expand((ch) => ch.points)
              .map((pt) => pt.reason)
              .toSet(),
          {'left to the engine from here'},
        );
        expect(c.openBranches, 0);
      },
    );
  });

  group('own games', () {
    test('a tie between two of your moves keeps the source order', () async {
      final afterD4d5 = normalizeFen(_fenAfter(['d4', 'd5']));
      final afterC4 = normalizeFen(_fenAfter(['d4', 'd5', 'c4']));
      final knowledge = PlanKnowledge(
        ownReplies: {
          afterD4d5: {'c4': 6},
        },
        ownMoves: {
          afterC4: {'c6': 3, 'e6': 3},
        },
      );
      final c = make(knowledge: knowledge, basis: PlanBasis.ownGames);
      await c.start(['d4', 'd5']);
      expect(c.ownFloor, 3);
      expect(c.step!.preselected, {'c4'});
      await c.acceptCoverage(['c4']);
      // Every game went 2.c4, so the reach is your games' share, not Maia's.
      expect(c.reachOf(['d4', 'd5', 'c4']), 1.0);
      final ours = c.step!;
      expect(ours.kind, PlanStepKind.ourMove);
      expect(ours.candidates.take(2).map((x) => x.san), ['e6', 'c6']);
      expect(ours.preselected, {'e6'});
      // Where the games stop, the walk stops — asking first.
      await c.choose(['c6']);
      expect(c.step!.kind, PlanStepKind.confirmLeaf);
      expect(c.step!.ownGames, 0);
    });

    test('the question floor scales with the games at the root', () async {
      final afterD4d5 = normalizeFen(_fenAfter(['d4', 'd5']));
      final knowledge = PlanKnowledge(
        ownReplies: {
          afterD4d5: {'c4': 90, 'Bf4': 7, 'Nf3': 3},
        },
      );
      final c = make(knowledge: knowledge, basis: PlanBasis.ownGames);
      await c.start(['d4', 'd5']);
      expect(c.ownFloor, 8); // 8% of 100
      expect(c.step!.ownGames, 100);
      // 2.Bf4 is a 15% Maia reply but only 7 of your games: not ticked.
      expect(c.step!.preselected, {'c4'});
      expect(
        c.step!.candidates.firstWhere((x) => x.san == 'Bf4').ownShare,
        closeTo(0.07, 1e-9),
      );
    });

    test('as White your own moves are the questions, theirs the replies', () async {
      String game(String moves) =>
          '[Event "?"]\n[White "Me"]\n[Black "opp"]\n[Result "*"]\n\n$moves *\n\n';
      // The last game is the same line with colours swapped: it must not count.
      final corpus = [
        game('1. e4 c5 2. Nf3'),
        game('1. e4 c5 2. Nf3'),
        game('1. e4 c5 2. Nf3'),
        game('1. e4 e5 2. Nf3'),
        '[Event "?"]\n[White "opp"]\n[Black "Me"]\n[Result "*"]\n\n1. e4 c5 2. Nf3 *\n\n',
      ].join();
      final counted = PlanKnowledge.countOwnGamesSync(
        corpus,
        heroNames: 'me',
        isWhite: true,
      );
      expect(counted.games, 4);
      final knowledge = PlanKnowledge(
        ownMoves: counted.moves,
        ownReplies: counted.replies,
      );
      final c = make(
        isWhite: true,
        knowledge: knowledge,
        basis: PlanBasis.ownGames,
      );
      await c.start(['e4']);
      expect(c.step!.kind, PlanStepKind.theirMove);
      expect(c.step!.ownGames, 4);
      expect(c.step!.preselected, {'c5'});
      await c.acceptCoverage(['c5']);
      expect(c.reachOf(['e4', 'c5']), closeTo(0.75, 1e-9));
      final ours = c.step!;
      expect(ours.kind, PlanStepKind.ourMove);
      expect(ours.candidates.first.san, 'Nf3');
      expect(ours.candidates.first.ownGames, 3);
      expect(ours.preselected, {'Nf3'});
    });
  });

  group('async guards', () {
    test(
      'an engine result for a question already answered is dropped',
      () async {
        final source = _Source(trie, _shares)..engineGate = Completer<void>();
        final c = make(source: source);
        await c.start(['d4', 'd5', 'c4']);
        final pending = c.evaluateCandidate('e6');
        expect(c.evaluating, {'e6'});
        await c.choose(['e6']);
        expect(c.step!.moves, ['d4', 'd5', 'c4', 'e6']);
        source.engineGate!.complete();
        await pending;
        expect(c.evaluating, isEmpty);
        expect(c.step!.candidates.every((x) => x.evalCp == null), isTrue);
      },
    );

    test(
      'reset() while a question is loading discards its candidates',
      () async {
        final source = _Source(trie, _shares)
          ..candidateGate = Completer<void>();
        final c = make(source: source);
        final starting = c.start(['d4', 'd5', 'c4']);
        await Future<void>.delayed(Duration.zero);
        expect(c.step, isNotNull);
        expect(c.step!.loading, isTrue);
        c.reset();
        source.candidateGate!.complete();
        await starting;
        expect(c.step, isNull);
        expect(c.phase, PlanPhase.start);
      },
    );

    test('dispose() while a question is loading does not throw', () async {
      final source = _Source(trie, _shares)..candidateGate = Completer<void>();
      final c = make(source: source);
      var notified = 0;
      c.addListener(() => notified++);
      final starting = c.start(['d4', 'd5', 'c4']);
      await Future<void>.delayed(Duration.zero);
      final before = notified;
      c.dispose();
      source.candidateGate!.complete();
      await starting;
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(notified, before);
    });
  });
}
