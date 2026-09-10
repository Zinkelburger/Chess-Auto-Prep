/// Moves played onto the viewer from outside (the tactics board, an engine
/// line) land in the move tree without duplicating what is already there.
library;

import 'package:dartchess/dartchess.dart';
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

Finder _bestMove(String san) => find.descendant(
  of: find.byKey(const ValueKey('pgn-analysis-line-2')),
  matching: find.byWidgetPredicate(
    (widget) => widget is MoveChip && widget.san == san,
  ),
);

void main() {
  testWidgets(
    'stored best variation selects only its move and replaces board trail',
    (tester) async {
      final controller = await _pumpViewer(
        tester,
        '1. e4 {[%eval 0.2]} e5 {[%eval 0.2]} '
        '2. Nf3 {[%eval -6.0] [%pv Bc4,Nf6,d3]} Nc6 {[%eval -6.0]} '
        '3. Bb5 {[%eval -6.0]} a6 {[%eval -6.0]}',
      );
      controller.goToMainLineIndex(3);
      await tester.pumpAndSettle();
      expect(controller.recentMoveSquares, {'g1', 'f3'});

      await tester.tap(_bestMove('Nf6'));
      await tester.pumpAndSettle();
      expect(controller.inVariation, isTrue);
      expect(controller.currentVariationNodeId, isNotNull);
      expect(controller.hasSavedSidelines, isTrue);
      expect(find.byTooltip('Preview comment move'), findsNothing);
      expect(find.text('Bc4'), findsOneWidget);
      expect(find.text('Nf6'), findsOneWidget);
      expect(controller.recentMoveSquares, {'g8', 'f6'});
      final selections = tester
          .widgetList<MoveChip>(find.byType(MoveChip))
          .where(
            (chip) => chip.decoration?.color == AppColors.pgnMoveCurrentBg,
          );
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
            .where(
              (chip) => chip.decoration?.color == AppColors.pgnMoveCurrentBg,
            )
            .map((chip) => chip.san),
        ['e5'],
      );
    },
  );

  for (final score in ['-0.65', '-1.30', '-6.00']) {
    testWidgets('extend a classified best line and back up one ply: $score', (
      tester,
    ) async {
      final controller = await _pumpViewer(
        tester,
        '1. e4 {[%eval 0.00]} e5 {[%eval 0.00]} '
        '2. Nf3 {[%eval $score] [%pv Bc4,Nf6,d3]} Nc6 {[%eval $score]} *',
      );
      final positions = <String>[];
      Position pos = Chess.initial;
      for (final san in ['e4', 'e5', 'Bc4', 'Nf6', 'Nc3', 'Bb4']) {
        pos = pos.play(pos.parseSan(san)!);
        positions.add(pos.fen);
      }
      await tester.tap(_bestMove('Nf6'));
      await tester.pumpAndSettle();
      expect(controller.currentFen, positions[3]);
      controller.addEphemeralMove('Nc3');
      controller.addEphemeralMove('Bb4');
      await tester.pumpAndSettle();
      expect(controller.currentFen, positions[5]);
      for (final index in [4, 3, 2, 1]) {
        controller.goBack();
        await tester.pumpAndSettle();
        expect(controller.currentFen, positions[index]);
        expect(controller.inVariation, index > 1);
      }
      // Re-entering the source suggestion must keep our explored branch.
      await tester.tap(_bestMove('Nf6'));
      await tester.pumpAndSettle();
      controller.addEphemeralMove('Nc3');
      await tester.pumpAndSettle();
      controller.goForward();
      await tester.pumpAndSettle();
      expect(controller.currentFen, positions[5]);
      controller.goBack();
      controller.goBack();
      controller.goForward();
      await tester.pumpAndSettle();
      final before = Chess.fromSetup(Setup.parseFen(positions[3]));
      expect(controller.currentFen, before.play(before.parseSan('d3')!).fen);
    });
  }

  testWidgets('saving a move from a preview includes its legal ancestry', (
    tester,
  ) async {
    final controller = PgnViewerWidgetController();
    final writes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PgnViewerWidget(
            controller: controller,
            persistMoves: true,
            onCommentsChanged: writes.add,
            pgnText:
                '1. e4 {[%eval 0.0]} e5 {[%eval 0.0]} '
                '2. Nf3 {[%eval -6.0] [%pv Bc4,Nf6,d3]} *',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_bestMove('Bc4'));
    await tester.pumpAndSettle();
    expect(
      writes,
      hasLength(1),
      reason: 'legacy review migrated through normal save policy',
    );
    // Following the already suggested reply must save that node as well.
    controller.addEphemeralMove('Nf6');
    await tester.pumpAndSettle();
    expect(writes, hasLength(2));
    final tree = PgnGame.parsePgn(writes.last).moves;
    final alternative = tree.children.single.children.single.children[1];
    expect(alternative.data.san, 'Bc4');
    expect(alternative.children.single.data.san, 'Nf6');
    expect(alternative.children.single.children.single.data.san, 'd3');
    expect(controller.mainLineMoves, ['e4', 'e5', 'Nf3']);
    controller.goBack();
    await tester.pumpAndSettle();
    expect(controller.recentMoveSquares, {'f1', 'c4'});
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
