import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

TreeBuildConfig _config({bool playAsWhite = true}) => TreeBuildConfig(
  startFen: _startFen,
  playAsWhite: playAsWhite,
  minProbability: 0.01,
);

void main() {
  group('LineExtractor', () {
    test('extracts lines when isRepertoireMove flags are set', () {
      final t = StandardTree();
      // Mark e4 and its continuations as repertoire moves
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4c5nf3.isRepertoireMove = true;

      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());

      expect(lines, isNotEmpty);
      // Two opponent branches (e5, c5) -> two lines
      expect(lines.length, 2);
    });

    test('follows isRepertoireMove at our-move nodes', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4c5nf3.isRepertoireMove = true;

      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());

      // Every line should start with e4 (our repertoire pick)
      for (final line in lines) {
        expect(line.movesSan.first, 'e4');
      }
      // No line should contain d4 (not a repertoire move)
      for (final line in lines) {
        expect(line.movesSan, isNot(contains('d4')));
      }
    });

    test('branches at opponent-move nodes', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4c5nf3.isRepertoireMove = true;

      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());

      final secondMoves = lines.map((l) => l.movesSan[1]).toSet();
      expect(secondMoves, containsAll(['e5', 'c5']));
    });

    test('skips opponent children below minProbability', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4c5nf3.isRepertoireMove = true;
      t.e4c5.cumulativeProbability = 0.001; // below default 0.01
      t.e4c5.moveProbability = 0.001; // below the coverage floor too

      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());

      // Only the e5 branch should remain
      expect(lines.length, 1);
      expect(lines.single.movesSan[1], 'e5');
    });

    test('keeps coverage-floored children below minProbability', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4c5nf3.isRepertoireMove = true;
      // Deep-but-rare line: reach probability below the floor, yet the
      // move itself is popular locally — the coverage floor guarantees it
      // an answer, so its line must be exported.
      t.e4c5.cumulativeProbability = 0.001;
      t.e4c5.moveProbability = 0.35;

      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());

      expect(lines.length, 2);
      expect(lines.map((l) => l.movesSan[1]).toSet(), {'e5', 'c5'});
    });

    test('produces 0 lines when no repertoire marks exist', () {
      final t = StandardTree();
      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());

      expect(lines, isEmpty);
    });

    test('resolves transposition leaves via FenMap', () {
      resetNodeIds();
      final root = makeNode(
        fen: _startFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
        evalCp: 30,
      );
      final e4 = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        uci: 'e2e4',
        ply: 1,
        isWhiteToMove: false,
        evalCp: -25,
        parent: root,
      )..isRepertoireMove = true;

      // Transposition leaf (childless, same FEN as canonical below)
      final transLeaf = makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        uci: 'e7e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 35,
        moveProbability: 0.6,
        cumulativeProbability: 0.6,
        parent: e4,
      );

      // Canonical node with children (lives elsewhere in the tree)
      final canonical = makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        uci: 'e7e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 35,
        nodeId: 999,
      );
      // Attaches itself as a child of `canonical` via `parent:`.
      makeNode(
        fen: kFenAfterE4E5Nf3,
        san: 'Nf3',
        uci: 'g1f3',
        ply: 3,
        isWhiteToMove: false,
        evalCp: -30,
        parent: canonical,
      ).isRepertoireMove = true;

      final fenMap = FenMap();
      fenMap.putCanonical(canonical.fen, canonical);
      fenMap.addTransposition(transLeaf.fen, transLeaf);

      final extractor = LineExtractor(config: _config(), fenMap: fenMap);
      final lines = extractor.extract(BuildTree(root: root));

      expect(lines, isNotEmpty);
      // Line should traverse through the transposition to the canonical's child
      final sanLists = lines.map((l) => l.movesSan).toList();
      expect(sanLists.any((sans) => sans.contains('Nf3')), isTrue);
    });

    test('terminates on a transposition cycle (no infinite recursion)', () {
      // Build a loop: root -> e4 (canonical, has children) -> e5 ->
      // a childless leaf whose FEN transposes back to e4. Without a cycle
      // guard this recurses forever. (docs/REFACTOR_PLAN.md §1.3)
      resetNodeIds();
      final root = makeNode(
        fen: _startFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
        evalCp: 30,
      );
      final e4 = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        uci: 'e2e4',
        ply: 1,
        isWhiteToMove: false,
        evalCp: -25,
        parent: root,
      )..isRepertoireMove = true;
      final e4e5 = makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        uci: 'e7e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 35,
        moveProbability: 0.6,
        cumulativeProbability: 0.6,
        parent: e4,
      );
      // Our move from e4e5 that loops back to the e4 position (childless leaf).
      final loopLeaf = makeNode(
        fen: kFenAfterE4,
        san: 'Ng1f3-loop',
        uci: 'g1f3',
        ply: 3,
        isWhiteToMove: false,
        evalCp: -20,
        parent: e4e5,
      )..isRepertoireMove = true;

      final fenMap = FenMap();
      fenMap.putCanonical(e4.fen, e4);
      fenMap.putCanonical(e4e5.fen, e4e5);
      fenMap.addTransposition(loopLeaf.fen, loopLeaf);

      final extractor = LineExtractor(config: _config(), fenMap: fenMap);
      final lines = extractor.extract(BuildTree(root: root), maxLines: 50);

      // Must terminate and stay well under maxLines.
      expect(lines, isNotEmpty);
      expect(lines.length, lessThan(50));
    });

    test('line probability reflects cumulative probability at leaf', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;

      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());

      for (final line in lines) {
        expect(line.probability, greaterThan(0.0));
      }
    });

    test('works for black repertoire', () {
      final t = BlackRepertoireTree();
      // Mark e5 as our repertoire choice (we are black)
      t.e4e5.isRepertoireMove = true;

      final extractor = LineExtractor(config: _config(playAsWhite: false));
      final lines = extractor.extract(t.toTree());

      expect(lines, isNotEmpty);
      // Lines should start with e4 (opponent), then e5 (our pick)
      for (final line in lines) {
        expect(line.movesSan.first, 'e4');
        expect(line.movesSan[1], 'e5');
      }
    });

    test('coverage units carry our-move projection keys and values', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4c5nf3.isRepertoireMove = true;
      // Model real cumP propagation (our moves inherit the parent's cumP).
      t.e4e5nf3.cumulativeProbability = 0.55;
      t.e4c5nf3.cumulativeProbability = 0.35;

      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());

      expect(lines.length, 2);
      final e5Line = lines.firstWhere((l) => l.movesSan[1] == 'e5');
      final c5Line = lines.firstWhere((l) => l.movesSan[1] == 'c5');

      // Keys are the decision itself: the position faced, then the move.
      // Both lines open with the same root decision, so that key is shared.
      expect(e5Line.coverageUnits.first.key, endsWith('|e2e4'));
      expect(c5Line.coverageUnits.first.key, e5Line.coverageUnits.first.key);

      // Their second decisions are *not* shared. Playing Nf3 after 1...e5 and
      // playing Nf3 after 1...c5 are two things to know, because they are two
      // positions; only the SAN coincides. The old projection key called them
      // one, which is why the c5 line used to be prunable away and the
      // repertoire could end up never answering 1...c5 at all.
      expect(e5Line.coverageUnits[1].key, isNot(c5Line.coverageUnits[1].key));
      expect(e5Line.coverageUnits[1].key, endsWith('|g1f3'));
      expect(c5Line.coverageUnits[1].key, endsWith('|g1f3'));

      // e4 at the root: d4 sibling evals better for us (30 vs 25), so the
      // gap clamps to 0 and the value is the bare reach probability 1.0.
      expect(e5Line.coverageUnits[0].value, closeTo(1.0, 1e-9));
      // Nf3 has no evaluated sibling: gap defaults to maxEvalLossCp (50),
      // weight 1.5, scaled by the node's reach probability.
      expect(e5Line.coverageUnits[1].value, closeTo(0.55 * 1.5, 1e-9));
      expect(c5Line.coverageUnits[1].value, closeTo(0.35 * 1.5, 1e-9));
    });

    test('coverage value grows with the eval gap to the best sibling', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4e5nf3.cumulativeProbability = 0.55;
      // Evaluated alternative 20cp worse than Nf3 (30 vs 10 for us).
      makeNode(
        fen: 'rnbqkbnr/pppp1ppp/8/4p2Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2',
        san: 'Qh5',
        uci: 'd1h5',
        ply: 3,
        isWhiteToMove: false,
        evalCp: -10,
        parent: t.e4e5,
      );

      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());

      final e5Line = lines.firstWhere((l) => l.movesSan[1] == 'e5');
      expect(e5Line.coverageUnits[1].value, closeTo(0.55 * 1.2, 1e-9));
    });

    test('annotates our moves with eval and naturalness', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4.myEase = 0.82;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4c5nf3.isRepertoireMove = true;

      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());

      final first = lines.first.moveAnnotations.first;
      expect(first.myEase, closeTo(0.82, 1e-9));
      expect(first.evalCp, isNotNull);
      expect(first.likelihood, isNull, reason: 'we choose our own moves');
    });

    group('difficulty annotations', () {
      StandardTree marked() {
        final t = StandardTree();
        t.e4.isRepertoireMove = true;
        t.e4e5nf3.isRepertoireMove = true;
        t.e4c5nf3.isRepertoireMove = true;
        return t;
      }

      ExtractedLine e5LineOf(StandardTree t, {TreeBuildConfig? config}) =>
          LineExtractor(
            config: config ?? _config(),
          ).extract(t.toTree()).firstWhere((l) => l.movesSan[1] == 'e5');

      void addQh5(StandardTree t, {required int evalCp}) => makeNode(
        fen: 'rnbqkbnr/pppp1ppp/8/4p2Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2',
        san: 'Qh5',
        uci: 'd1h5',
        ply: 3,
        isWhiteToMove: false,
        evalCp: evalCp,
        parent: t.e4e5,
      );

      test('a move with no stored alternative is not called forced', () {
        // A sole child usually means the search never widened here, not
        // that every alternative loses — so no claim is made.
        final nf3 = e5LineOf(marked()).moveAnnotations[2];

        expect(nf3.isOnlyMove, isFalse);
        expect(nf3.glyph, isNull);
      });

      test('an alternative losing most of the window makes it forced', () {
        final t = marked();
        addQh5(t, evalCp: 12); // -12 for us, 42cp behind Nf3 in a 50cp window

        final nf3 = e5LineOf(t).moveAnnotations[2];
        expect(nf3.isOnlyMove, isTrue);
        expect(nf3.onlyMoveLeadCp, 42);
        expect(nf3.glyph, '!');
      });

      test('a playable alternative cancels it', () {
        final t = marked();
        addQh5(t, evalCp: -10); // +10 for us, 20cp behind Nf3

        expect(e5LineOf(t).moveAnnotations[2].isOnlyMove, isFalse);
      });

      test('the bar caps at 100cp however wide the window', () {
        final t = marked();
        addQh5(t, evalCp: 80); // -80 for us, 110cp behind Nf3
        const config = TreeBuildConfig(
          startFen: _startFen,
          playAsWhite: true,
          minProbability: 0.01,
          maxEvalLossCp: 300,
        );

        final nf3 = e5LineOf(t, config: config).moveAnnotations[2];
        expect(nf3.isOnlyMove, isTrue);
        expect(nf3.onlyMoveLeadCp, 110);
      });

      test('names the natural move humans prefer to ours', () {
        final t = marked();
        t.e4.maiaFrequency = 0.05;
        t.d4.maiaFrequency = 0.60;

        final e4 = e5LineOf(t).moveAnnotations[0];
        expect(e4.humanFrequency, closeTo(0.05, 1e-9));
        expect(e4.naturalAlternativeSan, 'd4');
        // d4 is +30 for us against e4's +25: the natural move costs nothing.
        expect(e4.naturalAlternativeLossCp, -5);
        expect(e4.explanation, contains('the natural d4 is nearly as good'));
      });

      test('a popular move gets no hard-to-find warning', () {
        final t = marked();
        t.e4.maiaFrequency = 0.45;
        t.d4.maiaFrequency = 0.50;

        final e4 = e5LineOf(t).moveAnnotations[0];
        expect(e4.isHardToFind, isFalse);
        expect(e4.naturalAlternativeSan, isNull);
      });

      test('grades an opponent reply against best play for them', () {
        final t = marked();
        // After 1.e4 the position is +25 for us; ...c5 leaves it +200.
        t.e4c5.engineEvalCp = 200;

        final lines = LineExtractor(config: _config()).extract(t.toTree());
        final c5 = lines
            .firstWhere((l) => l.movesSan[1] == 'c5')
            .moveAnnotations[1];
        expect(c5.mistakeCp, 175);
        expect(c5.betterMoveSan, 'e5', reason: '...e5 (+35) holds the bar');
        expect(c5.glyph, '?');

        final e5 = e5LineOf(t).moveAnnotations[1];
        expect(e5.mistakeCp, isNull, reason: '+35 against +25 is no mistake');
      });

      test('names no better move when every stored reply is bad', () {
        final t = marked();
        t.e4c5.engineEvalCp = 200;
        t.e4e5.engineEvalCp = 150;

        final lines = LineExtractor(config: _config()).extract(t.toTree());
        final c5 = lines
            .firstWhere((l) => l.movesSan[1] == 'c5')
            .moveAnnotations[1];
        expect(c5.mistakeCp, 175);
        expect(c5.betterMoveSan, isNull);
      });

      test('flags the last move seen in master games', () {
        final t = marked();
        t.e4.totalGames = 100;
        t.e4e5.totalGames = 40;

        final line = e5LineOf(t);
        expect(line.moveAnnotations[0].lastBookMove, isFalse);
        expect(line.moveAnnotations[1].lastBookMove, isTrue);
        expect(line.moveAnnotations[2].lastBookMove, isFalse);
      });

      test('a line still in book at its leaf has no boundary', () {
        final t = marked();
        t.e4.totalGames = 100;
        t.e4e5.totalGames = 40;
        t.e4e5nf3.totalGames = 30;

        expect(e5LineOf(t).moveAnnotations.any((a) => a.lastBookMove), isFalse);
      });
    });

    group('choice points', () {
      // The alternatives pass asks "what else would a human play here?", so
      // what it needs is the *position* and what the tree already knows about
      // it — not the branch the line happened to take.
      test('record every position the line passes through', () {
        final t = StandardTree();
        t.e4.isRepertoireMove = true;
        t.e4e5nf3.isRepertoireMove = true;
        t.e4c5nf3.isRepertoireMove = true;

        final lines = LineExtractor(config: _config()).extract(t.toTree());
        final line = lines.first;

        expect(line.choices, hasLength(line.movesSan.length));
        expect(line.choices.map((c) => c.moveIndex), [0, 1, 2]);
        expect(line.choices.first.fenBefore, _startFen);
        expect(line.choices.map((c) => c.isOurMove), [true, false, true]);
      });

      test('carry the moves the tree already holds at that position', () {
        final t = StandardTree();
        t.e4.isRepertoireMove = true;
        t.e4e5nf3.isRepertoireMove = true;
        t.e4c5nf3.isRepertoireMove = true;

        final lines = LineExtractor(config: _config()).extract(t.toTree());

        // Both of our root candidates, not just the one that was selected —
        // an engine-approved alternative needs no refutation either.
        expect(lines.first.choices.first.knownUcis, ['e2e4', 'd2d4']);
      });

      test('our best is the highest eval for us, theirs the lowest', () {
        final t = StandardTree();
        t.e4.isRepertoireMove = true;
        t.e4e5nf3.isRepertoireMove = true;
        t.e4c5nf3.isRepertoireMove = true;

        final lines = LineExtractor(config: _config()).extract(t.toTree());
        final line = lines.firstWhere((l) => l.movesSan[1] == 'e5');

        // Our move: e4 (+25 for us) beats d4 (+30 for us)? No — d4 is better
        // by this tree's numbers, and the site records what is *available*.
        expect(line.choices[0].bestEvalCpForUs, 30);
        // Their move: e5 leaves us +35, c5 leaves us +45, so their best try
        // is e5 — the bar an alternative has to fall below.
        expect(line.choices[1].bestEvalCpForUs, 35);
      });

      test('an unevaluated position offers nothing to compare against', () {
        final t = StandardTree();
        t.e4.isRepertoireMove = true;
        t.e4e5nf3.isRepertoireMove = true;
        t.e4c5nf3.isRepertoireMove = true;
        t.e4.engineEvalCp = null;
        t.d4.engineEvalCp = null;

        final lines = LineExtractor(config: _config()).extract(t.toTree());

        expect(lines.first.choices.first.bestEvalCpForUs, isNull);
      });
    });
  });
}
