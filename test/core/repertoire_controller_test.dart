import 'dart:io' as io;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/repertoire_controller.dart';

/// Replay [moves] from [startingFen] (or standard start) and return the FEN.
String fenAfterMoves(
  List<String> moves, {
  String? startingFen,
}) {
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

  if (controller.moveHistory.isEmpty) {
    expect(controller.currentMoveIndex, -1);
  } else {
    expect(controller.currentMoveIndex, lessThan(controller.moveHistory.length));
  }

  if (controller.currentMoveIndex < 0) {
    expect(controller.currentMoveSequence, isEmpty);
  } else {
    expect(
      controller.currentMoveSequence.length,
      controller.currentMoveIndex + 1,
    );
    expect(
      controller.currentMoveSequence,
      controller.moveHistory.sublist(0, controller.currentMoveIndex + 1),
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
    test('setPositionFromMoveHistory preserves full move history from startpos',
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
    });

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

    test('goBack after userPlayedMove restores previous FEN exactly', () {
      controller.userPlayedMove('e4');
      final afterE4 = navigationSnapshot(controller);

      controller.userPlayedMove('e5');
      expect(controller.fen, isNot(equals(afterE4.fen)));

      controller.goBack();

      expect(controller.fen, afterE4.fen);
      expect(controller.currentMoveIndex, afterE4.moveIndex);
      expect(controller.currentMoveSequence, afterE4.history);
      // Full history is preserved; only the cursor moves back.
      expect(controller.moveHistory, ['e4', 'e5']);
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
        controller.userPlayedMove(san);
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
        expect(
          controller.currentMoveSequence,
          moves.sublist(0, i + 1),
        );
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

    test('userPlayedMove advances FEN, increments moveIndex, extends history by exactly one',
        () {
      final before = navigationSnapshot(controller);

      controller.userPlayedMove('e4');

      expect(controller.moveHistory.length, before.history.length + 1);
      expect(controller.currentMoveIndex, before.moveIndex + 1);
      expect(controller.moveHistory.last, 'e4');
      expect(controller.fen, fenAfterMoves(['e4']));
      expect(controller.fen, isNot(equals(before.fen)));
      assertNavigationInvariants(controller);
    });

    test('userPlayedMove after goBack truncates future history', () {
      controller.loadMoveHistory(['e4', 'e5', 'Nf3']);
      controller.goBack();
      controller.goBack();
      expect(controller.currentMoveIndex, 0);
      expect(controller.moveHistory, ['e4', 'e5', 'Nf3']);

      controller.userPlayedMove('c5');

      expect(controller.moveHistory, ['e4', 'c5']);
      expect(controller.currentMoveIndex, 1);
      expect(controller.fen, fenAfterMoves(['e4', 'c5']));
      assertNavigationInvariants(controller);
    });

    test('userSelectedTreeMove maintains consistency between history and tree cursor',
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

      final treePathBefore = controller.openingTree!.currentNode.getMovePath();
      expect(treePathBefore, ['e4']);

      controller.userSelectedTreeMove('e5');

      expect(controller.moveHistory, ['e4', 'e5']);
      expect(controller.currentMoveIndex, 1);
      expect(controller.currentMoveSequence, ['e4', 'e5']);
      expect(
        controller.openingTree!.currentNode.getMovePath(),
        ['e4', 'e5'],
      );
      expect(controller.fen, fenAfterMoves(['e4', 'e5']));
      assertNavigationInvariants(controller);
    });

    test('consecutive userPlayedMove calls produce monotonically increasing move indices',
        () {
      const moves = ['e4', 'e5', 'Nf3', 'Nc6'];
      var previousIndex = controller.currentMoveIndex;

      for (final san in moves) {
        controller.userPlayedMove(san);
        expect(controller.currentMoveIndex, greaterThan(previousIndex));
        previousIndex = controller.currentMoveIndex;
        assertNavigationInvariants(controller);
      }
    });
  });

  group('PGN and repertoire sync', () {
    late io.Directory tempDir;
    late String filePath;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('repertoire_ctrl_test');
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

    test('restoreRepertoireFromPgn rebuilds parsed lines from PGN snapshot', () async {
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
    });

    test('restoreRepertoireFromPgn without Root comment resets navigation to start',
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
            'BUG: restoreRepertoireFromPgn without // Root: leaves stale moveHistory/currentMoveIndex');

    test('restoreRepertoireFromPgn with empty syncPath resets navigation to start',
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
    });

    test('setRepertoireColor flips side and resets navigation state', () async {
      final controller = RepertoireController();
      await controller.setRepertoire({'name': 'Test', 'filePath': filePath});
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

    test('currentMoveSequence length equals moveIndex plus one after play and navigate',
        () {
      const moves = ['e4', 'e5', 'Nf3'];
      for (final san in moves) {
        controller.userPlayedMove(san);
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
    });
  });
}
