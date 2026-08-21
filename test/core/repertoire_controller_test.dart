import 'dart:async';
import 'dart:io' as io;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';

/// Replay [moves] from [startingFen] (or standard start) and return the FEN.
String fenAfterMoves(List<String> moves, {String? startingFen}) {
  Position pos;
  if (startingFen != null) {
    pos = Chess.fromSetup(Setup.parseFen(startingFen));
  } else {
    pos = Chess.initial;
  }
  for (final san in moves) {
    final move = pos.parseSan(san);
    if (move == null) break;
    pos = pos.play(move);
  }
  return pos.fen;
}

({String fen, int moveIndex, List<String> history}) navigationSnapshot(
  RepertoireController controller,
) {
  return (
    fen: controller.fen,
    moveIndex: controller.currentMoveIndex,
    history: List<String>.from(controller.moveHistory),
  );
}

/// Knuth-style invariants that must hold after every navigation/play operation.
void assertNavigationInvariants(RepertoireController controller) {
  expect(controller.currentMoveIndex, greaterThanOrEqualTo(-1));

  // In tree-path model, moveHistory == currentMoveSequence (always up to cursor).
  expect(controller.moveHistory, controller.currentMoveSequence);

  if (controller.currentMoveIndex < 0) {
    expect(controller.currentMoveSequence, isEmpty);
  } else {
    expect(
      controller.currentMoveSequence.length,
      controller.currentMoveIndex + 1,
    );
  }

  expect(
    controller.fen,
    fenAfterMoves(
      controller.currentMoveSequence,
      startingFen: controller.startingFen,
    ),
  );
}

