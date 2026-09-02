/// Behavior pins for [PgnViewerWidget]'s model layer, driven through
/// [PgnViewerWidgetController] — the contract solitaire, the viewer screen,
/// and the tactics panes rely on. These exist so the flat-mainline →
/// MoveTree port can be attempted without guessing what "unchanged
/// behavior" means, especially for the serializer: an edit must re-emit
/// every annotation the source PGN carried (multi-block comments, sideline
/// comments, NAGs), and scratch analysis must never reach the file.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/pgn/solitaire_reveal.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

/// Mainline e4 e5 Nf3 Nc6 with a multi-block comment on 1. e4, a commented
/// Sicilian sideline, and a NAG on 2. Nf3.
const _annotatedPgn =
    '[Event "Pin"]\n'
    '[White "Alpha, A"]\n'
    '[Black "Beta, B"]\n'
    '[Result "*"]\n'
    '\n'
    '1. e4 {first block} {second block} e5 '
    '(1... c5 {Sicilian try} 2. Nf3) '
    '2. Nf3 \$1 Nc6 *\n';

Future<List<String>> _pump(
  WidgetTester tester, {
  required PgnViewerWidgetController controller,
  String pgn = _annotatedPgn,
  bool editMode = false,
}) async {
  final emissions = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 480,
          height: 640,
          child: PgnViewerWidget(
            pgnText: pgn,
            controller: controller,
            onCommentsChanged: emissions.add,
            editMode: editMode,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return emissions;
}

Position _positionAfter(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    pos = pos.play(pos.parseSan(san)!);
  }
  return pos;
}

