/// Moves played onto the viewer from outside (the tactics board, an engine
/// line) land in the move tree without duplicating what is already there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

Future<PgnViewerWidgetController> _pumpViewer(
  WidgetTester tester,
  String pgn,
) async {
  final controller = PgnViewerWidgetController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PgnViewerWidget(pgnText: pgn, controller: controller),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('a move matching the mainline follows it instead of forking', (
    tester,
  ) async {
    final controller = await _pumpViewer(tester, '1. e4 e5 2. Nf3 Nc6');
    expect(controller.mainLineLength, 4, reason: 'game should have loaded');

    controller.goToMainLineIndex(0);
    await tester.pumpAndSettle();

    controller.addEphemeralMove('e4');
    await tester.pumpAndSettle();

    expect(controller.mainLineIndex, 1);
    expect(controller.inVariation, isFalse);
    expect(
      controller.hasEphemeralMoves,
      isFalse,
      reason: 'the game already contains this move — no sideline beside it',
    );
  });

  testWidgets('a move the game did not play becomes a variation', (
    tester,
  ) async {
    final controller = await _pumpViewer(tester, '1. e4 e5 2. Nf3 Nc6');

    controller.goToMainLineIndex(1); // after 1. e4
    await tester.pumpAndSettle();

    controller.addEphemeralMove('c5'); // the game played e5
    await tester.pumpAndSettle();

    expect(controller.inVariation, isTrue);
    expect(controller.hasEphemeralMoves, isTrue);
    expect(controller.mainLineIndex, 1, reason: 'mainline cursor stays put');
  });

  testWidgets('a whole line off the game is kept as one variation', (
    tester,
  ) async {
    final controller = await _pumpViewer(tester, '1. e4 e5 2. Nf3 Nc6');

    controller.goToMainLineIndex(1);
    await tester.pumpAndSettle();
    for (final san in const ['c5', 'Nf3', 'd6']) {
      controller.addEphemeralMove(san);
      await tester.pumpAndSettle();
    }

    expect(controller.inVariation, isTrue);
    // The line is on screen, not something the user has to re-enter.
    expect(find.text('c5'), findsOneWidget);
    expect(find.text('d6'), findsOneWidget);
  });
}
