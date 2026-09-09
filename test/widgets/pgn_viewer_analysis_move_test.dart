/// Moves played onto the viewer from outside (the tactics board, an engine
/// line) land in the move tree without duplicating what is already there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';

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
  testWidgets('inline preview selects only its move and replaces board trail', (
    tester,
  ) async {
    final controller = await _pumpViewer(
      tester,
      '1. e4 {[%eval 0.2]} e5 {[%eval 0.2]} '
      '2. Nf3 {[%eval -6.0] [%pv Bc4,Nf6,d3]} Nc6 {[%eval -6.0]} '
      '3. Bb5 {[%eval -6.0]} a6 {[%eval -6.0]}',
    );
    controller.goToMainLineIndex(3);
    await tester.pumpAndSettle();
    expect(controller.recentMoveSquares, {'g1', 'f3'});

    await tester.tap(find.byTooltip('Preview comment move').at(1));
    await tester.pumpAndSettle();
    expect(controller.inVariation, isTrue);
    expect(controller.recentMoveSquares, {'g8', 'f6'});
    final selections = tester
        .widgetList<MoveChip>(find.byType(MoveChip))
        .where((chip) => chip.decoration?.color == AppColors.pgnMoveCurrentBg);
    expect(selections.map((chip) => chip.san), [
      'Nf6',
    ], reason: 'the parked mainline move is not the position on the board');

    controller.goBack();
    await tester.pumpAndSettle();
    expect(controller.recentMoveSquares, {'f1', 'c4'});
    controller.goBack();
    await tester.pumpAndSettle();
    expect(controller.inVariation, isFalse);
    expect(controller.recentMoveSquares, {'e7', 'e5'});
    expect(
      tester
          .widgetList<MoveChip>(find.byType(MoveChip))
          .where((chip) => chip.decoration?.color == AppColors.pgnMoveCurrentBg)
          .map((chip) => chip.san),
      ['e5'],
    );
  });

  for (final comment in [
    'Consider 1...c5!? 2.Nf3, then develop.',
    'Consider …c5!? 2.Nf3, then develop.',
    '@@HeaderStart@@Alternative@@HeaderEnd@@  1...c5!?  2.Nf3  then develop.',
  ]) {
    testWidgets('comment selection covers only SAN: $comment', (tester) async {
      final controller = await _pumpViewer(tester, '1. e4 {$comment} e5 *');
      controller.goToMainLineIndex(1);
      await tester.pumpAndSettle();
      final mainline = tester
          .widgetList<MoveChip>(find.byType(MoveChip))
          .singleWhere((chip) => chip.san == 'e4');
      final move = find.byWidgetPredicate(
        (widget) => widget is MoveChip && widget.san == 'c5!?',
      );
      expect(
        move,
        findsOneWidget,
        reason: tester
            .widgetList<MoveChip>(find.byType(MoveChip))
            .map((chip) => chip.san)
            .join(', '),
      );
      final before = tester.getRect(move);
      final weight = tester.widget<MoveChip>(move).sanStyle.fontWeight;
      await tester.tap(move);
      await tester.pumpAndSettle();
      final selected = tester.widget<MoveChip>(move);
      expect(selected.decoration, mainline.decoration);
      expect(selected.padding, mainline.padding);
      expect(selected.sanStyle.color, mainline.sanStyle.color);
      expect(selected.sanStyle.fontWeight, weight);
      expect(tester.getRect(move).size, before.size);
      expect(
        find
            .descendant(of: move, matching: find.byType(RichText))
            .evaluate()
            .map((element) => (element.widget as RichText).text.toPlainText()),
        ['c5!?'],
        reason: 'numbers and separator spaces must remain outside the pill',
      );
      expect(controller.recentMoveSquares, {'c7', 'c5'});
      expect(tester.takeException(), isNull);
    });
  }

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
