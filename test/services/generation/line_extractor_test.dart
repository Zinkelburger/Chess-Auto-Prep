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
      final continuation = makeNode(
        fen: kFenAfterE4E5Nf3,
        san: 'Nf3',
        uci: 'g1f3',
        ply: 3,
        isWhiteToMove: false,
        evalCp: -30,
        parent: canonical,
      )..isRepertoireMove = true;

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

    test('exportPgn produces valid PGN text', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4c5nf3.isRepertoireMove = true;

      final extractor = LineExtractor(config: _config());
      final lines = extractor.extract(t.toTree());
      final pgn = extractor.exportPgn(lines, repertoireName: 'Test');

      expect(pgn, contains('[Event'));
      expect(pgn, contains('1. e4'));
      expect(pgn, contains('*'));
    });
  });
}