void main() {
  group('setPositionFromMoveHistory', () {
    test(
      'setPositionFromMoveHistory preserves full move history from startpos',
      () {
        final controller = RepertoireController();
        const fen =
            'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';
        const moves = ['e4', 'e5', 'Nf3'];

        final success = controller.setPositionFromMoveHistory(
          fen: fen,
          moves: moves,
        );

        expect(success, isTrue);
        expect(controller.currentMoveSequence, moves);
        expect(controller.currentMoveIndex, 2);
        expect(controller.fen, fen);
        assertNavigationInvariants(controller);
      },
    );

    test('setPositionFromMoveHistory supports custom starting positions', () {
      final controller = RepertoireController();
      const startingFen =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
      const fen =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';

      final success = controller.setPositionFromMoveHistory(
        fen: fen,
        moves: const ['Nf3'],
        startingFen: startingFen,
      );

      expect(success, isTrue);
      expect(controller.currentMoveSequence, ['Nf3']);
      expect(controller.fen, fen);
      expect(controller.startingFen, startingFen);
      assertNavigationInvariants(controller);
    });
  });

  group('appendNewLine', () {
    test('appendNewLine preserves custom start positions from PGN headers', () {
      final controller = RepertoireController();
      const startingFen =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
      final pgn = [
        '[Event "Training Line"]',
        '[FEN "$startingFen"]',
        '[SetUp "1"]',
        '',
        '2. Nf3 *',
      ].join('\n');

      controller.appendNewLine(['Nf3'], 'Custom line', pgn);

      expect(controller.repertoireLines, hasLength(1));
      expect(controller.repertoireLines.single.startPosition.fen, startingFen);
    });
  });

  group('promoteVariation', () {
    /// A tree with two replies to 2.c4: mainline e6, then g6 as a sibling.
    RepertoireController controllerWithVariation() {
      final controller = RepertoireController();
      controller.loadMoveHistory(['d4', 'Nf6', 'c4', 'e6']);
      controller.jumpToMoveIndex(2); // cursor after 2.c4
      controller.playMove('g6'); // adds g6 as the second child
      return controller;
    }

    test('a cursor on an earlier sibling keeps pointing at its own move', () {
      final controller = controllerWithVariation();

      // Park the cursor on the mainline e6, which sits at index 0.
      controller.jump(const TreePath([0, 0, 0, 0]));
      expect(controller.moveHistory, ['d4', 'Nf6', 'c4', 'e6']);

      // Promoting g6 shuffles it to index 0, pushing e6 down to index 1.
      controller.promoteVariation(const TreePath([0, 0, 0, 1]));

      // The cursor must follow e6, not stay on index 0 and silently become g6.
      expect(controller.moveHistory, ['d4', 'Nf6', 'c4', 'e6']);
      expect(controller.fen, fenAfterMoves(['d4', 'Nf6', 'c4', 'e6']));
    });

    test('a cursor on the promoted move stays on it', () {
      final controller = controllerWithVariation();
      expect(controller.moveHistory, ['d4', 'Nf6', 'c4', 'g6']);

      controller.promoteVariation(const TreePath([0, 0, 0, 1]));

      expect(controller.moveHistory, ['d4', 'Nf6', 'c4', 'g6']);
      expect(controller.path, const TreePath([0, 0, 0, 0]));
    });

    test('the opening tree cursor is re-synced after a promotion', () async {
      final controller = RepertoireController();
      await controller.restoreRepertoireFromPgn('''
[Event "A"]
[Result "*"]

1. d4 Nf6 2. c4 e6 *

[Event "B"]
[Result "*"]

1. d4 Nf6 2. c4 g6 *
''');

      controller.loadMoveHistory(['d4', 'Nf6', 'c4', 'e6']);
      controller.jumpToMoveIndex(2);
      controller.playMove('g6');
      controller.jump(const TreePath([0, 0, 0, 0])); // back onto e6

      controller.promoteVariation(const TreePath([0, 0, 0, 1]));

      // Every path mutation funnels through the syncing setter, so the
      // opening-tree cursor must agree with the move history.
      expect(controller.openingTree, isNotNull);
      expect(controller.openingTree!.currentMovePath, controller.moveHistory);
    });
  });

  group('repertoireLines identity', () {
    test('appendNewLine swaps the list rather than mutating it', () {
      final controller = RepertoireController();
      controller.appendNewLine(['e4'], 'One', '1. e4 *');
      final first = controller.repertoireLines;

      controller.appendNewLine(['d4'], 'Two', '1. d4 *');

      // Consumers rebuild their search indexes only on identity change.
      expect(identical(controller.repertoireLines, first), isFalse);
      expect(first, hasLength(1));
      expect(controller.repertoireLines, hasLength(2));
    });

    test('appendMoveToExistingLine swaps the list rather than mutating it', () {
      final controller = RepertoireController();
      controller.appendNewLine(['e4'], 'One', '1. e4 *');
      final before = controller.repertoireLines;

      controller.appendMoveToExistingLine(['e4'], 'e5');

      expect(identical(controller.repertoireLines, before), isFalse);
      expect(before.single.moves, ['e4']);
      expect(controller.repertoireLines.single.moves, ['e4', 'e5']);
    });

    test('the exposed list rejects in-place mutation', () {
      final controller = RepertoireController();
      controller.appendNewLine(['e4'], 'One', '1. e4 *');

      expect(
        () => controller.repertoireLines.add(controller.repertoireLines.first),
        throwsUnsupportedError,
      );
    });
  });

  group('navigation invariants', () {
    late RepertoireController controller;

    setUp(() {
      controller = RepertoireController();
    });

    test('goBack at start position is identity', () {
      final before = navigationSnapshot(controller);

      controller.goBack();

      final after = navigationSnapshot(controller);
      expect(after.fen, before.fen);
      expect(after.moveIndex, before.moveIndex);
      expect(after.history, before.history);
      assertNavigationInvariants(controller);
    });

    test('goForward at end position is identity', () {
      controller.loadMoveHistory(['e4', 'e5', 'Nf3']);
      final before = navigationSnapshot(controller);

      controller.goForward();

      final after = navigationSnapshot(controller);
      expect(after.fen, before.fen);
      expect(after.moveIndex, before.moveIndex);
      expect(after.history, before.history);
      assertNavigationInvariants(controller);
    });

    test('goBack after playMove restores previous FEN exactly', () {
      controller.playMove('e4');
      final afterE4 = navigationSnapshot(controller);

      controller.playMove('e5');
      expect(controller.fen, isNot(equals(afterE4.fen)));

      controller.goBack();

      expect(controller.fen, afterE4.fen);
      expect(controller.currentMoveIndex, afterE4.moveIndex);
      expect(controller.currentMoveSequence, afterE4.history);
      // e5 still exists in the tree as a child — goForward reaches it.
      controller.goForward();
      expect(controller.currentMoveSequence, ['e4', 'e5']);
      assertNavigationInvariants(controller);
    });

    test('goToStart resets to initial FEN regardless of depth', () {
      controller.loadMoveHistory(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']);

      controller.goToStart();

      expect(controller.currentMoveIndex, -1);
      expect(controller.currentMoveSequence, isEmpty);
      expect(controller.fen, fenAfterMoves([]));
      assertNavigationInvariants(controller);
    });

    test('goToEnd after goToStart restores final position', () {
      const moves = ['e4', 'e5', 'Nf3', 'Nc6'];
      controller.loadMoveHistory(moves);

      controller.goToStart();
      expect(controller.currentMoveIndex, -1);

      controller.goToEnd();

      expect(controller.currentMoveIndex, moves.length - 1);
      expect(controller.currentMoveSequence, moves);
      expect(controller.fen, fenAfterMoves(moves));
      assertNavigationInvariants(controller);
    });

    test('goBack and goForward are inverses for every move in a sequence', () {
      const moves = ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5'];
      for (final san in moves) {
        controller.playMove(san);
        assertNavigationInvariants(controller);
      }
      final endSnapshot = navigationSnapshot(controller);

      for (var i = 0; i < moves.length; i++) {
        controller.goBack();
        assertNavigationInvariants(controller);
      }
      expect(controller.currentMoveIndex, -1);
      expect(controller.fen, fenAfterMoves([]));

      for (var i = 0; i < moves.length; i++) {
        controller.goForward();
        assertNavigationInvariants(controller);
        expect(controller.currentMoveSequence, moves.sublist(0, i + 1));
      }

      final restored = navigationSnapshot(controller);
      expect(restored.fen, endSnapshot.fen);
      expect(restored.moveIndex, endSnapshot.moveIndex);
      expect(restored.history, endSnapshot.history);
    });

    test('jumpToMoveIndex with out-of-bounds index is identity', () {
      controller.loadMoveHistory(['e4', 'e5', 'Nf3']);

      for (final badIndex in [-2, 3, 10]) {
        final before = navigationSnapshot(controller);
        controller.jumpToMoveIndex(badIndex);
        final after = navigationSnapshot(controller);
        expect(after.fen, before.fen);
        expect(after.moveIndex, before.moveIndex);
        expect(after.history, before.history);
      }
      assertNavigationInvariants(controller);
    });
  });

  group('move playing', () {
    late RepertoireController controller;

    setUp(() {
      controller = RepertoireController();
    });

    test(
      'playMove advances FEN, increments moveIndex, extends history by exactly one',
      () {
        final before = navigationSnapshot(controller);

        controller.playMove('e4');

        expect(controller.moveHistory.length, before.history.length + 1);
        expect(controller.currentMoveIndex, before.moveIndex + 1);
        expect(controller.moveHistory.last, 'e4');
        expect(controller.fen, fenAfterMoves(['e4']));
        expect(controller.fen, isNot(equals(before.fen)));
        assertNavigationInvariants(controller);
      },
    );

    test('playMove after goBack creates variation', () {
      controller.loadMoveHistory(['e4', 'e5', 'Nf3']);
      controller.goBack();
      controller.goBack();
      expect(controller.currentMoveIndex, 0);

      controller.playMove('c5');

      // c5 is a new variation; cursor is now on the e4 → c5 line.
      expect(controller.currentMoveSequence, ['e4', 'c5']);
      expect(controller.currentMoveIndex, 1);
      expect(controller.fen, fenAfterMoves(['e4', 'c5']));
      assertNavigationInvariants(controller);
    });

    test(
      'userSelectedTreeMove maintains consistency between history and tree cursor',
      () async {
        const pgn = '''
// Color: White

[Event "Tree line"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6
''';

        await controller.restoreRepertoireFromPgn(pgn);
        controller.navigateToLineMove(['e4']);
        assertNavigationInvariants(controller);

        final treePathBefore = controller.openingTree!.currentNode
            .getMovePath();
        expect(treePathBefore, ['e4']);

        controller.userSelectedTreeMove('e5');

        expect(controller.moveHistory, ['e4', 'e5']);
        expect(controller.currentMoveIndex, 1);
        expect(controller.currentMoveSequence, ['e4', 'e5']);
        expect(controller.openingTree!.currentNode.getMovePath(), ['e4', 'e5']);
        expect(controller.fen, fenAfterMoves(['e4', 'e5']));
        assertNavigationInvariants(controller);
      },
    );

    test(
      'userSelectedTreeMove keeps the board move order on a one-ply transposition',
      () async {
        const pgn = '''
// Color: White

[Event "Book line"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "*"]

1. d4 Nf6 2. e3 c5
''';

        await controller.restoreRepertoireFromPgn(pgn);
        controller.goToStart();
        controller.playMove('d4');
        controller.playMove('c5');
        controller.playMove('e3');
        expect(controller.openingTree!.inBook, isFalse);
        expect(
          controller.openingTree!.continuations.map((g) => g.move),
          contains('Nf6'),
        );

        controller.userSelectedTreeMove('Nf6');

        expect(controller.currentMoveSequence, ['d4', 'c5', 'e3', 'Nf6']);
        expect(controller.openingTree!.inBook, isTrue);
        expect(controller.fen, fenAfterMoves(['d4', 'c5', 'e3', 'Nf6']));
        assertNavigationInvariants(controller);
      },
    );

    test(
      'consecutive playMove calls produce monotonically increasing move indices',
      () {
        const moves = ['e4', 'e5', 'Nf3', 'Nc6'];
        var previousIndex = controller.currentMoveIndex;

        for (final san in moves) {
          controller.playMove(san);
          expect(controller.currentMoveIndex, greaterThan(previousIndex));
          previousIndex = controller.currentMoveIndex;
          assertNavigationInvariants(controller);
        }
      },
    );
  });

  group('PGN and repertoire sync', () {
    late io.Directory tempDir;
    late String filePath;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp(
        'repertoire_ctrl_test',
      );
      filePath = '${tempDir.path}/test.pgn';
      await io.File(filePath).writeAsString('''
// Color: White

[Event "Line 1"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5
''');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'restoreRepertoireFromPgn rebuilds parsed lines from PGN snapshot',
      () async {
        final controller = RepertoireController();

        const newPgn = '''
// Color: White

[Event "Fresh line"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 c5 2. Nf3
''';

        await controller.restoreRepertoireFromPgn(newPgn);

        expect(controller.repertoireLines, hasLength(1));
        expect(controller.repertoireLines.single.moves, ['e4', 'c5', 'Nf3']);
        expect(controller.openingTree, isNotNull);
      },
    );

    test(
      'restoreRepertoireFromPgn without Root comment resets navigation to start',
      () async {
        final controller = RepertoireController();
        controller.loadMoveHistory(['d4', 'd5', 'c4']);

        const newPgn = '''
// Color: White

[Event "Fresh line"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 c5 2. Nf3
''';

        await controller.restoreRepertoireFromPgn(newPgn);

        expect(controller.currentMoveIndex, -1);
        expect(controller.currentMoveSequence, isEmpty);
      },
      skip:
          'BUG: restoreRepertoireFromPgn without // Root: leaves stale moveHistory/currentMoveIndex',
    );

    test(
      'restoreRepertoireFromPgn with empty syncPath resets navigation to start',
      () async {
        final controller = RepertoireController();
        controller.loadMoveHistory(['d4', 'd5', 'c4']);

        const newPgn = '''
// Color: White

[Event "Fresh line"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 c5 2. Nf3
''';

        await controller.restoreRepertoireFromPgn(newPgn, syncPath: []);

        expect(controller.repertoireLines.single.moves, ['e4', 'c5', 'Nf3']);
        expect(controller.currentMoveIndex, -1);
        expect(controller.currentMoveSequence, isEmpty);
        expect(controller.fen, kStandardStartFen);
        assertNavigationInvariants(controller);
      },
    );

    test('setRepertoireColor flips side and resets navigation state', () async {
      final controller = RepertoireController();
      await controller.setRepertoire(
        RepertoireMetadata(
          name: 'Test',
          filePath: filePath,
          lastModified: DateTime(2026, 1, 1),
        ),
      );
      controller.loadMoveHistory(['e4', 'e5', 'Nf3']);
      expect(controller.currentMoveIndex, 2);

      await controller.setRepertoireColor(false);

      expect(controller.isRepertoireWhite, isFalse);
      expect(controller.needsColorSelection, isFalse);
      expect(controller.currentMoveIndex, -1);
      expect(controller.currentMoveSequence, isEmpty);
      expect(controller.repertoireLines.single.color, 'black');
      assertNavigationInvariants(controller);
    });

    test('loadMoveHistory with empty history produces start position FEN', () {
      final controller = RepertoireController();

      controller.loadMoveHistory([]);

      expect(controller.moveHistory, isEmpty);
      expect(controller.currentMoveIndex, -1);
      expect(controller.fen, kStandardStartFen);
      assertNavigationInvariants(controller);
    });
  });

  group('saved root position', () {
    test('defaults to the starting position when no root is saved', () {
      final controller = RepertoireController();

      expect(controller.rootMoveSans, isEmpty);
      expect(controller.rootFen, kStandardStartFen);
      expect(controller.isAtRootPosition, isTrue);

      controller.loadMoveHistory(['d4', 'Nf6']);
      expect(controller.isAtRootPosition, isFalse);
    });

    test('follows the // Root: header and tracks the cursor', () async {
      final controller = RepertoireController();
      const pgnWithRoot = '''
// Color: Black
// Root: 1. d4 Nf6 2. c4 c5

[Event "Benoni"]
[Date "2026-01-01"]
[White "Opponent"]
[Black "Me"]
[Result "0-1"]

1. d4 Nf6 2. c4 c5 3. d5 e6
''';

      await controller.restoreRepertoireFromPgn(pgnWithRoot);

      const rootSans = ['d4', 'Nf6', 'c4', 'c5'];
      expect(controller.rootMoveSans, rootSans);
      expect(controller.rootFen, fenAfterMoves(rootSans));

      // Loading navigated to the root; leaving it must be detected.
      expect(controller.isAtRootPosition, isTrue);
      controller.goToStart();
      expect(controller.isAtRootPosition, isFalse);
    });
  });

  group('state machine properties', () {
    late RepertoireController controller;

    setUp(() {
      controller = RepertoireController();
    });

    test('no operation changes FEN without also updating moveIndex', () {
      controller.loadMoveHistory(['e4', 'e5', 'Nf3', 'Nc6']);

      void expectFenIndexCoupled(void Function() operation) {
        final fenBefore = controller.fen;
        final indexBefore = controller.currentMoveIndex;
        operation();
        if (controller.fen == fenBefore) {
          expect(controller.currentMoveIndex, indexBefore);
        }
      }

      expectFenIndexCoupled(controller.goBack);
      expectFenIndexCoupled(controller.goBack);
      expectFenIndexCoupled(controller.goForward);
      expectFenIndexCoupled(() => controller.jumpToMoveIndex(1));
      expectFenIndexCoupled(controller.goToStart);
      expectFenIndexCoupled(controller.goToEnd);
      expectFenIndexCoupled(() => controller.jumpToMoveIndex(99));
      assertNavigationInvariants(controller);
    });

    test(
      'currentMoveSequence length equals moveIndex plus one after play and navigate',
      () {
        const moves = ['e4', 'e5', 'Nf3'];
        for (final san in moves) {
          controller.playMove(san);
          assertNavigationInvariants(controller);
        }

        controller.goBack();
        assertNavigationInvariants(controller);

        controller.goForward();
        assertNavigationInvariants(controller);

        controller.goToStart();
        assertNavigationInvariants(controller);

        controller.goToEnd();
        assertNavigationInvariants(controller);
      },
    );
  });

  group('loadRepertoire epoch', () {
    test('a superseded load does not overwrite the later repertoire', () async {
      final dir = io.Directory.systemTemp.createTempSync('rep_load');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final a = io.File('${dir.path}/a.pgn')
        ..writeAsStringSync(
          '// Color: White\n\n[Event "A"]\n[Result "*"]\n\n1. e4 *\n',
        );
      final b = io.File('${dir.path}/b.pgn')
        ..writeAsStringSync(
          '// Color: White\n\n[Event "B"]\n[Result "*"]\n\n1. d4 *\n',
        );

      final gate = Completer<void>();
      final firstReached = Completer<void>();
      final controller = RepertoireController();
      controller.debugAfterRepertoireRead = () async {
        if (!firstReached.isCompleted) firstReached.complete();
        await gate.future;
      };

      final first = controller.setRepertoire(
        RepertoireMetadata(
          filePath: a.path,
          name: 'A',
          lastModified: DateTime.now(),
        ),
      );
      await firstReached.future.timeout(const Duration(seconds: 5));
      controller.debugAfterRepertoireRead = null;

      await controller.setRepertoire(
        RepertoireMetadata(
          filePath: b.path,
          name: 'B',
          lastModified: DateTime.now(),
        ),
      );
      gate.complete();
      await first;

      expect(controller.currentRepertoire?.filePath, b.path);
      expect(controller.repertoirePgn, contains('1. d4'));
      expect(controller.repertoirePgn, isNot(contains('1. e4')));
    });
  });
}
