/// The controller hands its listeners one cursor snapshot per move — an
/// identity-stable history, a cached position — and tells structural
/// changes apart from cursor moves.  Screens scope their rebuilds on both.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';

void main() {
  group('cursor snapshot', () {
    test('moveHistory keeps its identity until the cursor moves', () {
      final c = RepertoireController();
      c.loadMoveHistory(['e4', 'e5', 'Nf3']);

      final first = c.moveHistory;
      expect(identical(c.moveHistory, first), isTrue);
      expect(identical(c.currentMoveSequence, first), isTrue);
      expect(() => first.add('x'), throwsUnsupportedError);

      c.goBack();
      expect(identical(c.moveHistory, first), isFalse);
      expect(c.moveHistory, ['e4', 'e5']);
      c.dispose();
    });

    test('position is the cursor node\'s, never re-parsed', () {
      final c = RepertoireController();
      c.loadMoveHistory(['d4', 'Nf6', 'c4']);
      expect(c.position.fen, c.fen);
      expect(identical(c.position, c.position), isTrue);

      c.goToStart();
      expect(identical(c.position, c.tree.startingPosition), isTrue);
      expect(c.position.fen, Chess.initial.fen);
      c.dispose();
    });

    test('recentMoveTrail marks the move that produced the position', () {
      final c = RepertoireController();
      c.loadMoveHistory(['e4', 'e5', 'Nf3']);
      expect(c.recentMoveTrail(), {'g1', 'f3'});
      expect(c.recentMoveTrail(lastN: 2), {'e7', 'e5', 'g1', 'f3'});

      c.goToStart();
      expect(c.recentMoveTrail(), isEmpty);
      c.dispose();
    });

    test('a promotion keeps the cursor on the same moves', () {
      final c = RepertoireController();
      c.loadMoveHistory(['e4', 'e5']);
      c.goBack();
      c.playMove('c5'); // variation at ply 1
      expect(c.moveHistory, ['e4', 'c5']);
      c.makeMainLine(c.path);
      expect(c.moveHistory, ['e4', 'c5']);
      expect(c.tree.roots.first.children.first.san, 'c5');
      c.dispose();
    });
  });

  group('structureVersion', () {
    test('a cursor move notifies without bumping it', () {
      final c = RepertoireController();
      c.loadMoveHistory(['e4', 'e5', 'Nf3']);
      final version = c.structureVersion;
      var notified = 0;
      c.addListener(() => notified++);

      c.goBack();
      c.goForward();
      c.jump(TreePath.empty);
      expect(notified, 3);
      expect(c.structureVersion, version);
      c.dispose();
    });

    test('edits and loads bump it', () {
      final c = RepertoireController();
      final v0 = c.structureVersion;

      c.loadMoveHistory(['e4']);
      final v1 = c.structureVersion;
      expect(v1, greaterThan(v0));

      c.playMove('e5'); // adds a node, then jumps
      final v2 = c.structureVersion;
      expect(v2, greaterThan(v1));

      c.setCommentAtPath(c.path, 'hi');
      expect(c.structureVersion, greaterThan(v2));
      c.dispose();
    });

    test('playing an existing move is a pure cursor move', () {
      final c = RepertoireController();
      c.loadMoveHistory(['e4', 'e5']);
      c.goToStart();
      final version = c.structureVersion;
      c.playMove('e4');
      expect(c.moveHistory, ['e4']);
      expect(c.structureVersion, version);
      c.dispose();
    });
  });

  group('rootFen', () {
    test('is replayed once per starting position and root moves', () {
      final c = RepertoireController();
      final fen = c.rootFen;
      expect(fen, Chess.initial.fen);
      expect(identical(c.rootFen, fen), isTrue);

      final custom = fenAfterMoves(Chess.initial.fen, ['e4', 'c5'], 1);
      c.setPositionFromFen(custom);
      expect(c.rootFen, custom);
      c.dispose();
    });
  });
}
