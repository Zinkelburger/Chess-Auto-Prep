/// Extraction-time transposition merging.
///
/// The build keeps one expanded subtree per position; every other arrival is
/// a childless leaf that resolves to it.  These tests pin down what the
/// extractor does with that: the continuation is emitted once, under the
/// most probable move order, and every other move order stops at the shared
/// position with a note naming the owner.
library;

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/export/move_annotation.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/line_pruner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// Positions are identified by name; only the first four FEN fields matter
/// to the transposition table, and the move counters are deliberately
/// different on the two arrivals to prove they are ignored.
String _fen(String name, {required bool whiteToMove, int counter = 0}) =>
    '$name ${whiteToMove ? 'w' : 'b'} KQkq - 0 $counter';

TreeBuildConfig _config() => const TreeBuildConfig(
  startFen: _start,
  playAsWhite: true,
  minProbability: 0.01,
  coverMinProb: 0.0,
);

/// Two move orders into the same our-turn position P (after 1.Nf3 d5 2.d4
/// Nf6 / 1.Nf3 Nf6 2.d4 d5), which continues 3.c4 and then branches.
///
///   root ─ Nf3 ─┬─ d5 (p=pD5) ─ d4 ─ Nf6 (p=pNf6After) ─ [P canonical]
///               │                                           └ c4 ─┬ e6 ─ Nc3
///               │                                                 └ c6 ─ Nc3
///               └─ Nf6 (p=pNf6) ─ d4 ─ d5 (p=pD5After) ─ [P' leaf]
class _TranspositionTree {
  late final BuildTreeNode root;
  late final BuildTreeNode pCanonical;
  late final BuildTreeNode pLeaf;
  late final FenMap fenMap;

  _TranspositionTree({
    double pD5 = 0.6,
    double pNf6After = 0.7,
    double pNf6 = 0.4,
    double pD5After = 0.9,
  }) {
    resetNodeIds();
    root = makeNode(fen: _start, san: '', ply: 0, isWhiteToMove: true);
    final nf3 = makeNode(
      fen: _fen('nf3', whiteToMove: false),
      san: 'Nf3',
      uci: 'g1f3',
      ply: 1,
      isWhiteToMove: false,
      evalCp: -20,
      parent: root,
    )..isRepertoireMove = true;

    // Branch A: 1...d5 2.d4 Nf6
    final d5 = makeNode(
      fen: _fen('nf3d5', whiteToMove: true),
      san: 'd5',
      uci: 'd7d5',
      ply: 2,
      isWhiteToMove: true,
      evalCp: 20,
      moveProbability: pD5,
      cumulativeProbability: pD5,
      parent: nf3,
    );
    final d4a = makeNode(
      fen: _fen('nf3d5d4', whiteToMove: false),
      san: 'd4',
      uci: 'd2d4',
      ply: 3,
      isWhiteToMove: false,
      evalCp: -20,
      cumulativeProbability: pD5,
      parent: d5,
    )..isRepertoireMove = true;
    final reachA = pD5 * pNf6After;
    final reachB = pNf6 * pD5After;
    final pReach = reachA > reachB ? reachA : reachB;
    pCanonical = makeNode(
      fen: _fen('P', whiteToMove: true, counter: 3),
      san: 'Nf6',
      uci: 'g8f6',
      ply: 4,
      isWhiteToMove: true,
      evalCp: 20,
      moveProbability: pNf6After,
      // The build propagates the highest arrival's cumP into the canonical.
      cumulativeProbability: pReach,
      parent: d4a,
    );
    final c4 = makeNode(
      fen: _fen('Pc4', whiteToMove: false),
      san: 'c4',
      uci: 'c2c4',
      ply: 5,
      isWhiteToMove: false,
      evalCp: -25,
      cumulativeProbability: pReach,
      parent: pCanonical,
    )..isRepertoireMove = true;
    for (final (san, uci, p) in [('e6', 'e7e6', 0.5), ('c6', 'c7c6', 0.4)]) {
      final reply = makeNode(
        fen: _fen('Pc4$san', whiteToMove: true),
        san: san,
        uci: uci,
        ply: 6,
        isWhiteToMove: true,
        evalCp: 25,
        moveProbability: p,
        cumulativeProbability: pReach * p,
        parent: c4,
      );
      makeNode(
        fen: _fen('Pc4${san}Nc3', whiteToMove: false),
        san: 'Nc3',
        uci: 'b1c3',
        ply: 7,
        isWhiteToMove: false,
        evalCp: -25,
        cumulativeProbability: pReach * p,
        parent: reply,
      ).isRepertoireMove = true;
    }

    // Branch B: 1...Nf6 2.d4 d5 — transposes into P.
    final nf6 = makeNode(
      fen: _fen('nf3nf6', whiteToMove: true),
      san: 'Nf6',
      uci: 'g8f6',
      ply: 2,
      isWhiteToMove: true,
      evalCp: 20,
      moveProbability: pNf6,
      cumulativeProbability: pNf6,
      parent: nf3,
    );
    final d4b = makeNode(
      fen: _fen('nf3nf6d4', whiteToMove: false),
      san: 'd4',
      uci: 'd2d4',
      ply: 3,
      isWhiteToMove: false,
      evalCp: -20,
      cumulativeProbability: pNf6,
      parent: nf6,
    )..isRepertoireMove = true;
    pLeaf = makeNode(
      fen: _fen('P', whiteToMove: true, counter: 9),
      san: 'd5',
      uci: 'd7d5',
      ply: 4,
      isWhiteToMove: true,
      evalCp: 20,
      moveProbability: pD5After,
      cumulativeProbability: reachB,
      parent: d4b,
    );

    fenMap = FenMap()..populate(root);
  }

