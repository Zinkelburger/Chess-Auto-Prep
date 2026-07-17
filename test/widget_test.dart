// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';

Future<void> _pumpDesktopSizedWidget(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(widget);
  // Avoid pumpAndSettle: MainScreen / tactics browse show an indeterminate
  // CircularProgressIndicator while loading, which never "settles".
  // Extra pumps: first visit shows a one-frame loading placeholder, then
  // constructs the tactics screen on the next frame.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Center of [square] in board-local coordinates (e.g. `e2`), not flipped.
Offset _boardLocalCenterForSquare(String square, double squareSize) {
  final file = square.codeUnitAt(0) - 97;
  final rank = int.parse(square[1]);
  final col = file;
  final row = 8 - rank;
  return Offset((col + 0.5) * squareSize, (row + 0.5) * squareSize);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App loads without crashing', (WidgetTester tester) async {
    await _pumpDesktopSizedWidget(tester, const ChessAutoPrepApp());

    // Verify that main screen elements are present
    expect(find.text('Tactics'), findsOneWidget);
    expect(find.text('Import Games'), findsOneWidget);
  });

  group('ChessBoardWidget Tests', () {
    late Position testPosition;

    setUp(() {
      testPosition = Chess.initial;
    });

    testWidgets('renders initial chess position correctly', (
      WidgetTester tester,
    ) async {
      await _pumpDesktopSizedWidget(
        tester,
        MaterialApp(
          home: Scaffold(body: ChessBoardWidget(position: testPosition)),
        ),
      );

      // Should render without errors
      expect(find.byType(ChessBoardWidget), findsOneWidget);
      expect(
        tester
            .widget<ChessBoardWidget>(find.byType(ChessBoardWidget))
            .position
            .fen,
        contains('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR'),
      );
    });

    testWidgets('handles piece selection', (WidgetTester tester) async {
      String? selectedSquare;

      await _pumpDesktopSizedWidget(
        tester,
        MaterialApp(
          home: Scaffold(
            body: ChessBoardWidget(
              position: testPosition,
              onPieceSelected: (square) {
                selectedSquare = square;
              },
            ),
          ),
        ),
      );

      // Tap on e2 square (white pawn)
      final chessBoardFinder = find.byType(ChessBoardWidget);
      expect(chessBoardFinder, findsOneWidget);

      final renderBox = tester.renderObject(chessBoardFinder) as RenderBox;
      final size = renderBox.size;
      final squareSize = size.width / 8;
      final e2Position = _boardLocalCenterForSquare('e2', squareSize);

      await tester.tapAt(tester.getTopLeft(chessBoardFinder) + e2Position);
      await tester.pump();

      expect(selectedSquare, equals('e2'));
    });

    testWidgets(
      'does not complete a move when destination is illegal after selection',
      (WidgetTester tester) async {
        var moveCount = 0;

        await _pumpDesktopSizedWidget(
          tester,
          MaterialApp(
            home: Scaffold(
              body: ChessBoardWidget(
                position: testPosition,
                onMove: (_) => moveCount++,
              ),
            ),
          ),
        );

        final chessBoardFinder = find.byType(ChessBoardWidget);
        final renderBox = tester.renderObject(chessBoardFinder) as RenderBox;
        final squareSize = renderBox.size.width / 8;
        final origin = tester.getTopLeft(chessBoardFinder);

        await tester.tapAt(
          origin + _boardLocalCenterForSquare('e2', squareSize),
        );
        await tester.pump();
        // e5 is empty but not a legal single step for the e2 pawn.
        await tester.tapAt(
          origin + _boardLocalCenterForSquare('e5', squareSize),
        );
        await tester.pump();

        expect(moveCount, 0);
      },
    );

    testWidgets('allows making legal moves', (WidgetTester tester) async {
      CompletedMove? lastMove;

      await _pumpDesktopSizedWidget(
        tester,
        MaterialApp(
          home: Scaffold(
            body: ChessBoardWidget(
              position: testPosition,
              onMove: (move) {
                lastMove = move;
              },
            ),
          ),
        ),
      );

      final chessBoardFinder = find.byType(ChessBoardWidget);
      final renderBox = tester.renderObject(chessBoardFinder) as RenderBox;
      final squareSize = renderBox.size.width / 8;
      final origin = tester.getTopLeft(chessBoardFinder);

      await tester.tapAt(origin + _boardLocalCenterForSquare('e2', squareSize));
      await tester.pump();
      await tester.tapAt(origin + _boardLocalCenterForSquare('e4', squareSize));
      await tester.pump();

      expect(lastMove, isNotNull);
      expect(lastMove!.from, 'e2');
      expect(lastMove!.to, 'e4');
      expect(lastMove!.uci, 'e2e4');
      expect(lastMove!.san, 'e4');
    });
  });
}
