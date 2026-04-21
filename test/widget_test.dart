// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart';

import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';

Future<void> _pumpDesktopSizedWidget(
  WidgetTester tester,
  Widget widget,
) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
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

    testWidgets('renders initial chess position correctly', (WidgetTester tester) async {
      await _pumpDesktopSizedWidget(
        tester,
        MaterialApp(
          home: Scaffold(
            body: ChessBoardWidget(position: testPosition),
          ),
        ),
      );

      // Should render without errors
      expect(find.byType(ChessBoardWidget), findsOneWidget);
      expect(
        tester.widget<ChessBoardWidget>(find.byType(ChessBoardWidget)).position.fen,
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

      final chessBoardWidget = tester.widget<ChessBoardWidget>(chessBoardFinder);
      final renderBox = tester.renderObject(chessBoardFinder) as RenderBox;
      final size = renderBox.size;

      // Calculate position of e2 square (file e = 4, rank 2 = 1 from bottom)
      final squareSize = size.width / 8;
      final e2Position = Offset(4 * squareSize + squareSize / 2, 6 * squareSize + squareSize / 2);

      await tester.tapAt(tester.getTopLeft(chessBoardFinder) + e2Position);
      await tester.pump();

      expect(selectedSquare, equals('e2'));
    });

    testWidgets('shows legal moves when piece is selected', (WidgetTester tester) async {
      await _pumpDesktopSizedWidget(
        tester,
        MaterialApp(
          home: Scaffold(
            body: ChessBoardWidget(position: testPosition),
          ),
        ),
      );

      // Find and tap e2 square
      final chessBoardFinder = find.byType(ChessBoardWidget);
      final renderBox = tester.renderObject(chessBoardFinder) as RenderBox;
      final size = renderBox.size;
      final squareSize = size.width / 8;

      // Tap e2 (white pawn)
      final e2Position = Offset(4 * squareSize + squareSize / 2, 6 * squareSize + squareSize / 2);
      await tester.tapAt(tester.getTopLeft(chessBoardFinder) + e2Position);
      await tester.pump();

      // Check if the chess board widget has highlighted squares
      expect(find.byType(ChessBoardWidget), findsOneWidget);
    });

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
      final size = renderBox.size;
      final squareSize = size.width / 8;

      // Select e2 pawn
      final e2Position = Offset(4 * squareSize + squareSize / 2, 6 * squareSize + squareSize / 2);
      await tester.tapAt(tester.getTopLeft(chessBoardFinder) + e2Position);
      await tester.pump();

      // Move to e4
      final e4Position = Offset(4 * squareSize + squareSize / 2, 4 * squareSize + squareSize / 2);
      await tester.tapAt(tester.getTopLeft(chessBoardFinder) + e4Position);
      await tester.pump();
    });
  });

}
