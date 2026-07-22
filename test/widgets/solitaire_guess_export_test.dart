/// Solitaire results export: a user's wrong guesses must be saved as real
/// sideline variations (not stripped ephemeral scratch), so the annotated game
/// can be copied / added to a study showing what the solver tried.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

void main() {
  testWidgets('addGuessVariations persists wrong guesses as sidelines', (
    tester,
  ) async {
    final controller = PgnViewerWidgetController();
    String? emitted;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PgnViewerWidget(
            pgnText: '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6',
            controller: controller,
            onCommentsChanged: (movetext) => emitted = movetext,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.mainLineLength, 8, reason: 'game should have loaded');

    // At ply 4 (position after 2...Nc6, White to move) the actual move is
    // 3. Bb5; the solver tried 3. Bc4 first. It should surface as a variation.
    controller.addGuessVariations({
      4: ['Bc4'],
    });
    await tester.pumpAndSettle();

    expect(emitted, isNotNull, reason: 'a movetext should be emitted');
    expect(emitted, contains('Bc4'));
    expect(
      emitted,
      contains('('),
      reason: 'the wrong guess should be serialized as a variation',
    );
  });

  testWidgets('addGuessVariations with no wrong guesses is a no-op', (
    tester,
  ) async {
    final controller = PgnViewerWidgetController();
    var emissions = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PgnViewerWidget(
            pgnText: '1. e4 e5 2. Nf3 Nc6',
            controller: controller,
            onCommentsChanged: (_) => emissions++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller.addGuessVariations({});
    await tester.pumpAndSettle();

    expect(emissions, 0, reason: 'nothing changed, so nothing to persist');
  });
}