void main() {
  testWidgets('loads the mainline and navigates by index', (tester) async {
    final c = PgnViewerWidgetController();
    await _pump(tester, controller: c);

    expect(c.mainLineMoves, ['e4', 'e5', 'Nf3', 'Nc6']);
    expect(c.mainLineLength, 4);
    expect(c.mainLineIndex, 0);

    c.goForward();
    await tester.pumpAndSettle();
    expect(c.mainLineIndex, 1);

    c.goToMainLineIndex(4);
    await tester.pumpAndSettle();
    expect(c.mainLineIndex, 4);

    c.goBack();
    await tester.pumpAndSettle();
    expect(c.mainLineIndex, 3);
  });

  testWidgets('re-annotated movetext keeps the reader where they are', (
    tester,
  ) async {
    final c = PgnViewerWidgetController();
    await _pump(tester, controller: c);
    c.goToMainLineIndex(3);
    await tester.pumpAndSettle();

    // The same game handed back with an engine pass's comments on it — what
    // the analysis tab and the line fill persist.
    const annotated =
        '[Event "Pin"]\n'
        '[White "Alpha, A"]\n'
        '[Black "Beta, B"]\n'
        '[Result "*"]\n'
        '\n'
        '1. e4 {first block} {second block} {[%eval 0.20]} '
        'e5 {[%eval -3.00] [%pv Nf3,Nc6]} '
        '(1... c5 {Sicilian try} 2. Nf3) '
        '2. Nf3 \$1 {[%eval 0.25]} Nc6 {[%eval 0.20]} *\n';
    await _pump(tester, controller: c, pgn: annotated);

    expect(c.mainLineIndex, 3);
    expect(c.currentFen, _positionAfter(['e4', 'e5', 'Nf3']).fen);
    expect(c.mainLineMoves, ['e4', 'e5', 'Nf3', 'Nc6']);
  });

  testWidgets('goToFen parks on the matching position and reports misses', (
    tester,
  ) async {
    final c = PgnViewerWidgetController();
    await _pump(tester, controller: c);

    expect(c.goToFen(_positionAfter(['e4', 'e5']).fen), isTrue);
    await tester.pumpAndSettle();
    expect(c.mainLineIndex, 2);

    // 1. d4 never occurs in this game.
    expect(c.goToFen(_positionAfter(['d4']).fen), isFalse);
    await tester.pumpAndSettle();
    expect(c.mainLineIndex, 2, reason: 'a miss must not move the cursor');
  });

  testWidgets('scratch analysis is ephemeral and never persisted', (
    tester,
  ) async {
    final c = PgnViewerWidgetController();
    final emissions = await _pump(tester, controller: c);

    c.goToMainLineIndex(2);
    await tester.pumpAndSettle();
    c.addEphemeralMove('Bc4');
    await tester.pumpAndSettle();

    expect(c.inVariation, isTrue);
    expect(c.hasEphemeralMoves, isTrue);
    expect(emissions, isEmpty, reason: 'scratch moves must not hit the file');

    c.clearEphemeralMoves();
    await tester.pumpAndSettle();
    expect(c.hasEphemeralMoves, isFalse);
    expect(c.inVariation, isFalse);
    expect(emissions, isEmpty);
  });

  testWidgets(
    "playing the game's own next move follows the mainline, no fork",
    (tester) async {
      final c = PgnViewerWidgetController();
      final emissions = await _pump(tester, controller: c);

      c.addEphemeralMove('e4');
      await tester.pumpAndSettle();

      expect(c.mainLineIndex, 1);
      expect(c.inVariation, isFalse);
      expect(c.hasEphemeralMoves, isFalse);
      expect(emissions, isEmpty);
    },
  );

  testWidgets(
    'amend mode: extending the mainline persists and keeps every annotation',
    (tester) async {
      final c = PgnViewerWidgetController();
      final emissions = await _pump(tester, controller: c, editMode: true);

      c.goToMainLineIndex(4);
      await tester.pumpAndSettle();
      c.addEphemeralMove('Bb5');
      await tester.pumpAndSettle();

      expect(emissions, isNotEmpty);
      final out = emissions.last;
      expect(out, contains('Bb5'));
      // Losslessness: everything the source PGN carried survives the edit.
      expect(out, contains('first block'));
      expect(out, contains('second block'));
      expect(out, contains('c5'));
      expect(out, contains('Sicilian try'));
      expect(out, anyOf(contains(r'$1'), contains('Nf3!')));
    },
  );

  testWidgets('amend mode: a new move off-mainline becomes a saved sideline', (
    tester,
  ) async {
    final c = PgnViewerWidgetController();
    final emissions = await _pump(tester, controller: c, editMode: true);

    c.goToMainLineIndex(2);
    await tester.pumpAndSettle();
    c.addEphemeralMove('Bc4');
    await tester.pumpAndSettle();

    expect(c.inVariation, isTrue);
    expect(emissions, isNotEmpty);
    expect(emissions.last, contains('Bc4'));
  });

  testWidgets(
    'solitaire guesses stay live-only until addGuessVariations persists them',
    (tester) async {
      final c = PgnViewerWidgetController();
      final emissions = await _pump(tester, controller: c);

      c.goToMainLineIndex(2);
      await tester.pumpAndSettle();
      c.recordVariationMove('Bc4');
      await tester.pumpAndSettle();

      expect(c.hasEphemeralMoves, isTrue);
      expect(c.mainLineIndex, 2, reason: 'recording must not navigate');
      expect(emissions, isEmpty);

      c.addGuessVariations({
        2: ['Bc4', 'd4'],
      });
      await tester.pumpAndSettle();

      expect(emissions, isNotEmpty);
      final out = emissions.last;
      expect(out, contains('Bc4'));
      expect(out, contains('d4'));
      expect(
        c.hasEphemeralMoves,
        isFalse,
        reason: 'the live guess was promoted, not duplicated',
      );
    },
  );

  testWidgets('addGuessAnnotations appends and keeps existing comment text', (
    tester,
  ) async {
    final c = PgnViewerWidgetController();
    final emissions = await _pump(tester, controller: c);

    c.addGuessAnnotations({0: 'Guessed d4 here.'});
    await tester.pumpAndSettle();

    expect(emissions, isNotEmpty);
    final out = emissions.last;
    expect(out, contains('Guessed d4 here.'));
    expect(out, contains('first block'));
    expect(out, contains('second block'));
    expect(out, contains('Sicilian try'));
  });

  testWidgets('the solitaire frontier caps forward navigation', (tester) async {
    final c = PgnViewerWidgetController();
    await _pump(tester, controller: c);
    c.setSolitaireReveal(const SolitaireReveal.mainline(2));
    await tester.pumpAndSettle();

    c.goToMainLineIndex(4);
    await tester.pumpAndSettle();
    expect(c.mainLineIndex, 2);

    c.goForward();
    await tester.pumpAndSettle();
    expect(c.mainLineIndex, 2);
  });
}
