import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/games_repertoire/repertoire_diff.dart';
import 'package:chess_auto_prep/services/games_repertoire/games_draft.dart';
import 'package:chess_auto_prep/services/games_repertoire/repertoire_merge.dart';
import 'package:chess_auto_prep/services/games_repertoire/draft_repertoire_writer.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';

/// Walk an [OpeningTree] to the node reached by [sans].
OpeningTreeNode? nodeFor(OpeningTree tree, List<String> sans) {
  var node = tree.root;
  for (final san in sans) {
    final next = node.children[san];
    if (next == null) return null;
    node = next;
  }
  return node;
}

void main() {
  group('RepertoireDiff', () {
    test('empty repertoire => everything is a deviation or beyond-book', () {
      final tree = OpeningTree()
        ..appendLine(['e4', 'e5', 'Nf3'])
        ..appendLine(['d4']);
      final diff = RepertoireDiff.compute(
        tree: tree,
        repertoire: MoveTree(),
        isWhite: true,
      );

      // First moves (mine) are deviations; replies past them are beyond-book.
      expect(diff[nodeFor(tree, ['e4'])!]!.status, DraftMoveStatus.myDeviation);
      expect(diff[nodeFor(tree, ['d4'])!]!.status, DraftMoveStatus.myDeviation);
      expect(diff[nodeFor(tree, ['e4', 'e5'])!]!.status,
          DraftMoveStatus.beyondBook);
      expect(diff.inRepertoireCount, 0);
    });

    test('classifies covered / my-deviation / opponent-deviation', () {
      final tree = OpeningTree()
        ..appendLine(['e4', 'e5', 'Nf3']) // all in book
        ..appendLine(['e4', 'c5']) // opponent off-book (Black)
        ..appendLine(['d4']); // my off-book (White)
      final rep = MoveTree.fromMoves(['e4', 'e5', 'Nf3', 'Nc6']);

      final diff =
          RepertoireDiff.compute(tree: tree, repertoire: rep, isWhite: true);

      expect(diff[nodeFor(tree, ['e4'])!]!.status,
          DraftMoveStatus.inRepertoire);
      expect(diff[nodeFor(tree, ['e4', 'e5'])!]!.status,
          DraftMoveStatus.inRepertoire);
      expect(diff[nodeFor(tree, ['e4', 'e5', 'Nf3'])!]!.status,
          DraftMoveStatus.inRepertoire);
      expect(diff[nodeFor(tree, ['e4', 'c5'])!]!.status,
          DraftMoveStatus.opponentDeviation);
      expect(diff[nodeFor(tree, ['d4'])!]!.status, DraftMoveStatus.myDeviation);
    });

    test('side awareness flips for a Black repertoire', () {
      final tree = OpeningTree()..appendLine(['e4', 'c5', 'Nf3', 'd6']);
      // Black repertoire after 1.e4: covers ...c5.
      final rep = MoveTree.fromMoves(['e4', 'c5']);
      final diff =
          RepertoireDiff.compute(tree: tree, repertoire: rep, isWhite: false);

      // e4 (White, opponent) covered; c5 (mine) covered.
      expect(diff[nodeFor(tree, ['e4'])!]!.isMyMove, isFalse);
      expect(diff[nodeFor(tree, ['e4', 'c5'])!]!.isMyMove, isTrue);
      // Nf3 = opponent off-book (parent covered, White move).
      expect(diff[nodeFor(tree, ['e4', 'c5', 'Nf3'])!]!.status,
          DraftMoveStatus.opponentDeviation);
    });
  });

  group('GamesDraft', () {
    test('prune removes a whole subtree', () {
      final tree = OpeningTree()
        ..appendLine(['e4', 'e5'])
        ..appendLine(['e4', 'c5', 'Nf3']);
      final draft = GamesDraft(tree: tree, isWhite: true);

      final c5 = nodeFor(tree, ['e4', 'c5'])!;
      expect(draft.prune(c5), isTrue);
      expect(nodeFor(tree, ['e4', 'c5']), isNull);
      expect(nodeFor(tree, ['e4', 'e5']), isNotNull); // sibling survives
    });

    test('materialize honours minGames and maxDepth', () {
      final tree = OpeningTree();
      // e4 e5 played twice; e4 d5 once.
      tree.appendLine(['e4', 'e5']);
      tree.appendLine(['e4', 'e5', 'Nf3']);
      tree.appendLine(['e4', 'd5']);
      final draft = GamesDraft(tree: tree, isWhite: true);

      final filtered = draft.materialize(
          filters: const DraftFilters(minGames: 2, maxDepth: 10));
      // d5 (1 game) dropped; e4/e5 (>=2) kept.
      final sans = filtered.roots.first.children.map((n) => n.san).toList();
      expect(filtered.roots.first.san, 'e4');
      expect(sans, contains('e5'));
      expect(sans, isNot(contains('d5')));

      final shallow =
          draft.materialize(filters: const DraftFilters(maxDepth: 1));
      // Only the first ply survives.
      expect(shallow.roots.first.children, isEmpty);
    });
  });

  group('restrictTreeToLine', () {
    test('keeps only the branch through the moves, prefix included', () {
      final tree = OpeningTree()
        ..appendLine(['e4', 'c5', 'Nf3', 'd6'])
        ..appendLine(['e4', 'c5', 'Nc3'])
        ..appendLine(['e4', 'e5', 'Nf3'])
        ..appendLine(['d4', 'd5']);

      expect(restrictTreeToLine(tree, ['e4', 'c5', 'Nf3']), isNull);

      // Full line through the position survives, subtree intact.
      expect(nodeFor(tree, ['e4', 'c5', 'Nf3', 'd6']), isNotNull);
      // Siblings at every level along the path are gone.
      expect(nodeFor(tree, ['d4']), isNull);
      expect(nodeFor(tree, ['e4', 'e5']), isNull);
      expect(nodeFor(tree, ['e4', 'c5', 'Nc3']), isNull);
    });

    test('empty move list is a no-op', () {
      final tree = OpeningTree()
        ..appendLine(['e4'])
        ..appendLine(['d4']);
      expect(restrictTreeToLine(tree, []), isNull);
      expect(nodeFor(tree, ['e4']), isNotNull);
      expect(nodeFor(tree, ['d4']), isNotNull);
    });

    test('reports when no game reaches the position', () {
      final tree = OpeningTree()..appendLine(['e4', 'e5']);
      final error = restrictTreeToLine(tree, ['e4', 'c5']);
      expect(error, isNotNull);
      expect(error, contains('e4 c5'));
    });

    test('matches SANs that differ only in check/mate suffixes', () {
      final tree = OpeningTree()..appendLine(['e4', 'e5', 'Qh5', 'Nc6']);
      // Caller position stored the queen check with a suffix.
      expect(restrictTreeToLine(tree, ['e4', 'e5', 'Qh5+']), isNull);
      expect(nodeFor(tree, ['e4', 'e5', 'Qh5', 'Nc6']), isNotNull);
    });
  });

  group('RepertoireMerge', () {
    test('union adds new opponent alternatives without conflict', () {
      final target = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final draft = MoveTree.fromMoves(['e4', 'c5']); // new Black reply

      final result = RepertoireMerge.merge(
          target: target, draft: draft, isWhite: true);

      expect(result.addedMoves, 1); // c5
      expect(result.hasConflicts, isFalse);
      // e4 now has two children: e5 and c5.
      expect(target.roots.first.children.map((n) => n.san),
          containsAll(['e5', 'c5']));
    });

    test('flags a conflict at my decision point', () {
      final target = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final draft = MoveTree.fromMoves(['e4', 'e5', 'Bc4']); // I play Bc4 instead

      final result = RepertoireMerge.merge(
          target: target, draft: draft, isWhite: true);

      expect(result.hasConflicts, isTrue);
      expect(result.conflicts.single.draftSan, 'Bc4');
      expect(result.conflicts.single.existingSans, ['Nf3']);
    });

    test('identical line merges with no additions and no conflicts', () {
      final target = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final draft = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);

      final result = RepertoireMerge.merge(
          target: target, draft: draft, isWhite: true);

      expect(result.addedMoves, 0);
      expect(result.hasConflicts, isFalse);
    });
  });

  group('draftToRepertoireFile', () {
    test('enumerates one line per leaf', () {
      // e4 then two replies (e5, c5); e5 continues to Nf3.
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      tree.addMove(const TreePath([0]), 'c5'); // second reply to e4
      final lines = enumerateLines(tree).map((l) => l.join(' ')).toList();
      expect(lines, hasLength(2));
      expect(lines, containsAll(['e4 e5 Nf3', 'e4 c5']));
    });

    test('round-trips through RepertoireService.parseRepertoirePgn', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3', 'Nc6']);
      tree.addMove(const TreePath([0]), 'c5');

      final content = draftToRepertoireFile(tree,
          name: 'Draft hikaru', isWhite: true);

      final parsed =
          RepertoireService().parseRepertoirePgn(content);
      expect(parsed, hasLength(2));
      expect(parsed.every((l) => l.color == 'white'), isTrue);
      final mainline =
          parsed.firstWhere((l) => l.moves.length == 4).moves;
      expect(mainline, ['e4', 'e5', 'Nf3', 'Nc6']);
    });
  });
}
