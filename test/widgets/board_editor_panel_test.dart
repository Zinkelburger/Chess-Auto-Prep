import 'package:chess_auto_prep/core/board_editor_controller.dart';
import 'package:chess_auto_prep/widgets/board_editor/board_editor_panel.dart';
import 'package:chess_auto_prep/widgets/board_editor/piece_palette.dart';
import 'package:chess_auto_prep/widgets/board_editor/position_setup_panel.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpControls(
    WidgetTester tester,
    BoardEditorController editor, {
    ValueChanged<Position>? onAction,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          child: PositionSetupPanel(
            controller: editor,
            advancedInitiallyExpanded: false,
            actionLabel: 'Use this position',
            onAction: onAction ?? (_) {},
          ),
        ),
      ),
    ),
  );

  TextField fenField(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField));

  FilledButton useButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'Use this position'),
  );

  testWidgets('invalid FEN survives blur and cannot apply the previous board', (
    tester,
  ) async {
    final editor = BoardEditorController();
    addTearDown(editor.dispose);
    Position? chosen;
    await pumpControls(tester, editor, onAction: (value) => chosen = value);
    final before = editor.fen;

    await tester.enterText(find.byType(TextField), 'invalid FEN');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(fenField(tester).controller!.text, 'invalid FEN');
    expect(useButton(tester).onPressed, isNull);
    expect(editor.hasUnappliedFen, isTrue);

    await tester.ensureVisible(find.text('Apply FEN'));
    await tester.tap(find.text('Apply FEN'));
    await tester.pumpAndSettle();
    expect(fenField(tester).decoration!.errorText, contains('Could not parse'));
    expect(fenField(tester).controller!.text, 'invalid FEN');
    expect(editor.fen, before);
    expect(chosen, isNull);
    expect(useButton(tester).onPressed, isNull);

    await tester.ensureVisible(find.text('Discard FEN changes'));
    await tester.tap(find.text('Discard FEN changes'));
    await tester.pumpAndSettle();
    expect(fenField(tester).controller!.text, before);
    expect(editor.hasUnappliedFen, isFalse);
    expect(fenField(tester).decoration!.errorText, isNull);
    expect(useButton(tester).onPressed, isNotNull);
  });

  testWidgets('Apply FEN canonicalizes text then uses the new position', (
    tester,
  ) async {
    final editor = BoardEditorController();
    addTearDown(editor.dispose);
    Position? chosen;
    await pumpControls(tester, editor, onAction: (value) => chosen = value);
    await tester.enterText(find.byType(TextField), '4k3/8/8/8/8/8/8/4K3 b - -');
    await tester.pump();
    expect(useButton(tester).onPressed, isNull);
    await tester.ensureVisible(find.text('Apply FEN'));
    await tester.tap(find.text('Apply FEN'));
    await tester.pumpAndSettle();
    expect(editor.turn, Side.black);
    expect(editor.hasUnappliedFen, isFalse);
    expect(fenField(tester).controller!.text, editor.fen);
    await tester.ensureVisible(find.text('Use this position'));
    await tester.tap(find.text('Use this position'));
    expect(chosen?.fen, editor.fen);
  });

  testWidgets(
    'controls follow a replacement controller and detach the old one',
    (tester) async {
      final first = BoardEditorController();
      final second = BoardEditorController(
        initialFen: '4k3/8/8/8/8/8/8/4K3 b - -',
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await pumpControls(tester, first);
      await pumpControls(tester, second);
      first.clear();
      await tester.pump();
      expect(fenField(tester).controller!.text, second.fen);
      second.setTurn(Side.white);
      await tester.pump();
      expect(fenField(tester).controller!.text, second.fen);
      await tester.pumpWidget(const SizedBox.shrink());
      first.setStartPosition();
      second.clear();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clear, start, flip and advanced castling controls are reachable',
    (tester) async {
      final editor = BoardEditorController();
      addTearDown(editor.dispose);
      await pumpControls(tester, editor);
      await tester.tap(find.text('Clear board'));
      await tester.pump();
      expect(editor.board, Board.empty);
      expect(useButton(tester).onPressed, isNull);
      await tester.tap(find.text('Start position'));
      await tester.tap(find.text('Flip board'));
      await tester.tap(find.text('Black to move'));
      await tester.pump();
      expect(editor.flipped, isTrue);
      expect(editor.turn, Side.black);
      expect(editor.board, Board.standard);
      expect(find.text('White O-O'), findsNothing);
      await tester.tap(find.text('Advanced position settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('White O-O'));
      await tester.pump();
      expect(editor.whiteKingside, isFalse);
      expect(editor.whiteQueenside, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [600.0, 900.0]) {
    testWidgets('complete editor embeds at width $width', (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final editor = BoardEditorController();
      addTearDown(editor.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: BoardEditorPanel(controller: editor),
            ),
          ),
        ),
      );
      expect(find.byType(SparePieceRow), findsNWidgets(2));
      await tester.ensureVisible(find.text('Apply FEN'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
