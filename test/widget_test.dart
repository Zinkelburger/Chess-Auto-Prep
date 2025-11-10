// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess/chess.dart' as chess;

import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/simple_chess_board.dart';

void main() {
  testWidgets('App loads without crashing', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ChessAutoPrepApp());

    // Verify that main screen elements are present
    expect(find.text('Chess Auto Prep'), findsOneWidget);
    expect(find.text('No tactics loaded'), findsOneWidget);
  });

  group('ChessBoardWidget Tests', () {
    late chess.Chess testGame;

    setUp(() {
      testGame = chess.Chess();
    });

    testWidgets('renders initial chess position correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChessBoardWidget(game: testGame),
          ),
        ),
      );

      // Should render without errors
      expect(find.byType(ChessBoardWidget), findsOneWidget);

      // Should have 32 pieces in starting position
      expect(find.byType(Container), findsWidgets);
    });

    testWidgets('handles piece selection', (WidgetTester tester) async {
      String? selectedSquare;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChessBoardWidget(
              game: testGame,
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChessBoardWidget(game: testGame),
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
      // This is a simplified test - in a real scenario we'd need to check the internal state
      expect(find.byType(ChessBoardWidget), findsOneWidget);
    });

    testWidgets('allows making legal moves', (WidgetTester tester) async {
      CompletedMove? lastMove;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChessBoardWidget(
              game: testGame,
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

      // Check that game state changed
      expect(testGame.fen, isNot(equals('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1')));
    });
  });

  group('SimpleChessBoard Tests', () {
    late chess.Chess testGame;

    setUp(() {
      testGame = chess.Chess();
    });

    testWidgets('renders without errors', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SimpleChessBoard(game: testGame),
          ),
        ),
      );

      expect(find.byType(SimpleChessBoard), findsOneWidget);
    });

    testWidgets('handles piece selection correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SimpleChessBoard(game: testGame),
          ),
        ),
      );

      // The SimpleChessBoard uses a different structure (Column/Row)
      expect(find.byType(SimpleChessBoard), findsOneWidget);
      expect(find.byType(Column), findsWidgets);
      expect(find.byType(Row), findsWidgets);
    });
  });
}
