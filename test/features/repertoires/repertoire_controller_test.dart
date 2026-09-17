import '../../support/repertoire_dependencies.dart';
import 'dart:async';
import 'dart:io' as io;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/builder_workspace_controller.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';

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
  BuilderWorkspaceController controller,
) {
  return (
    fen: controller.board.fen,
    moveIndex: controller.board.currentMoveIndex,
    history: List<String>.from(controller.board.moveHistory),
  );
}

/// Knuth-style invariants that must hold after every navigation/play operation.
void assertNavigationInvariants(BuilderWorkspaceController controller) {
  expect(controller.board.currentMoveIndex, greaterThanOrEqualTo(-1));

  // In tree-path model, moveHistory == currentMoveSequence (always up to cursor).
  expect(controller.board.moveHistory, controller.board.currentMoveSequence);

  if (controller.board.currentMoveIndex < 0) {
    expect(controller.board.currentMoveSequence, isEmpty);
  } else {
    expect(
      controller.board.currentMoveSequence.length,
      controller.board.currentMoveIndex + 1,
    );
  }

  expect(
    controller.board.fen,
    fenAfterMoves(
      controller.board.currentMoveSequence,
      startingFen: controller.board.startingFen,
    ),
  );
}

void main() {
  late io.Directory storageRoot;
  setUp(() async {
    storageRoot = await io.Directory.systemTemp.createTemp(
      'repertoire-storage-',
    );
    StorageFactory.instanceForTest = IOStorageService(
      documentsRoot: storageRoot,
      supportRoot: io.Directory('${storageRoot.path}/support'),
    );
  });
  tearDown(() async {
    StorageFactory.instanceForTest = null;
    await storageRoot.delete(recursive: true);
  });
  group('setPositionFromMoveHistory', () {
    test(
      'setPositionFromMoveHistory preserves full move history from startpos',
      () {
        final controller = testBuilderWorkspace();
        const fen =
            'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';
        const moves = ['e4', 'e5', 'Nf3'];

        final success = controller.board.setPositionFromMoveHistory(
          fen: fen,
          moves: moves,
        );

        expect(success, isTrue);
        expect(controller.board.currentMoveSequence, moves);
        expect(controller.board.currentMoveIndex, 2);
        expect(controller.board.fen, fen);
        assertNavigationInvariants(controller);
      },
    );

    test('setPositionFromMoveHistory supports custom starting positions', () {
      final controller = testBuilderWorkspace();
      const startingFen =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
      const fen =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';

      final success = controller.board.setPositionFromMoveHistory(
        fen: fen,
        moves: const ['Nf3'],
        startingFen: startingFen,
      );

      expect(success, isTrue);
      expect(controller.board.currentMoveSequence, ['Nf3']);
      expect(controller.board.fen, fen);
      expect(controller.board.startingFen, startingFen);
      assertNavigationInvariants(controller);
    });
  });

  group('appendNewLine', () {
    test('appendNewLine preserves custom start positions from PGN headers', () {
      final controller = testBuilderWorkspace();
      const startingFen =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
      final pgn = [
        '[Event "Training Line"]',
        '[FEN "$startingFen"]',
        '[SetUp "1"]',
        '',
        '2. Nf3 *',
      ].join('\n');

      controller.document.appendNewLine(['Nf3'], 'Custom line', pgn);

      expect(controller.document.repertoireLines, hasLength(1));
      expect(
        controller.document.repertoireLines.single.startPosition.fen,
        startingFen,
      );
    });
  });

  group('promoteVariation', () {
    /// A tree with two replies to 2.c4: mainline e6, then g6 as a sibling.
    BuilderWorkspaceController controllerWithVariation() {
      final controller = testBuilderWorkspace();
      controller.board.loadMoveHistory(['d4', 'Nf6', 'c4', 'e6']);
      controller.board.jumpToMoveIndex(2); // cursor after 2.c4
      controller.board.playMove('g6'); // adds g6 as the second child
      return controller;
    }

    test('a cursor on an earlier sibling keeps pointing at its own move', () {
      final controller = controllerWithVariation();

      // Park the cursor on the mainline e6, which sits at index 0.
      controller.board.jump(const TreePath([0, 0, 0, 0]));
      expect(controller.board.moveHistory, ['d4', 'Nf6', 'c4', 'e6']);

      // Promoting g6 shuffles it to index 0, pushing e6 down to index 1.
      controller.board.promoteVariation(const TreePath([0, 0, 0, 1]));

      // The cursor must follow e6, not stay on index 0 and silently become g6.
      expect(controller.board.moveHistory, ['d4', 'Nf6', 'c4', 'e6']);
      expect(controller.board.fen, fenAfterMoves(['d4', 'Nf6', 'c4', 'e6']));
    });

    test('a cursor on the promoted move stays on it', () {
      final controller = controllerWithVariation();
      expect(controller.board.moveHistory, ['d4', 'Nf6', 'c4', 'g6']);

      controller.board.promoteVariation(const TreePath([0, 0, 0, 1]));

      expect(controller.board.moveHistory, ['d4', 'Nf6', 'c4', 'g6']);
      expect(controller.board.path, const TreePath([0, 0, 0, 0]));
    });

    test('the opening tree cursor is re-synced after a promotion', () async {
      final controller = testBuilderWorkspace();
      await controller.document.restoreRepertoireFromPgn('''
[Event "A"]
[Result "*"]

1. d4 Nf6 2. c4 e6 *

[Event "B"]
[Result "*"]

1. d4 Nf6 2. c4 g6 *
''');

      controller.board.loadMoveHistory(['d4', 'Nf6', 'c4', 'e6']);
      controller.board.jumpToMoveIndex(2);
      controller.board.playMove('g6');
      controller.board.jump(const TreePath([0, 0, 0, 0])); // back onto e6

      controller.board.promoteVariation(const TreePath([0, 0, 0, 1]));

      // Every path mutation funnels through the syncing setter, so the
      // opening-tree cursor must agree with the move history.
      expect(controller.document.openingGraph, isNotNull);
      expect(
        controller.document.openingGraph!.currentMovePath,
        controller.board.moveHistory,
      );
    });
  });

  group('repertoireLines identity', () {
    test('appendNewLine swaps the list rather than mutating it', () {
      final controller = testBuilderWorkspace();
      controller.document.appendNewLine(['e4'], 'One', '1. e4 *');
      final first = controller.document.repertoireLines;

      controller.document.appendNewLine(['d4'], 'Two', '1. d4 *');

      // Consumers rebuild their search indexes only on identity change.
      expect(identical(controller.document.repertoireLines, first), isFalse);
      expect(first, hasLength(1));
      expect(controller.document.repertoireLines, hasLength(2));
    });

    test('appendMoveToExistingLine swaps the list rather than mutating it', () {
      final controller = testBuilderWorkspace();
      controller.document.appendNewLine(['e4'], 'One', '1. e4 *');
      final before = controller.document.repertoireLines;

      controller.document.appendMoveToExistingLine(['e4'], 'e5');

      expect(identical(controller.document.repertoireLines, before), isFalse);
      expect(before.single.moves, ['e4']);
      expect(controller.document.repertoireLines.single.moves, ['e4', 'e5']);
    });

    test('the exposed list rejects in-place mutation', () {
      final controller = testBuilderWorkspace();
      controller.document.appendNewLine(['e4'], 'One', '1. e4 *');

      expect(
        () => controller.document.repertoireLines.add(
          controller.document.repertoireLines.first,
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('navigation invariants', () {
    late BuilderWorkspaceController controller;

    setUp(() {
      controller = testBuilderWorkspace();
    });

    test('goBack at start position is identity', () {
      final before = navigationSnapshot(controller);

      controller.board.goBack();

      final after = navigationSnapshot(controller);
      expect(after.fen, before.fen);
      expect(after.moveIndex, before.moveIndex);
      expect(after.history, before.history);
      assertNavigationInvariants(controller);
    });

    test('goForward at end position is identity', () {
      controller.board.loadMoveHistory(['e4', 'e5', 'Nf3']);
      final before = navigationSnapshot(controller);

      controller.board.goForward();

      final after = navigationSnapshot(controller);
      expect(after.fen, before.fen);
      expect(after.moveIndex, before.moveIndex);
      expect(after.history, before.history);
      assertNavigationInvariants(controller);
    });

    test('goBack after playMove restores previous FEN exactly', () {
      controller.board.playMove('e4');
      final afterE4 = navigationSnapshot(controller);

      controller.board.playMove('e5');
      expect(controller.board.fen, isNot(equals(afterE4.fen)));

      controller.board.goBack();

      expect(controller.board.fen, afterE4.fen);
      expect(controller.board.currentMoveIndex, afterE4.moveIndex);
      expect(controller.board.currentMoveSequence, afterE4.history);
      // e5 still exists in the tree as a child — goForward reaches it.
      controller.board.goForward();
      expect(controller.board.currentMoveSequence, ['e4', 'e5']);
      assertNavigationInvariants(controller);
    });

    test('goToStart resets to initial FEN regardless of depth', () {
      controller.board.loadMoveHistory(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']);

      controller.board.goToStart();

      expect(controller.board.currentMoveIndex, -1);
      expect(controller.board.currentMoveSequence, isEmpty);
      expect(controller.board.fen, fenAfterMoves([]));
      assertNavigationInvariants(controller);
    });

    test('goToEnd after goToStart restores final position', () {
      const moves = ['e4', 'e5', 'Nf3', 'Nc6'];
      controller.board.loadMoveHistory(moves);

      controller.board.goToStart();
      expect(controller.board.currentMoveIndex, -1);

      controller.board.goToEnd();

      expect(controller.board.currentMoveIndex, moves.length - 1);
      expect(controller.board.currentMoveSequence, moves);
      expect(controller.board.fen, fenAfterMoves(moves));
      assertNavigationInvariants(controller);
    });

    test('goBack and goForward are inverses for every move in a sequence', () {
      const moves = ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5'];
      for (final san in moves) {
        controller.board.playMove(san);
        assertNavigationInvariants(controller);
      }
      final endSnapshot = navigationSnapshot(controller);

      for (var i = 0; i < moves.length; i++) {
        controller.board.goBack();
        assertNavigationInvariants(controller);
      }
      expect(controller.board.currentMoveIndex, -1);
      expect(controller.board.fen, fenAfterMoves([]));

      for (var i = 0; i < moves.length; i++) {
        controller.board.goForward();
        assertNavigationInvariants(controller);
        expect(controller.board.currentMoveSequence, moves.sublist(0, i + 1));
      }

      final restored = navigationSnapshot(controller);
      expect(restored.fen, endSnapshot.fen);
      expect(restored.moveIndex, endSnapshot.moveIndex);
      expect(restored.history, endSnapshot.history);
    });

    test('jumpToMoveIndex with out-of-bounds index is identity', () {
      controller.board.loadMoveHistory(['e4', 'e5', 'Nf3']);

      for (final badIndex in [-2, 3, 10]) {
        final before = navigationSnapshot(controller);
        controller.board.jumpToMoveIndex(badIndex);
        final after = navigationSnapshot(controller);
        expect(after.fen, before.fen);
        expect(after.moveIndex, before.moveIndex);
        expect(after.history, before.history);
      }
      assertNavigationInvariants(controller);
    });
  });

  group('move playing', () {
    late BuilderWorkspaceController controller;

    setUp(() {
      controller = testBuilderWorkspace();
    });

    test(
      'playMove advances FEN, increments moveIndex, extends history by exactly one',
      () {
        final before = navigationSnapshot(controller);

        controller.board.playMove('e4');

        expect(controller.board.moveHistory.length, before.history.length + 1);
        expect(controller.board.currentMoveIndex, before.moveIndex + 1);
        expect(controller.board.moveHistory.last, 'e4');
        expect(controller.board.fen, fenAfterMoves(['e4']));
        expect(controller.board.fen, isNot(equals(before.fen)));
        assertNavigationInvariants(controller);
      },
    );

    test('playMove after goBack creates variation', () {
      controller.board.loadMoveHistory(['e4', 'e5', 'Nf3']);
      controller.board.goBack();
      controller.board.goBack();
      expect(controller.board.currentMoveIndex, 0);

      controller.board.playMove('c5');

      // c5 is a new variation; cursor is now on the e4 → c5 line.
      expect(controller.board.currentMoveSequence, ['e4', 'c5']);
      expect(controller.board.currentMoveIndex, 1);
      expect(controller.board.fen, fenAfterMoves(['e4', 'c5']));
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

        await controller.document.restoreRepertoireFromPgn(pgn);
        controller.board.navigateToLineMove(['e4']);
        assertNavigationInvariants(controller);

        final treePathBefore = controller.document.openingGraph!.currentNode
            .getMovePath();
        expect(treePathBefore, ['e4']);

        controller.board.userSelectedTreeMove('e5');

        expect(controller.board.moveHistory, ['e4', 'e5']);
        expect(controller.board.currentMoveIndex, 1);
        expect(controller.board.currentMoveSequence, ['e4', 'e5']);
        expect(controller.document.openingGraph!.currentNode.getMovePath(), [
          'e4',
          'e5',
        ]);
        expect(controller.board.fen, fenAfterMoves(['e4', 'e5']));
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

        await controller.document.restoreRepertoireFromPgn(pgn);
        controller.board.goToStart();
        controller.board.playMove('d4');
        controller.board.playMove('c5');
        controller.board.playMove('e3');
        expect(controller.document.openingGraph!.inBook, isFalse);
        expect(
          controller.document.openingGraph!.continuations.map((g) => g.move),
          contains('Nf6'),
        );

        controller.board.userSelectedTreeMove('Nf6');

        expect(controller.board.currentMoveSequence, ['d4', 'c5', 'e3', 'Nf6']);
        expect(controller.document.openingGraph!.inBook, isTrue);
        expect(controller.board.fen, fenAfterMoves(['d4', 'c5', 'e3', 'Nf6']));
        assertNavigationInvariants(controller);
      },
    );

    test(
      'consecutive playMove calls produce monotonically increasing move indices',
      () {
        const moves = ['e4', 'e5', 'Nf3', 'Nc6'];
        var previousIndex = controller.board.currentMoveIndex;

        for (final san in moves) {
          controller.board.playMove(san);
          expect(controller.board.currentMoveIndex, greaterThan(previousIndex));
          previousIndex = controller.board.currentMoveIndex;
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
        final controller = testBuilderWorkspace();

        const newPgn = '''
// Color: White

[Event "Fresh line"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 c5 2. Nf3
''';

        await controller.document.restoreRepertoireFromPgn(newPgn);

        expect(controller.document.repertoireLines, hasLength(1));
        expect(controller.document.repertoireLines.single.moves, [
          'e4',
          'c5',
          'Nf3',
        ]);
        expect(controller.document.openingGraph, isNotNull);
      },
    );

    test(
      'restoreRepertoireFromPgn without Root comment resets navigation to start',
      () async {
        final controller = testBuilderWorkspace();
        controller.board.loadMoveHistory(['d4', 'd5', 'c4']);

        const newPgn = '''
// Color: White

[Event "Fresh line"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 c5 2. Nf3
''';

        await controller.document.restoreRepertoireFromPgn(newPgn);

        expect(controller.board.currentMoveIndex, -1);
        expect(controller.board.currentMoveSequence, isEmpty);
      },
    );

    test(
      'restoreRepertoireFromPgn with empty syncPath resets navigation to start',
      () async {
        final controller = testBuilderWorkspace();
        controller.board.loadMoveHistory(['d4', 'd5', 'c4']);

        const newPgn = '''
// Color: White

[Event "Fresh line"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 c5 2. Nf3
''';

        await controller.document.restoreRepertoireFromPgn(
          newPgn,
          syncPath: [],
        );

        expect(controller.document.repertoireLines.single.moves, [
          'e4',
          'c5',
          'Nf3',
        ]);
        expect(controller.board.currentMoveIndex, -1);
        expect(controller.board.currentMoveSequence, isEmpty);
        expect(controller.board.fen, kStandardStartFen);
        assertNavigationInvariants(controller);
      },
    );

    test('setRepertoireColor flips side and resets navigation state', () async {
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(
        RepertoireMetadata(
          name: 'Test',
          filePath: filePath,
          lastModified: DateTime(2026, 1, 1),
        ),
      );
      controller.board.loadMoveHistory(['e4', 'e5', 'Nf3']);
      expect(controller.board.currentMoveIndex, 2);

      await controller.document.setRepertoireColor(false);

      expect(controller.document.isRepertoireWhite, isFalse);
      expect(controller.document.needsColorSelection, isFalse);
      expect(controller.board.currentMoveIndex, -1);
      expect(controller.board.currentMoveSequence, isEmpty);
      expect(controller.document.repertoireLines.single.color, 'black');
      assertNavigationInvariants(controller);
    });

    test('loadMoveHistory with empty history produces start position FEN', () {
      final controller = testBuilderWorkspace();

      controller.board.loadMoveHistory([]);

      expect(controller.board.moveHistory, isEmpty);
      expect(controller.board.currentMoveIndex, -1);
      expect(controller.board.fen, kStandardStartFen);
      assertNavigationInvariants(controller);
    });
  });

  group('saved root position', () {
    test('defaults to the starting position when no root is saved', () {
      final controller = testBuilderWorkspace();

      expect(
        controller.board.rootMoveSans(controller.document.rootMoves),
        isEmpty,
      );
      expect(
        controller.board.rootFen(controller.document.rootMoves),
        kStandardStartFen,
      );
      expect(
        controller.board.isAtRootPosition(controller.document.rootMoves),
        isTrue,
      );

      controller.board.loadMoveHistory(['d4', 'Nf6']);
      expect(
        controller.board.isAtRootPosition(controller.document.rootMoves),
        isFalse,
      );
    });

    test('follows the // Root: header and tracks the cursor', () async {
      final controller = testBuilderWorkspace();
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

      await controller.document.restoreRepertoireFromPgn(pgnWithRoot);

      const rootSans = ['d4', 'Nf6', 'c4', 'c5'];
      expect(
        controller.board.rootMoveSans(controller.document.rootMoves),
        rootSans,
      );
      expect(
        controller.board.rootFen(controller.document.rootMoves),
        fenAfterMoves(rootSans),
      );

      // Loading navigated to the root; leaving it must be detected.
      expect(
        controller.board.isAtRootPosition(controller.document.rootMoves),
        isTrue,
      );
      controller.board.goToStart();
      expect(
        controller.board.isAtRootPosition(controller.document.rootMoves),
        isFalse,
      );
    });
  });

  group('state machine properties', () {
    late BuilderWorkspaceController controller;

    setUp(() {
      controller = testBuilderWorkspace();
    });

    test('no operation changes FEN without also updating moveIndex', () {
      controller.board.loadMoveHistory(['e4', 'e5', 'Nf3', 'Nc6']);

      void expectFenIndexCoupled(void Function() operation) {
        final fenBefore = controller.board.fen;
        final indexBefore = controller.board.currentMoveIndex;
        operation();
        if (controller.board.fen == fenBefore) {
          expect(controller.board.currentMoveIndex, indexBefore);
        }
      }

      expectFenIndexCoupled(controller.board.goBack);
      expectFenIndexCoupled(controller.board.goBack);
      expectFenIndexCoupled(controller.board.goForward);
      expectFenIndexCoupled(() => controller.board.jumpToMoveIndex(1));
      expectFenIndexCoupled(controller.board.goToStart);
      expectFenIndexCoupled(controller.board.goToEnd);
      expectFenIndexCoupled(() => controller.board.jumpToMoveIndex(99));
      assertNavigationInvariants(controller);
    });

    test(
      'currentMoveSequence length equals moveIndex plus one after play and navigate',
      () {
        const moves = ['e4', 'e5', 'Nf3'];
        for (final san in moves) {
          controller.board.playMove(san);
          assertNavigationInvariants(controller);
        }

        controller.board.goBack();
        assertNavigationInvariants(controller);

        controller.board.goForward();
        assertNavigationInvariants(controller);

        controller.board.goToStart();
        assertNavigationInvariants(controller);

        controller.board.goToEnd();
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
      final decoder = GatedRepertoireDecoder();
      final controller = testBuilderWorkspace(decoder: decoder);
      decoder.beforeBuild = () async {
        if (!firstReached.isCompleted) firstReached.complete();
        await gate.future;
      };

      final first = controller.document.setRepertoire(
        RepertoireMetadata(
          filePath: a.path,
          name: 'A',
          lastModified: DateTime.now(),
        ),
      );
      await firstReached.future.timeout(const Duration(seconds: 5));
      decoder.beforeBuild = null;

      await controller.document.setRepertoire(
        RepertoireMetadata(
          filePath: b.path,
          name: 'B',
          lastModified: DateTime.now(),
        ),
      );
      gate.complete();
      await first;

      expect(controller.document.currentRepertoire?.filePath, b.path);
      expect(controller.document.repertoirePgn, contains('1. d4'));
      expect(controller.document.repertoirePgn, isNot(contains('1. e4')));
    });
  });
}
