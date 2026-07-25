import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/games_repertoire/draft_merge_planner.dart';
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
      expect(
        diff[nodeFor(tree, ['e4', 'e5'])!]!.status,
        DraftMoveStatus.beyondBook,
      );
      expect(diff.inRepertoireCount, 0);
    });

    test('classifies covered / my-deviation / opponent-deviation', () {
      final tree = OpeningTree()
        ..appendLine(['e4', 'e5', 'Nf3']) // all in book
        ..appendLine(['e4', 'c5']) // opponent off-book (Black)
        ..appendLine(['d4']); // my off-book (White)
      final rep = MoveTree.fromMoves(['e4', 'e5', 'Nf3', 'Nc6']);

      final diff = RepertoireDiff.compute(
        tree: tree,
        repertoire: rep,
        isWhite: true,
      );

      expect(
        diff[nodeFor(tree, ['e4'])!]!.status,
        DraftMoveStatus.inRepertoire,
      );
      expect(
        diff[nodeFor(tree, ['e4', 'e5'])!]!.status,
        DraftMoveStatus.inRepertoire,
      );
      expect(
        diff[nodeFor(tree, ['e4', 'e5', 'Nf3'])!]!.status,
        DraftMoveStatus.inRepertoire,
      );
      expect(
        diff[nodeFor(tree, ['e4', 'c5'])!]!.status,
        DraftMoveStatus.opponentDeviation,
      );
      expect(diff[nodeFor(tree, ['d4'])!]!.status, DraftMoveStatus.myDeviation);
    });

    test('side awareness flips for a Black repertoire', () {
      final tree = OpeningTree()..appendLine(['e4', 'c5', 'Nf3', 'd6']);
      // Black repertoire after 1.e4: covers ...c5.
      final rep = MoveTree.fromMoves(['e4', 'c5']);
      final diff = RepertoireDiff.compute(
        tree: tree,
        repertoire: rep,
        isWhite: false,
      );

      // e4 (White, opponent) covered; c5 (mine) covered.
      expect(diff[nodeFor(tree, ['e4'])!]!.isMyMove, isFalse);
      expect(diff[nodeFor(tree, ['e4', 'c5'])!]!.isMyMove, isTrue);
      // Nf3 = opponent off-book (parent covered, White move).
      expect(
        diff[nodeFor(tree, ['e4', 'c5', 'Nf3'])!]!.status,
        DraftMoveStatus.opponentDeviation,
      );
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
        filters: const DraftFilters(minGames: 2, maxDepth: 10),
      );
      // d5 (1 game) dropped; e4/e5 (>=2) kept.
      final sans = filtered.roots.first.children.map((n) => n.san).toList();
      expect(filtered.roots.first.san, 'e4');
      expect(sans, contains('e5'));
      expect(sans, isNot(contains('d5')));

      final shallow = draft.materialize(
        filters: const DraftFilters(maxDepth: 1),
      );
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
        target: target,
        draft: draft,
        isWhite: true,
      );

      expect(result.addedMoves, 1); // c5
      expect(result.hasConflicts, isFalse);
      // e4 now has two children: e5 and c5.
      expect(
        target.roots.first.children.map((n) => n.san),
        containsAll(['e5', 'c5']),
      );
    });

    test('flags a conflict at my decision point', () {
      final target = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final draft = MoveTree.fromMoves([
        'e4',
        'e5',
        'Bc4',
      ]); // I play Bc4 instead

      final result = RepertoireMerge.merge(
        target: target,
        draft: draft,
        isWhite: true,
      );

      expect(result.hasConflicts, isTrue);
      expect(result.conflicts.single.draftSan, 'Bc4');
      expect(result.conflicts.single.existingSans, ['Nf3']);
    });

    test('identical line merges with no additions and no conflicts', () {
      final target = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final draft = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);

      final result = RepertoireMerge.merge(
        target: target,
        draft: draft,
        isWhite: true,
      );

      expect(result.addedMoves, 0);
      expect(result.hasConflicts, isFalse);
    });
  });

  group('planDraftMerge / applyConflictDecisions', () {
    test('fully covered draft plans nothing and mutates neither tree', () {
      final repertoire = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final draft = MoveTree.fromMoves(['e4', 'e5']);

      final plan = planDraftMerge(
        repertoire: repertoire,
        draft: draft,
        isWhite: true,
      );

      expect(plan.isEmpty, isTrue);
      expect(plan.hasConflicts, isFalse);
      // The repertoire passed in is untouched (planning must be side-effect
      // free — the caller may re-plan after changing the min-games filter).
      expect(
        repertoire.roots.single.children.single.children.single.san,
        'Nf3',
      );
    });

    test('opponent gap becomes a new line without conflict', () {
      final repertoire = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final draft = MoveTree.fromMoves(['e4', 'c5', 'Nc3']);

      final plan = planDraftMerge(
        repertoire: repertoire,
        draft: draft,
        isWhite: true,
      );

      expect(plan.newLines, [
        ['e4', 'c5', 'Nc3'],
      ]);
      expect(plan.hasConflicts, isFalse);
    });

    test('my divergence is flagged with SAN prefix and prep answers', () {
      final repertoire = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final draft = MoveTree.fromMoves(['e4', 'e5', 'Bc4', 'Nc6']);

      final plan = planDraftMerge(
        repertoire: repertoire,
        draft: draft,
        isWhite: true,
      );

      expect(plan.newLines, [
        ['e4', 'e5', 'Bc4', 'Nc6'],
      ]);
      final conflict = plan.conflicts.single;
      expect(conflict.prefixSans, ['e4', 'e5']);
      expect(conflict.draftSan, 'Bc4');
      expect(conflict.repertoireSans, ['Nf3']);
      // Planning must not graft the draft into the real repertoire tree.
      expect(repertoire.roots.single.children.single.children, hasLength(1));
    });

    test(
      'skipping a conflict drops every line through it, imports keep all',
      () {
        final repertoire = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
        // Two lines under the conflicting Bc4, plus one unrelated gap line.
        final draft = MoveTree.fromMoves(['e4', 'e5', 'Bc4', 'Nc6']);
        draft.addMove(const TreePath([0, 0, 0]), 'Nf6');
        draft.addMove(const TreePath([0]), 'c5');

        final plan = planDraftMerge(
          repertoire: repertoire,
          draft: draft,
          isWhite: true,
        );
        expect(plan.newLines, hasLength(3));
        expect(plan.conflicts, hasLength(1));

        final kept = applyConflictDecisions(plan, importAlternatives: {});
        expect(kept, [
          ['e4', 'c5'],
        ]);

        final all = applyConflictDecisions(plan, importAlternatives: {0});
        expect(all, hasLength(3));
      },
    );
  });

  group('gap-line marking', () {
    test('lineEndsWithMyMove is side-aware', () {
      // White repertoire: my line ends on my (White) move.
      expect(lineEndsWithMyMove(['e4'], isWhite: true), isTrue);
      expect(lineEndsWithMyMove(['e4', 'e5'], isWhite: true), isFalse);
      // Black repertoire: the same endings flip.
      expect(lineEndsWithMyMove(['e4'], isWhite: false), isFalse);
      expect(lineEndsWithMyMove(['e4', 'c5'], isWhite: false), isTrue);
      expect(lineEndsWithMyMove([], isWhite: true), isFalse);
    });

    test('lastMoveLabel numbers both sides correctly', () {
      expect(lastMoveLabel(['e4']), '1.e4');
      expect(lastMoveLabel(['e4', 'e5']), '1...e5');
      expect(lastMoveLabel(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6']), '3...a6');
    });

    test('gap lines get a needs-answer title and final-move comment', () {
      final content = draftLinesToPgnGames(
        [
          ['e4', 'e5', 'Nf3'], // finished: ends on my move
          ['e4', 'c5'], // gap: opponent reply with no answer
        ],
        isWhite: true,
        titlePrefix: 'From my games (hikaru)',
        startIndex: 5,
      );

      // Finished line: numbered title continuing from startIndex, no comment.
      expect(content, contains('[Event "From my games (hikaru) — line 6"]'));
      // Gap line: the move needing an answer is named in the title, and the
      // final move carries the explanatory comment.
      expect(
        content,
        contains('[Event "From my games (hikaru) — no answer to 1...c5 yet"]'),
      );
      expect(content, contains('{ $kGapLineComment }'));

      // The comment does not break parsing and moves survive intact.
      final parsed = RepertoireService().parseRepertoirePgn(content);
      expect(parsed, hasLength(2));
      expect(
        parsed.map((l) => l.moves.join(' ')),
        containsAll(['e4 e5 Nf3', 'e4 c5']),
      );
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

      final content = draftToRepertoireFile(
        tree,
        name: 'Draft hikaru',
        isWhite: true,
      );

      final parsed = RepertoireService().parseRepertoirePgn(content);
      expect(parsed, hasLength(2));
      expect(parsed.every((l) => l.color == 'white'), isTrue);
      final mainline = parsed.firstWhere((l) => l.moves.length == 4).moves;
      expect(mainline, ['e4', 'e5', 'Nf3', 'Nc6']);
    });
  });
}