  List<ExtractedLine> extract() => LineExtractor(
    config: _config(),
    fenMap: fenMap,
  ).extract(BuildTree(root: root));
}

String _san(ExtractedLine l) => l.movesSan.join(' ');

void main() {
  group('LineExtractor transposition merge', () {
    test('the build resolves both arrivals to one canonical node', () {
      final t = _TranspositionTree();
      expect(t.fenMap.getCanonical(t.pLeaf.fen), same(t.pCanonical));
      expect(t.fenMap.getTranspositions(t.pLeaf.fen), [t.pLeaf]);
    });

    test('the continuation is emitted once, under the likelier order', () {
      final t = _TranspositionTree(); // A reaches P with 0.42, B with 0.36
      final lines = t.extract();
      final sans = lines.map(_san).toList();

      expect(sans, [
        'Nf3 d5 d4 Nf6 c4 e6 Nc3',
        'Nf3 d5 d4 Nf6 c4 c6 Nc3',
        'Nf3 Nf6 d4 d5 c4',
      ]);
      // Before the merge the extractor re-walked P's subtree for branch B
      // and produced five lines, two of them the same continuation again.
      expect(lines.where((l) => l.movesSan.contains('e6')).length, 1);
    });

    test('the cut line ends on our reply, not the opponent\'s move', () {
      final t = _TranspositionTree();
      final cut = t.extract().singleWhere((l) => l.isTransposition);
      // P is our turn: the line still answers 2...d5 with 3.c4, so the
      // reader is never left to move with nothing to play.
      expect(cut.movesSan.last, 'c4');
      // The pointer names the owner's path to the position the line ends
      // in — after 3.c4 — so a reader following it lands on the same board.
      expect(cut.transposesInto, ['Nf3', 'd5', 'd4', 'Nf6', 'c4']);
      expect(
        cut.moveAnnotations.last.note,
        'Transposes to 1. Nf3 d5 2. d4 Nf6 3. c4.',
      );
      expect(cut.moveAnnotations.last.transposesTo, cut.transposesInto);
      final comment = cut.moveAnnotations.last.toPgnComment(
        MoveAnnotationDetail.full,
      );
      expect(comment, startsWith('Transposes to 1. Nf3 d5 2. d4 Nf6 3. c4.'));
      expect(comment, contains('[%transposes Nf3 d5 d4 Nf6 c4]'));
      // Earlier moves carry no such note.
      for (final a in cut.moveAnnotations.take(
        cut.moveAnnotations.length - 1,
      )) {
        expect(a.note, isNull);
      }
    });

    test('the cut line carries its own reach, not the subtree\'s', () {
      final t = _TranspositionTree();
      final cut = t.extract().singleWhere((l) => l.isTransposition);
      expect(cut.probability, closeTo(0.36, 1e-9));
    });

    test('a stub ending on the canonical node reports its own path, not the '
        'summed arrivals', () {
      // Branch B owns (0.4 x 0.9 = 0.36 against 0.4 x 0.7 = 0.28), so the
      // line that gets cut is branch A — and branch A ends on the *canonical*
      // node. The build sums every arrival into that node's reach, so reading
      // `cumulativeProbability` off it would credit the stub with branch B's
      // mass as well, inflating it in the pruner's coverage accounting and in
      // the exported percentage.
      final t = _TranspositionTree(
        pD5: 0.4,
        pNf6After: 0.7,
        pNf6: 0.4,
        pD5After: 0.9,
      );
      // What addArrivalCumP leaves behind: 0.28 + 0.36.
      t.pCanonical.cumulativeProbability = 0.64;

      final cut = t.extract().singleWhere((l) => l.isTransposition);
      expect(cut.movesSan, ['Nf3', 'd5', 'd4', 'Nf6', 'c4']);
      expect(cut.probability, closeTo(0.28, 1e-9));
    });

    test('ownership follows probability, not which node holds the subtree', () {
      // Now branch B (through the childless leaf) is the likelier way into
      // P: 0.4 × 0.9 = 0.36 against 0.4 × 0.7 = 0.28.
      final t = _TranspositionTree(pD5: 0.4, pNf6After: 0.7, pNf6: 0.4);
      final lines = t.extract();
      expect(lines.map(_san).toList(), [
        'Nf3 d5 d4 Nf6 c4',
        'Nf3 Nf6 d4 d5 c4 e6 Nc3',
        'Nf3 Nf6 d4 d5 c4 c6 Nc3',
      ]);
      final cut = lines.singleWhere((l) => l.isTransposition);
      expect(cut.transposesInto, ['Nf3', 'Nf6', 'd4', 'd5', 'c4']);
    });

    test('an exact tie goes to the earlier branch in tree order', () {
      final t = _TranspositionTree(
        pD5: 0.5,
        pNf6After: 0.8,
        pNf6: 0.5,
        pD5After: 0.8,
      );
      final lines = t.extract();
      expect(lines.first.movesSan, [
        'Nf3',
        'd5',
        'd4',
        'Nf6',
        'c4',
        'e6',
        'Nc3',
      ]);
      expect(lines.last.isTransposition, isTrue);
    });

    test('the pruner keeps both move orders and nothing is taught twice', () {
      final t = _TranspositionTree();
      final lines = t.extract();
      final kept = LinePruner.rank(lines).all;
      // 2.d4 after 1...d5 and 2.d4 after 1...Nf6 are different decisions, so
      // both move orders survive — but the continuation appears once.
      expect(kept.length, 3);
      final continuationLines = kept.where((l) => l.movesSan.length > 5);
      expect(continuationLines.length, 2); // e6 and c6 branches, once each
    });

    test('the shared decisions still share a coverage key', () {
      final t = _TranspositionTree();
      final lines = t.extract();
      final cut = lines.singleWhere((l) => l.isTransposition);
      final owner = lines.firstWhere((l) => !l.isTransposition);
      // 3.c4 at P is the same decision however P was reached.
      final c4Key = cut.coverageUnits.last.key;
      expect(owner.coverageUnits.map((u) => u.key), contains(c4Key));
      expect(c4Key, endsWith('|c2c4'));
      expect(c4Key, startsWith(canonicalizeFen(t.pCanonical.fen)));
    });

    test('merging when we move into the shared position', () {
      // 1.Nf3 d5 2.c4 Nf6 3.d4  and  1.Nf3 Nf6 2.d4 d5 3.c4 — our own move
      // completes the transposition, so the cut line ends on it as is.
      resetNodeIds();
      final root = makeNode(fen: _start, san: '', ply: 0, isWhiteToMove: true);
      final nf3 = makeNode(
        fen: _fen('nf3', whiteToMove: false),
        san: 'Nf3',
        uci: 'g1f3',
        ply: 1,
        isWhiteToMove: false,
        parent: root,
      )..isRepertoireMove = true;

      BuildTreeNode opp(
        BuildTreeNode parent,
        String san,
        String pos,
        double p,
      ) => makeNode(
        fen: _fen(pos, whiteToMove: true),
        san: san,
        ply: parent.ply + 1,
        isWhiteToMove: true,
        moveProbability: p,
        cumulativeProbability: parent.cumulativeProbability * p,
        parent: parent,
      );
      BuildTreeNode our(BuildTreeNode parent, String san, String pos) =>
          makeNode(
            fen: _fen(pos, whiteToMove: false),
            san: san,
            ply: parent.ply + 1,
            isWhiteToMove: false,
            cumulativeProbability: parent.cumulativeProbability,
            parent: parent,
          )..isRepertoireMove = true;

      // A: d5 c4 Nf6 d4 → R (canonical), then e6 Nc3.
      final d5 = opp(nf3, 'd5', 'd5', 0.6);
      final c4 = our(d5, 'c4', 'd5c4');
      final nf6a = opp(c4, 'Nf6', 'd5c4nf6', 0.7);
      final r = our(nf6a, 'd4', 'R');
      final e6 = opp(r, 'e6', 'Re6', 0.5);
      our(e6, 'Nc3', 'Re6nc3');
      // B: Nf6 d4 d5 c4 → R' (leaf).
      final nf6b = opp(nf3, 'Nf6', 'nf6', 0.4);
      final d4 = our(nf6b, 'd4', 'nf6d4');
      final d5b = opp(d4, 'd5', 'nf6d4d5', 0.9);
      final rLeaf = our(d5b, 'c4', 'R');

      final fenMap = FenMap()..populate(root);
      expect(fenMap.getCanonical(rLeaf.fen), same(r));

      final lines = LineExtractor(
        config: _config(),
        fenMap: fenMap,
      ).extract(BuildTree(root: root));
      expect(lines.map(_san).toList(), [
        'Nf3 d5 c4 Nf6 d4 e6 Nc3',
        'Nf3 Nf6 d4 d5 c4',
      ]);
      final cut = lines.last;
      expect(cut.transposesInto, ['Nf3', 'd5', 'c4', 'Nf6', 'd4']);
      expect(cut.probability, closeTo(0.36, 1e-9));
      expect(cut.leafFen, rLeaf.fen);
    });

    test('lines through positions reached one way are unchanged', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4c5nf3.isRepertoireMove = true;
      final lines = LineExtractor(
        config: _config(),
        fenMap: FenMap()..populate(t.root),
      ).extract(t.toTree());
      expect(lines.length, 2);
      expect(lines.every((l) => !l.isTransposition), isTrue);
      expect(
        lines.every((l) => l.moveAnnotations.every((a) => a.note == null)),
        isTrue,
      );
    });

    test('extract never leaves a pointer at a move order it did not emit', () {
      // The structural invariant the repair pass exists to hold: the owner
      // walk explores paths the extraction walk stops short of, so it can
      // hand a continuation to an arrival extraction cannot reach. Whatever
      // the tree shape, every pointer must name a line that is in the output.
      for (final t in [
        _TranspositionTree(),
        _TranspositionTree(pD5: 0.4, pNf6After: 0.7, pNf6: 0.4, pD5After: 0.9),
        _TranspositionTree(pD5: 0.5, pNf6After: 0.8, pNf6: 0.5, pD5After: 0.8),
        _TranspositionTree(pD5: 0.9, pNf6After: 0.9, pNf6: 0.05, pD5After: 0.1),
        _TranspositionTree(pD5: 0.05, pNf6After: 0.1, pNf6: 0.9, pD5After: 0.9),
      ]) {
        final lines = t.extract();
        final played = <String>{};
        for (final line in lines) {
          for (var i = 1; i <= line.movesSan.length; i++) {
            played.add(line.movesSan.take(i).join(' '));
          }
        }
        for (final line in lines) {
          final target = line.transposesInto;
          if (target == null || target.isEmpty) continue;
          expect(
            played,
            contains(target.join(' ')),
            reason:
                '"${line.movesSan.join(' ')}" points at "${target.join(' ')}", '
                'which no emitted line plays',
          );
        }
        // And the continuation is still taught exactly once.
        expect(lines.where((l) => l.movesSan.contains('e6')), hasLength(1));
      }
    });

    test('a pointer at a move order no line plays is withdrawn', () {
      final t = _TranspositionTree();
      final extractor = LineExtractor(config: _config(), fenMap: t.fenMap);
      final lines = extractor.extract(BuildTree(root: t.root));
      final cut = lines.singleWhere((l) => l.isTransposition);
      expect(cut.transposesInto, isNotNull);

      // Drop the owner, as a truncated greedy or a cycle-guard divergence
      // between the two traversals can.
      final orphaned = lines
          .where(
            (l) => !l.movesSan.contains('e6') && !l.movesSan.contains('c6'),
          )
          .toList();
      final repaired = extractor.withdrawDanglingTranspositions(orphaned);

      expect(extractor.danglingTranspositions, 1);
      final line = repaired.singleWhere((l) => l.movesSan.contains('Nf6'));
      expect(line.transposesInto, isNull);
      expect(line.moveAnnotations.last.transposesTo, isNull);
      expect(
        line.moveAnnotations.last.note,
        isNull,
        reason: 'the withdrawn claim must not be left in the prose',
      );
      // The moves themselves are untouched.
      expect(line.movesSan, cut.movesSan);
      expect(line.probability, cut.probability);
    });

    test('a pointer whose move order is present is left alone', () {
      final t = _TranspositionTree();
      final extractor = LineExtractor(config: _config(), fenMap: t.fenMap);
      final lines = extractor.extract(BuildTree(root: t.root));

      final repaired = extractor.withdrawDanglingTranspositions(lines);

      expect(extractor.danglingTranspositions, 0);
      expect(repaired.singleWhere((l) => l.isTransposition).transposesInto, [
        'Nf3',
        'd5',
        'd4',
        'Nf6',
        'c4',
      ]);
    });

    test('withdrawing keeps prose that was not the transposition note', () {
      const a = MoveAnnotation(note: 'Improves on 3.Nc3.');
      final withNote = a.withTransposition(const [
        'd4',
      ], 'Transposes to 1. d4.');
      expect(withNote.note, 'Improves on 3.Nc3. Transposes to 1. d4.');

      final undone = withNote.withoutTransposition('Transposes to 1. d4.');
      expect(undone.note, 'Improves on 3.Nc3.');
      expect(undone.transposesTo, isNull);
    });

    test(
      'a transposition note joins an existing note instead of replacing it',
      () {
        const a = MoveAnnotation(note: 'Improves on 3.Nc3.');
        expect(
          a.withNote('Transposes to 1. d4.').note,
          'Improves on 3.Nc3. Transposes to 1. d4.',
        );
        expect(const MoveAnnotation().withNote('x').note, 'x');
      },
    );
  });
}
