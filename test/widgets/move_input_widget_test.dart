import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/training/move_input_widget.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MoveInputWidget', () {
    late Position startPosition;

    setUp(() {
      startPosition = Chess.initial;
    });

    Widget buildWidget({
      Position? position,
      bool enabled = true,
      void Function(CompletedMove)? onMove,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: MoveInputWidget(
            position: position ?? startPosition,
            enabled: enabled,
            onMove: onMove ?? (_) {},
          ),
        ),
      );
    }

    testWidgets('renders text field with hint', (tester) async {
      await tester.pumpWidget(buildWidget());
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Type a move…'), findsOneWidget);
    });

    testWidgets('disabled when enabled=false', (tester) async {
      await tester.pumpWidget(buildWidget(enabled: false));
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.enabled, isFalse);
    });

    testWidgets('SAN pawn move auto-submits', (tester) async {
      CompletedMove? received;
      await tester.pumpWidget(buildWidget(onMove: (m) => received = m));

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'e4');
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.san, 'e4');
      expect(received!.uci, 'e2e4');
    });

    testWidgets('SAN knight move auto-submits', (tester) async {
      CompletedMove? received;
      await tester.pumpWidget(buildWidget(onMove: (m) => received = m));

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Nf3');
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.san, 'Nf3');
    });

    testWidgets('UCI move auto-submits', (tester) async {
      CompletedMove? received;
      await tester.pumpWidget(buildWidget(onMove: (m) => received = m));

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'g1f3');
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.san, 'Nf3');
      expect(received!.uci, 'g1f3');
    });

    testWidgets('case-insensitive SAN works', (tester) async {
      CompletedMove? received;
      await tester.pumpWidget(buildWidget(onMove: (m) => received = m));

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'nf3');
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.san, 'Nf3');
    });

    testWidgets('invalid input shows no matching move', (tester) async {
      CompletedMove? received;
      await tester.pumpWidget(buildWidget(onMove: (m) => received = m));

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'z9');
      await tester.pump();

      expect(received, isNull);
    });

    testWidgets('field clears after successful move', (tester) async {
      await tester.pumpWidget(buildWidget(onMove: (_) {}));

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'e4');
      await tester.pump();

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, isEmpty);
    });

    testWidgets('partial input does not submit', (tester) async {
      CompletedMove? received;
      await tester.pumpWidget(buildWidget(onMove: (m) => received = m));

      await tester.tap(find.byType(TextField));
      await tester.pump();

      // "e" alone is a valid prefix but not a complete move
      await tester.enterText(find.byType(TextField), 'e');
      await tester.pump();

      expect(received, isNull);
    });

    testWidgets('capture without x works (Nf6 matches Nxf6)', (tester) async {
      // Position where Nxf6 is a capture
      final pos = Chess.fromSetup(
        Setup.parseFen(
          'rnbqkb1r/pppppppp/5n2/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2',
        ),
      );
      // White has e4, black has Nf6. White can't Nxf6 here.
      // Use a position where a capture exists:
      // After 1.e4 d5 — white can play exd5
      final pos2 = Chess.fromSetup(
        Setup.parseFen(
          'rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2',
        ),
      );

      CompletedMove? received;
      await tester.pumpWidget(
        buildWidget(position: pos2, onMove: (m) => received = m),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();

      // Type "ed5" instead of "exd5" — should still match
      await tester.enterText(find.byType(TextField), 'ed5');
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.san, 'exd5');
    });

    testWidgets('capture with x also works (exd5)', (tester) async {
      final pos = Chess.fromSetup(
        Setup.parseFen(
          'rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2',
        ),
      );

      CompletedMove? received;
      await tester.pumpWidget(
        buildWidget(position: pos, onMove: (m) => received = m),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'exd5');
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.san, 'exd5');
    });

    testWidgets('castling with O-O works', (tester) async {
      // Position where castling is legal
      final pos = Chess.fromSetup(
        Setup.parseFen(
          'r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4',
        ),
      );

      CompletedMove? received;
      await tester.pumpWidget(
        buildWidget(position: pos, onMove: (m) => received = m),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'O-O');
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.san, 'O-O');
    });

    testWidgets('castling with 0-0 (zeros) works', (tester) async {
      final pos = Chess.fromSetup(
        Setup.parseFen(
          'r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4',
        ),
      );

      CompletedMove? received;
      await tester.pumpWidget(
        buildWidget(position: pos, onMove: (m) => received = m),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '0-0');
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.san, 'O-O');
    });

    testWidgets('castling via UCI e1g1 works', (tester) async {
      final pos = Chess.fromSetup(
        Setup.parseFen(
          'r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4',
        ),
      );

      CompletedMove? received;
      await tester.pumpWidget(
        buildWidget(position: pos, onMove: (m) => received = m),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'e1g1');
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.san, 'O-O');
    });
  });
}
