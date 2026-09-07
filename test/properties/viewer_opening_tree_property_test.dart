/// Invariant tests for the PGN viewer's opening-tree cursor.
///
/// [ViewerOpeningTree] owns a cursor into a merged tree and drives the board
/// through a callback. The laws here are about that pairing — the board always
/// shows the cursor's position, a step back undoes exactly one move, leaving
/// and re-entering restores where you were — rather than about any particular
/// tree. The tree is injected, so nothing here builds one in an isolate.
library;

import 'dart:math';

import 'package:chess_auto_prep/core/pgn/viewer_opening_tree.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tree_property_support.dart';

class _Board {
  Position position = Chess.initial;
}

ViewerOpeningTree _viewer(_Board board) => ViewerOpeningTree(
  isActive: () => true,
  onChanged: () {},
  filteredGames: () => const [],
  allGames: () => const [],
  fenIndex: () => null,
  currentFen: () => board.position.fen,
  applyPosition: (position) => board.position = position,
);

/// A seeded tree of real games to explore.
OpeningTree _tree(int seed) {
  final rng = Random(seed);
  final games = <String>[];
  for (var i = 0; i < 2 + rng.nextInt(3); i++) {
    games.add(
      pgnOf(
        randomGameTree(rng, Chess.initial, maxDepth: 4 + rng.nextInt(3)),
        result: '*',
      ),
    );
  }
  return treeFrom(games);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The invariant that must hold after every cursor operation: the sequence
  /// the viewer reports, the tree's own cursor and the board all agree.
  void expectInSync(ViewerOpeningTree viewer, _Board board, String reason) {
    final tree = viewer.openingTree!;
    expect(
      viewer.treeCurrentMoveSequence,
      tree.currentMovePath,
      reason: reason,
    );
    expect(
      normalizeFen(board.position.fen),
      normalizeFen(tree.currentFen),
      reason: '$reason: the board is not showing the cursor',
    );
  }

  test('the board follows the cursor through any walk of the tree', () {
    for (var seed = 0; seed < 12; seed++) {
      final board = _Board();
      final viewer = _viewer(board)..openingTree = _tree(seed);
      viewer.showOpeningTree = true;
      viewer.resetToStart();
      expectInSync(viewer, board, 'seed $seed: after reset');

      final rng = Random(seed);
      for (var step = 0; step < 12; step++) {
        final moves = viewer.openingTree!.continuations;
        if (moves.isEmpty) break;
        viewer.onMoveSelected(moves[rng.nextInt(moves.length)].move);
        expectInSync(viewer, board, 'seed $seed: after step $step');
      }
      viewer.goBack();
      expectInSync(viewer, board, 'seed $seed: after back');
      viewer.resetToStart();
      expect(viewer.treeCurrentMoveSequence, isEmpty);
      expectInSync(viewer, board, 'seed $seed: after reset to start');
    }
  });

  test('a selected move and a step back cancel out', () {
    for (var seed = 0; seed < 12; seed++) {
      final board = _Board();
      final viewer = _viewer(board)..openingTree = _tree(seed);
      viewer.showOpeningTree = true;
      viewer.resetToStart();

      for (var step = 0; step < 8; step++) {
        final before = List.of(viewer.treeCurrentMoveSequence);
        final fen = normalizeFen(board.position.fen);
        final moves = viewer.openingTree!.continuations;
        if (moves.isEmpty) break;
        viewer.onMoveSelected(moves.first.move);
        expect(
          viewer.treeCurrentMoveSequence.length,
          before.length + 1,
          reason: 'seed $seed: a move did not advance exactly one ply',
        );
        viewer.goBack();
        expect(
          viewer.treeCurrentMoveSequence,
          before,
          reason: 'seed $seed: back did not undo the move',
        );
        expect(normalizeFen(board.position.fen), fen, reason: 'seed $seed');
        viewer.onMoveSelected(moves.first.move);
      }
    }
  });

  test('goToEnd terminates on a book line and never walks backwards', () {
    for (var seed = 0; seed < 12; seed++) {
      final board = _Board();
      final viewer = _viewer(board)..openingTree = _tree(seed);
      viewer.showOpeningTree = true;
      viewer.resetToStart();
      viewer.goToEnd();
      expectInSync(viewer, board, 'seed $seed: after goToEnd');
      expect(
        viewer.treeCurrentMoveSequence,
        isNotEmpty,
        reason: 'seed $seed: goToEnd went nowhere in a non-empty tree',
      );
      // Idempotent: the end of the line is the end of the line.
      final reached = List.of(viewer.treeCurrentMoveSequence);
      viewer.goToEnd();
      expect(
        viewer.treeCurrentMoveSequence.length,
        greaterThanOrEqualTo(reached.length),
        reason: 'seed $seed: goToEnd walked backwards',
      );
    }
  });

  test(
    'leaving and re-entering restores the line, whatever the board shows',
    () async {
      for (var seed = 0; seed < 8; seed++) {
        final board = _Board();
        final viewer = _viewer(board)..openingTree = _tree(seed);
        viewer.showOpeningTree = true;
        viewer.resetToStart();
        for (var step = 0; step < 3; step++) {
          final moves = viewer.openingTree!.continuations;
          if (moves.isEmpty) break;
          viewer.onMoveSelected(moves.first.move);
        }
        final line = List.of(viewer.treeCurrentMoveSequence);
        if (line.isEmpty) continue;

        viewer.snapshotCursor(leavingForGame: true);
        expect(viewer.hasSavedPosition, isTrue, reason: 'seed $seed');
        viewer.hide();
        // Opening a game remounts the viewer and resets the board to move 1;
        // re-entering must not adopt that position.
        board.position = Chess.initial;
        viewer.resetToStart();

        await viewer.restoreSavedPosition();
        expect(
          viewer.treeCurrentMoveSequence,
          line,
          reason: 'seed $seed: re-entering lost the line',
        );
        expectInSync(viewer, board, 'seed $seed: after restore');
        expect(
          viewer.hasSavedPosition,
          isFalse,
          reason: 'seed $seed: the back button survived the return',
        );
      }
    },
  );

  test('dropping the tree drops everything that pointed into it', () {
    for (var seed = 0; seed < 8; seed++) {
      final board = _Board();
      final viewer = _viewer(board)..openingTree = _tree(seed);
      viewer.showOpeningTree = true;
      viewer.resetToStart();
      final moves = viewer.openingTree!.continuations;
      if (moves.isEmpty) continue;
      viewer.onMoveSelected(moves.first.move);
      viewer.snapshotCursor(leavingForGame: true);

      viewer.clearTree();
      expect(viewer.openingTree, isNull, reason: 'seed $seed');
      expect(viewer.hasSavedPosition, isFalse, reason: 'seed $seed');

      // Every cursor operation is a no-op without a tree, and none throws.
      viewer.onMoveSelected('e4');
      viewer.goBack();
      viewer.goForward();
      viewer.goToEnd();
      viewer.resetToStart();
      expect(viewer.treeCurrentMoveSequence, isEmpty, reason: 'seed $seed');
      expect(viewer.gamesAtTreePosition(), isEmpty, reason: 'seed $seed');

      viewer.openingTree = _tree(seed);
      viewer.resetForNewFile();
      expect(viewer.openingTree, isNull, reason: 'seed $seed');
      expect(viewer.showOpeningTree, isFalse, reason: 'seed $seed');
      expect(viewer.hasSavedPosition, isFalse, reason: 'seed $seed');
    }
  });
}
