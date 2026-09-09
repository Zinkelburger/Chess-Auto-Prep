import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/pgn/viewer_opening_tree.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';

class _Board {
  Position position = Chess.initial;
}

Position _play(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    final move = pos.parseSan(san);
    expect(move, isNotNull, reason: 'illegal $san from ${pos.fen}');
    pos = pos.play(move!);
  }
  return pos;
}

ViewerOpeningTree _make(_Board board) {
  return ViewerOpeningTree(
    isActive: () => true,
    onChanged: () {},
    filteredGames: () => const [],
    allGames: () => const [],
    fenIndex: () => null,
    currentFen: () => board.position.fen,
    applyPosition: (pos) => board.position = pos,
  );
}

OpeningTree _line(List<String> sans) => OpeningTree()..appendLine(sans);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ViewerOpeningTree cursor ownership', () {
    test(
      'board highlights follow only the tree cursor, including back/reset',
      () {
        final board = _Board()..position = _play(['d4', 'd5']);
        final tree = _make(board);
        expect(tree.recentMoveSquares, isEmpty);
        tree.openingTree = _line(['e4', 'e5', 'Nf3']);
        tree.showOpeningTree = true;
        expect(tree.recentMoveSquares, isEmpty);
        tree.onMoveSelected('e4');
        expect(tree.recentMoveSquares, {'e2', 'e4'});
        tree.onMoveSelected('e5');
        expect(tree.recentMoveSquares, {'e7', 'e5'});
        tree.onMoveSelected('Nf3');
        expect(tree.recentMoveSquares, {'g1', 'f3'});
        tree.goBack();
        expect(tree.recentMoveSquares, {'e7', 'e5'});
        tree.resetToStart();
        expect(tree.recentMoveSquares, isEmpty);
      },
    );

    test(
      'first open from an absent variation puts the board at the root',
      () async {
        final board = _Board()..position = _play(['d4', 'd5']);
        final tree = _make(board)..openingTree = _line(['e4', 'e5']);
        await tree.enter();
        expect(tree.treeCurrentMoveSequence, isEmpty);
        expect(board.position.fen, Chess.initial.fen);
        expect(tree.recentMoveSquares, isEmpty);
      },
    );

    test(
      'a saved root remains the root when returning from another game move',
      () async {
        final board = _Board();
        final tree = _make(board)..openingTree = _line(['e4', 'e5']);
        await tree.enter();
        tree.toggle();
        board.position = _play(['e4']);
        await tree.enter();
        expect(tree.treeCurrentMoveSequence, isEmpty);
        expect(board.position.fen, Chess.initial.fen);
        expect(tree.recentMoveSquares, isEmpty);
      },
    );

    test('highlight uses the played move order after a transposition', () {
      final board = _Board();
      final tree = _make(board);
      tree.openingTree = _line(['Nf3', 'd5', 'd4']);
      tree.openingTree!.syncToMoveHistory(['d4', 'd5']);
      tree.onMoveSelected('Nf3');
      expect(tree.openingTree!.currentNode.move, 'd4');
      expect(tree.recentMoveSquares, {'g1', 'f3'});
    });

    test(
      're-entering after a remount restores the tree line, not the start',
      () async {
        final board = _Board();
        final tree = _make(board);
        tree.openingTree = _line(['e4', 'e5', 'Nf3']);
        tree.showOpeningTree = true;

        tree.onMoveSelected('e4');
        tree.onMoveSelected('e5');
        expect(tree.treeCurrentMoveSequence, ['e4', 'e5']);

        tree.toggle();
        expect(tree.showOpeningTree, isFalse);

        // Showing the tree unmounts PgnViewerWidget, which reloads the game
        // from move 1 and would poison a FEN-sync on the way back in.
        board.position = Chess.initial;

        tree.toggle();
        await Future<void>.delayed(Duration.zero);

        expect(tree.showOpeningTree, isTrue);
        expect(tree.treeCurrentMoveSequence, ['e4', 'e5']);
        expect(
          normalizeFen(board.position.fen),
          normalizeFen(_play(['e4', 'e5']).fen),
        );
      },
    );

    test(
      'first open with no saved cursor syncs the tree to the current game FEN',
      () async {
        final board = _Board()..position = _play(['e4']);
        final tree = _make(board);
        tree.openingTree = _line(['e4', 'e5']);

        await tree.enter();

        expect(tree.treeCurrentMoveSequence, ['e4']);
      },
    );

    test(
      'games-at-position leave offers app-bar back until the tree is re-entered',
      () async {
        final board = _Board();
        final tree = _make(board);
        tree.openingTree = _line(['e4']);
        tree.showOpeningTree = true;
        tree.onMoveSelected('e4');

        expect(tree.hasSavedPosition, isFalse);
        tree.snapshotCursor(leavingForGame: true);
        tree.hide();
        expect(tree.hasSavedPosition, isTrue);

        await tree.enter();
        expect(tree.hasSavedPosition, isFalse);
        expect(tree.treeCurrentMoveSequence, ['e4']);
      },
    );

    test('plain toggle-off does not show the app-bar back button', () {
      final board = _Board();
      final tree = _make(board);
      tree.openingTree = _line(['e4']);
      tree.showOpeningTree = true;
      tree.onMoveSelected('e4');

      tree.toggle();
      expect(tree.showOpeningTree, isFalse);
      expect(tree.hasSavedPosition, isFalse);
    });
  });
}
