/// The controller hands its listeners one cursor snapshot per move — an
/// identity-stable history, a cached position — and tells structural
/// changes apart from cursor moves.  Screens scope their rebuilds on both.
library;

import '../../support/repertoire_dependencies.dart';

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';

void main() {
  group('cursor snapshot', () {
    test('moveHistory keeps its identity until the cursor moves', () {
      final c = testBuilderWorkspace();
      c.board.loadMoveHistory(['e4', 'e5', 'Nf3']);

      final first = c.board.moveHistory;
      expect(identical(c.board.moveHistory, first), isTrue);
      expect(identical(c.board.currentMoveSequence, first), isTrue);
      expect(() => first.add('x'), throwsUnsupportedError);

      c.board.goBack();
      expect(identical(c.board.moveHistory, first), isFalse);
      expect(c.board.moveHistory, ['e4', 'e5']);
      c.dispose();
    });

    test('position is the cursor node\'s, never re-parsed', () {
      final c = testBuilderWorkspace();
      c.board.loadMoveHistory(['d4', 'Nf6', 'c4']);
      expect(c.board.position.fen, c.board.fen);
      expect(identical(c.board.position, c.board.position), isTrue);

      c.board.goToStart();
      expect(c.board.tree.startingPosition.fen, c.board.position.fen);
      expect(identical(c.board.position, c.board.position), isTrue);
      expect(c.board.position.fen, Chess.initial.fen);
      c.dispose();
    });

    test('recentMoveTrail marks the move that produced the position', () {
      final c = testBuilderWorkspace();
      c.board.loadMoveHistory(['e4', 'e5', 'Nf3']);
      expect(c.board.recentMoveTrail(), {'g1', 'f3'});
      expect(c.board.recentMoveTrail(lastN: 2), {'e7', 'e5', 'g1', 'f3'});

      c.board.goToStart();
      expect(c.board.recentMoveTrail(), isEmpty);
      c.dispose();
    });

    test('a promotion keeps the cursor on the same moves', () {
      final c = testBuilderWorkspace();
      c.board.loadMoveHistory(['e4', 'e5']);
      c.board.goBack();
      c.board.playMove('c5'); // variation at ply 1
      expect(c.board.moveHistory, ['e4', 'c5']);
      c.board.makeMainLine(c.board.path);
      expect(c.board.moveHistory, ['e4', 'c5']);
      expect(c.board.tree.roots.first.children.first.san, 'c5');
      c.dispose();
    });
  });

  group('structureVersion', () {
    test('a cursor move notifies without bumping it', () {
      final c = testBuilderWorkspace();
      c.board.loadMoveHistory(['e4', 'e5', 'Nf3']);
      final version = c.structureVersion;
      var notified = 0;
      c.addListener(() => notified++);

      c.board.goBack();
      c.board.goForward();
      c.board.jump(TreePath.empty);
      expect(notified, 3);
      expect(c.structureVersion, version);
      c.dispose();
    });

    test('edits and loads bump it', () {
      final c = testBuilderWorkspace();
      final v0 = c.structureVersion;

      c.board.loadMoveHistory(['e4']);
      final v1 = c.structureVersion;
      expect(v1, greaterThan(v0));

      c.board.playMove('e5'); // adds a node, then jumps
      final v2 = c.structureVersion;
      expect(v2, greaterThan(v1));

      c.board.setCommentAtPath(c.board.path, 'hi');
      expect(c.structureVersion, greaterThan(v2));
      c.dispose();
    });

    test('playing an existing move is a pure cursor move', () {
      final c = testBuilderWorkspace();
      c.board.loadMoveHistory(['e4', 'e5']);
      c.board.goToStart();
      final version = c.structureVersion;
      c.board.playMove('e4');
      expect(c.board.moveHistory, ['e4']);
      expect(c.structureVersion, version);
      c.dispose();
    });
  });

  group('rootFen', () {
    test('is replayed once per starting position and root moves', () {
      final c = testBuilderWorkspace();
      final fen = c.board.rootFen(c.document.rootMoves);
      expect(fen, Chess.initial.fen);
      expect(identical(c.board.rootFen(c.document.rootMoves), fen), isTrue);

      final custom = fenAfterMoves(Chess.initial.fen, ['e4', 'c5'], 1);
      c.board.setPositionFromFen(custom);
      expect(c.board.rootFen(c.document.rootMoves), custom);
      c.dispose();
    });
  });
}
