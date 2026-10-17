import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_screen.dart';
import 'package:chess_auto_prep/features/bughouse/lab_engine.dart';
import 'package:chess_auto_prep/features/bughouse/lab_lines.dart';
import 'package:chess_auto_prep/features/bughouse/pocket.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show Role, Side, Square;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

/// The Bughouse screen over a scripted engine: promotion, the engine lines'
/// move tokens with their floating boards, and the right-button menus.
void main() {
  late BughouseLab lab;
  late ScriptedHivemind hivemind;
  late LabEngine engine;

  // Made inside each test, in its fake time: a future made outside it
  // would complete where the test's pumps never reach.
  void build() {
    lab = BughouseLab();
    hivemind = ScriptedHivemind();
    engine = LabEngine(
      lab: lab,
      passes: const [800],
      startEngine: () async => HivemindStarted(hivemind),
    );
    addTearDown(() {
      engine.dispose();
      lab.dispose();
    });
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: BughouseScreen(lab: lab, engine: engine),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A's team answers with [pv]; the other team as the script does.
  Future<void> engineSays(WidgetTester tester, List<JointMove> pv) async {
    hivemind.answer = (question) => question.team == Team.ab
        ? HivemindSearched(
            best: pv.first,
            lines: [JointLine(rank: 1, cp: -200, nodes: 800, pv: pv)],
          )
        : firstMoves(question);
    engine
      ..open()
      ..toggle();
    await tester.pumpAndSettle();
  }

  Future<TestGesture> mouse(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    return mouse;
  }

  List<String> copies(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return copied;
  }

  Future<void> rightClick(WidgetTester tester, Finder finder) async {
    await tester.tap(finder, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  group('promotion', () {
    const promoting = 'k7/4P3/8/8/8/8/8/K7[] w - - 0 1';

    testWidgets('a pawn on the last rank waits for the piece it becomes', (
      tester,
    ) async {
      build();
      lab.loadDualFen(promoting);
      await pump(tester);
      await tester.tapAt(squareCenter(tester, BoardNumber.one, Square.e7));
      await tester.pump();
      await tester.tapAt(squareCenter(tester, BoardNumber.one, Square.e8));
      await tester.pump();
      expect(lab.line.moves, isEmpty);
      expect(pending(tester, BoardNumber.one), isNotNull);
      // Down the file from the last rank: queen, knight, rook, bishop.
      await tester.tapAt(squareCenter(tester, BoardNumber.one, Square.e7));
      await tester.pumpAndSettle();
      expect(lab.line.moves.single.san, 'e8=N');
      expect(lab.position.one.board.pieceAt(Square.e8)?.role, Role.knight);
    });

    testWidgets('a promotion put away plays nothing', (tester) async {
      build();
      lab.loadDualFen(promoting);
      await pump(tester);
      final before = lab.position.dualFen;
      await tester.tapAt(squareCenter(tester, BoardNumber.one, Square.e7));
      await tester.pump();
      await tester.tapAt(squareCenter(tester, BoardNumber.one, Square.e8));
      await tester.pump();
      await tester.tapAt(squareCenter(tester, BoardNumber.one, Square.a4));
      await tester.pumpAndSettle();
      expect(pending(tester, BoardNumber.one), isNull);
      expect(lab.line.moves, isEmpty);
      expect(lab.position.dualFen, before);
    });

    testWidgets('board 2 promotes through the same chooser', (tester) async {
      build();
      lab
        ..showBoards(LabBoards.two)
        ..loadDualFen(
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1|'
          'k7/8/8/8/8/8/4p3/K7[] b - - 0 1',
        );
      await pump(tester);
      await tester.tapAt(squareCenter(tester, BoardNumber.two, Square.e2));
      await tester.pump();
      await tester.tapAt(squareCenter(tester, BoardNumber.two, Square.e1));
      await tester.pump();
      expect(pending(tester, BoardNumber.two), isNotNull);
      // Black is below on board 2: up the file, queen, knight, rook.
      await tester.tapAt(squareCenter(tester, BoardNumber.two, Square.e3));
      await tester.pumpAndSettle();
      expect(lab.line.of(BoardNumber.two).single.san, 'e1=R+');
    });
  });

  group('engine lines', () {
    testWidgets('one board: each move floats board 1 with its hands and '
        'plays the line up to it; the row never changes size', (tester) async {
      build();
      await pump(tester);
      await engineSays(tester, const [
        JointMove('e2e4', null),
        JointMove('e7e5', null),
        JointMove('g1f3', null),
      ]);
      expect(find.text('1. e4'), findsOneWidget);
      // One board's moves are one game: nothing parts them.
      expect(find.text(' · '), findsNothing);
      final rows = tester.getSize(find.byType(LabLineRows));
      final pointer = await mouse(tester);
      await pointer.moveTo(tester.getCenter(find.text('e5')));
      await tester.pump(previewDelay * 2);
      final preview = tester.widget<BughousePreviewBoard>(
        find.byType(BughousePreviewBoard),
      );
      expect(preview.lastMove, 'e7e5');
      expect(preview.position.turn, Side.white);
      expect(find.byType(StaticChessboard), findsOneWidget);
      expect(tester.getSize(find.byType(LabLineRows)), rows);
      // The row still draws its first move on the board.
      expect(lab.preview.value, {BoardNumber.one: 'e2e4'});
      await tester.tap(find.text('e5'));
      await tester.pumpAndSettle();
      expect(lab.line.moves.map((m) => m.san), ['e4', 'e5']);
      expect(find.byType(BughousePreviewBoard), findsNothing);
    });

    testWidgets('two boards: a move floats the board it is on and plays the '
        'line up to it', (tester) async {
      build();
      lab.showBoards(LabBoards.two);
      await pump(tester);
      await engineSays(tester, const [
        JointMove('e2e4', null),
        JointMove('e7e5', 'd2d4'),
      ]);
      final pointer = await mouse(tester);
      await pointer.moveTo(tester.getCenter(find.text('D d4')));
      await tester.pump(previewDelay * 2);
      final preview = tester.widget<BughousePreviewBoard>(
        find.byType(BughousePreviewBoard),
      );
      expect(preview.lastMove, 'd2d4');
      expect(preview.position.board.pieceAt(Square.d4)?.role, Role.pawn);
      // Board 2 has Black, B, below.
      expect(preview.orientation, Side.black);
      await tester.tap(find.text('D d4'));
      await tester.pumpAndSettle();
      expect(lab.line.moves.map((m) => m.san), ['e4', 'e5', 'd4']);
    });

    testWidgets('the right button copies an engine line as PGN', (
      tester,
    ) async {
      build();
      final copied = copies(tester);
      await pump(tester);
      await engineSays(tester, const [
        JointMove('e2e4', null),
        JointMove('e7e5', null),
      ]);
      await rightClick(tester, find.text('1. e4'));
      await tester.tap(find.text('Copy line PGN'));
      await tester.pumpAndSettle();
      expect(copied, ['[Variant "Crazyhouse"]\n\n1. e4 e5 *']);
    });
  });

  group('move list', () {
    testWidgets('the right button copies the line and the FEN, and deletes', (
      tester,
    ) async {
      build();
      final copied = copies(tester);
      lab
        ..play(BoardNumber.one, 'e2e4')
        ..play(BoardNumber.one, 'e7e5')
        ..play(BoardNumber.one, 'g1f3');
      await pump(tester);
      await rightClick(tester, find.text('e5'));
      expect(find.text('Copy dual FEN'), findsNothing);
      await tester.tap(find.text('Copy line PGN'));
      await tester.pumpAndSettle();
      await rightClick(tester, find.text('e5'));
      await tester.tap(find.text('Copy FEN'));
      await tester.pumpAndSettle();
      expect(copied, [
        '[Variant "Crazyhouse"]\n\n1. e4 e5 *',
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR[] w KQkq - 0 2',
      ]);
      await rightClick(tester, find.text('e5'));
      await tester.tap(find.text('Delete from here'));
      await tester.pumpAndSettle();
      expect(lab.line.moves.map((m) => m.san), ['e4']);
    });

    testWidgets('two boards: the dual FEN after a move, and BPGN', (
      tester,
    ) async {
      build();
      final copied = copies(tester);
      lab
        ..showBoards(LabBoards.two)
        ..play(BoardNumber.one, 'e2e4')
        ..play(BoardNumber.two, 'd2d4');
      await pump(tester);
      await rightClick(tester, find.text('d4'));
      await tester.tap(find.text('Copy line PGN'));
      await tester.pumpAndSettle();
      await rightClick(tester, find.text('d4'));
      await tester.tap(find.text('Copy dual FEN'));
      await tester.pumpAndSettle();
      expect(copied, ['1A. e4 1B. d4', lab.position.dualFen]);
    });

    testWidgets('PgUp and PgDn go to the ends, F flips', (tester) async {
      build();
      lab
        ..play(BoardNumber.one, 'e2e4')
        ..play(BoardNumber.one, 'e7e5');
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(lab.line.upto(BoardNumber.one), 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(lab.line.upto(BoardNumber.one), 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(lab.flipped, isTrue);
    });
  });
}

/// The move waiting on [board] for the piece a pawn becomes.
Object? pending(WidgetTester tester, BoardNumber board) => tester
    .widget<Chessboard>(
      find.byType(Chessboard).at(board == BoardNumber.one ? 0 : 1),
    )
    .controller
    .pendingPromotion;

/// The middle of [square] on [board], as the board is drawn now.
Offset squareCenter(WidgetTester tester, BoardNumber board, Square square) {
  final boards = find.byType(Chessboard);
  final chessboard = boards.at(board == BoardNumber.one ? 0 : 1);
  final widget = tester.widget<Chessboard>(chessboard);
  final topLeft = tester.getTopLeft(chessboard);
  final size = tester.getSize(chessboard).width / 8;
  final white = widget.orientation == Side.white;
  final file = white ? square.file : 7 - square.file;
  final rank = white ? 7 - square.rank : square.rank;
  return topLeft + Offset((file + 0.5) * size, (rank + 0.5) * size);
}
