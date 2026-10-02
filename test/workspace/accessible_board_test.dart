import 'dart:ui' show SemanticsAction;

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/workspace/accessible_board.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final played = <String>[];
  setUp(played.clear);
  Future<void> pump(
    WidgetTester tester, {
    Fen fen = Fen.initial,
    Side side = Side.white,
    bool movable = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: AccessibleBoard(
              fen: fen,
              orientation: side,
              movable: movable,
              onMove: played.add,
              child: const ColoredBox(color: Colors.grey),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> activate(WidgetTester tester, String square) async {
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('^$square, ')),
    );
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.tap,
    );
    await tester.pump();
  }

  Future<void> focus(WidgetTester tester) async {
    final context = tester.element(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            (w.properties.label ?? '').startsWith('Chessboard,'),
      ),
    );
    Focus.of(context).requestFocus();
    await tester.pump();
  }

  testWidgets('keyboard explores and plays while modified arrows propagate', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pump(tester);
    await focus(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // e2
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(played, ['e2e4']);
    semantics.dispose();
  });

  testWidgets('Black orientation follows visible arrows', (tester) async {
    await pump(
      tester,
      side: Side.black,
      fen: const Fen(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1',
      ),
    );
    await focus(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // e7
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(played, ['e7e5']);
  });

  testWidgets(
    'semantic squares reject illegal moves and offer every promotion',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      await activate(tester, 'e2');
      await activate(tester, 'e5');
      expect(played, isEmpty);
      expect(
        find.bySemanticsLabel('That move is not legal here.'),
        findsOneWidget,
      );
      await activate(tester, 'e4');
      expect(played, ['e2e4']);
      played.clear();
      await pump(tester, fen: const Fen('7k/4P3/8/8/8/8/8/K7 w - - 0 1'));
      await activate(tester, 'e7');
      await activate(tester, 'e8');
      await tester.pumpAndSettle();
      for (final piece in ['queen', 'rook', 'bishop', 'knight']) {
        expect(find.text(piece), findsOneWidget);
      }
      await tester.tap(find.text('knight'));
      await tester.pumpAndSettle();
      expect(played, ['e7e8n']);
      semantics.dispose();
    },
  );

  testWidgets('a promotion from an old position cannot play on a new board', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, fen: const Fen('7k/4P3/8/8/8/8/8/K7 w - - 0 1'));
    await activate(tester, 'e7');
    await activate(tester, 'e8');
    await tester.pumpAndSettle();
    await pump(tester);
    await tester.tap(find.text('queen'));
    await tester.pumpAndSettle();
    expect(played, isEmpty);
    semantics.dispose();
  });

  testWidgets('read-only squares have names but no move action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, movable: false);
    final node = tester.getSemantics(find.bySemanticsLabel('e2, White pawn'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    semantics.dispose();
  });
}
