import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/training/move_input_widget.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      bool Function(KeyEvent)? onNavigationKey,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: MoveInputWidget(
            position: position ?? startPosition,
            enabled: enabled,
            onMove: onMove ?? (_) {},
            onNavigationKey: onNavigationKey,
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

    // ── Trainer navigation keys ──────────────────────────────────────────
    // The tactics trainer's shortcut handler is a focus-tree sibling, so the
    // field forwards non-editing keys to onNavigationKey and swallows whatever
    // it claims — that's what keeps S/P and the arrow keys out of the textbox.

    testWidgets('forwards navigation keys to onNavigationKey while focused', (
      tester,
    ) async {
      final received = <LogicalKeyboardKey>[];
      await tester.pumpWidget(
        buildWidget(
          onNavigationKey: (event) {
            received.add(event.logicalKey);
            return true; // claim the key
          },
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(received, [
        LogicalKeyboardKey.keyS,
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.space,
      ]);
    });

    testWidgets('a claimed navigation key never types into the field', (
      tester,
    ) async {
      await tester.pumpWidget(buildWidget(onNavigationKey: (_) => true));

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, isEmpty);
    });

    testWidgets('arrow keys stay in the field for caret editing while typing', (
      tester,
    ) async {
      final received = <LogicalKeyboardKey>[];
      await tester.pumpWidget(
        buildWidget(
          onNavigationKey: (event) {
            received.add(event.logicalKey);
            return true; // claim everything it's offered
          },
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();

      // A partial, ambiguous multi-char move (no auto-submit from the start
      // position) so there is text to edit.
      await tester.enterText(find.byType(TextField), 'Nb');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // With text present, ←/→ are NOT forwarded — the field keeps them so the
      // caret can be repositioned to fix a typo.
      expect(received, isEmpty);
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, 'Nb');
    });

    testWidgets('Escape and Tab are handled by the field, not forwarded', (
      tester,
    ) async {
      final received = <LogicalKeyboardKey>[];
      await tester.pumpWidget(
        buildWidget(
          onNavigationKey: (event) {
            received.add(event.logicalKey);
            return true;
          },
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(received, isEmpty);
    });
  });
}
