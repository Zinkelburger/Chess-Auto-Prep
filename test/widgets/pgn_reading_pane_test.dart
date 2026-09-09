import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_reading_passage.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _tree =
    '1. e4 {Mainline explanation.} e5 '
    '(1... c5 {Sicilian explanation.} 2. Nf3 d6 '
    '(2... Nc6 {Second branch explanation.} 3. d4 cxd4 '
    '(3... e5 {Deep branch explanation.} 4. d5)) 3. d4) '
    '2. Nf3 {Developing explanation.} Nc6 *';

Finder _move(String san) =>
    find.byWidgetPredicate((w) => w is MoveChip && w.san == san);
Finder get _scrollView => find.byKey(const ValueKey('pgn-reading-scroll'));

Future<PgnViewerWidgetController> _pump(
  WidgetTester tester, {
  String pgn = _tree,
  double width = 520,
}) async {
  final controller = PgnViewerWidgetController();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: PgnViewerWidget(pgnText: pgn, controller: controller),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  for (final note in ['', '{A short explanation.}']) {
    testWidgets('a fitting game keeps its title visible with note="$note"', (
      tester,
    ) async {
      final controller = await _pump(
        tester,
        pgn:
            '[White "A comfortable fit"]\n'
            '[Black "A comfortable fit"]\n\n'
            '1. e4 $note e5 2. Nf3 Nc6 3. Bb5 a6 *',
      );
      final title = find.text('A comfortable fit');
      final titleTop = tester.getTopLeft(title).dy;
      final scroll = tester
          .widget<SingleChildScrollView>(_scrollView)
          .controller!;
      for (final anchor in [
        'Anchor near top',
        'Anchor near middle',
        'Anchor near bottom',
      ]) {
        await tester.tap(find.byTooltip('Reading options'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, anchor),
        );
        await tester.pumpAndSettle();
        for (final ply in [1, 3, 6, 0]) {
          controller.goToMainLineIndex(ply);
          await tester.pumpAndSettle();
          expect(scroll.offset, 0);
          expect(scroll.position.maxScrollExtent, 0);
          expect(tester.getTopLeft(title).dy, titleTop);
          expect(
            tester.getRect(_scrollView).contains(tester.getCenter(title)),
            isTrue,
          );
        }
      }
    });
  }

  testWidgets(
    'the final move stops at the document end without a blank screen',
    (tester) async {
      final note = List.filled(70, 'Readable prose needs space.').join(' ');
      final controller = await _pump(tester, pgn: '1. e4 {$note} e5 *');
      controller.goToMainLineIndex(2);
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(_scrollView)
          .controller!;
      expect(scroll.offset, greaterThan(0));
      expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
      final viewport = tester.getRect(_scrollView);
      final lastMove = tester.getRect(_move('e5'));
      expect(viewport.contains(lastMove.center), isTrue);
      expect(viewport.bottom - lastMove.bottom, lessThan(80));
    },
  );

  testWidgets(
    'fold controls reveal notes without moving the board or entering focus',
    (tester) async {
      final controller = await _pump(tester);
      final board = controller.currentFen;
      expect(
        find.textContaining('Deep branch explanation.', findRichText: true),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Reading options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expand all variations'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Deep branch explanation.', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Mainline explanation.', findRichText: true),
        findsOneWidget,
      );
      expect(controller.currentFen, board);

      await tester.tap(find.byTooltip('Reading options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fold deep variations'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Deep branch explanation.', findRichText: true),
        findsNothing,
      );
      expect(controller.currentFen, board);
    },
  );

  testWidgets(
    'returning from nested focus restores each parent reading position',
    (tester) async {
      // Keep enough prose below each bookmark to restore the same offset,
      // independently of the document-end clamp for short variations.
      final controller = await _pump(
        tester,
        pgn: _tree.replaceAll(
          'explanation.',
          'explanation. ${List.filled(30, 'More context for the reader.').join(' ')}',
        ),
      );
      final view = tester.widget<PgnMovetextView>(find.byType(PgnMovetextView));
      final sicilian = view.variationsByPly[1]!.single;
      final nested = sicilian.children.first.children[1];
      double offset() =>
          tester.widget<SingleChildScrollView>(_scrollView).controller!.offset;

      controller.goToVariationNode(sicilian, 1);
      await tester.pumpAndSettle();
      final documentOffset = offset();
      controller.focusVariation();
      await tester.pumpAndSettle();
      controller.goToVariationNode(nested, 1);
      await tester.pumpAndSettle();
      final parentOffset = offset();
      controller.focusVariation();
      await tester.pumpAndSettle();
      controller.returnToParentLine();
      await tester.pumpAndSettle();
      expect(offset(), closeTo(parentOffset, 1));
      expect(
        find.textContaining('Mainline explanation.', findRichText: true),
        findsNothing,
      );
      controller.returnToParentLine();
      await tester.pumpAndSettle();
      expect(offset(), closeTo(documentOffset, 1));
      expect(
        find.textContaining('Mainline explanation.', findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets('Left crosses focused branch roots one parent at a time', (
    tester,
  ) async {
    final controller = await _pump(tester);
    final view = tester.widget<PgnMovetextView>(find.byType(PgnMovetextView));
    final sicilian = view.variationsByPly[1]!.single;
    final nf3 = sicilian.children.first;
    final nested = nf3.children[1];
    controller.goToVariationNode(sicilian, 1);
    await tester.pumpAndSettle();
    controller.focusVariation();
    await tester.pumpAndSettle();
    controller.goToVariationNode(nested, 1);
    await tester.pumpAndSettle();
    controller.focusVariation();
    await tester.pumpAndSettle();
    controller.goBack();
    await tester.pumpAndSettle();
    expect(controller.currentFen, nf3.fen);
    expect(
      find.textContaining('Mainline explanation.', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('Sicilian explanation.', findRichText: true),
      findsOneWidget,
    );
    controller.goBack();
    await tester.pumpAndSettle();
    expect(controller.currentFen, sicilian.fen);
    controller.goBack();
    await tester.pumpAndSettle();
    expect(controller.inVariation, isFalse);
    expect(controller.mainLineIndex, 1);
    expect(
      find.textContaining('Mainline explanation.', findRichText: true),
      findsOneWidget,
    );
    expect(controller.returnToParentLine(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'parent command leaves an unfocused nested branch before its focused ancestor',
    (tester) async {
      final controller = await _pump(tester);
      final view = tester.widget<PgnMovetextView>(find.byType(PgnMovetextView));
      final sicilian = view.variationsByPly[1]!.single;
      final nf3 = sicilian.children.first;
      controller.goToVariationNode(sicilian, 1);
      await tester.pumpAndSettle();
      controller.focusVariation();
      await tester.pumpAndSettle();
      controller.goToVariationNode(nf3.children[1], 1);
      await tester.pumpAndSettle();
      expect(controller.returnToParentLine(), isTrue);
      await tester.pumpAndSettle();
      expect(controller.currentFen, nf3.fen);
      expect(
        find.textContaining('Mainline explanation.', findRichText: true),
        findsNothing,
      );
      expect(controller.returnToParentLine(), isTrue);
      await tester.pumpAndSettle();
      expect(controller.inVariation, isFalse);
      expect(
        find.textContaining('Mainline explanation.', findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets('focus a nested branch, return to parent and then mainline', (
    tester,
  ) async {
    final controller = await _pump(tester, width: 330);
    // Navigate through the real tree, including a normally folded third level.
    final view = tester.widget<PgnMovetextView>(find.byType(PgnMovetextView));
    final sicilian = view.variationsByPly[1]!.single;
    final nf3 = sicilian.children.first;
    final nc6 = nf3.children[1];
    final d4 = nc6.children.first;
    final e5 = d4.children[1];

    controller.goToVariationNode(e5, 1);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Deep branch explanation.', findRichText: true),
      findsOneWidget,
    );
    expect(_move('e5'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(TextButton, 'Focus variation'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Deep branch explanation.', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Mainline explanation.', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('Second branch explanation.', findRichText: true),
      findsNothing,
    );
    expect(controller.currentFen, e5.fen);

    controller.goForward();
    await tester.pumpAndSettle();
    expect(controller.currentFen, e5.children.first.fen);
    await tester.tap(find.widgetWithText(TextButton, 'Return to parent'));
    await tester.pumpAndSettle();
    expect(controller.currentFen, d4.fen);
    expect(
      find.textContaining('Mainline explanation.', findRichText: true),
      findsOneWidget,
    );
    controller.returnToMainline();
    await tester.pumpAndSettle();
    expect(controller.inVariation, isFalse);
    expect(controller.mainLineIndex, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'move anchoring works in sidelines and manual scrolling leaves the board alone',
    (tester) async {
      final longNote = List.filled(
        55,
        'This is a long explanation of the position.',
      ).join(' ');
      final controller = await _pump(
        tester,
        pgn:
            '1. e4 {$longNote} e5 (1... c5 {$longNote}) 2. Nf3 {$longNote} Nc6 *',
      );
      controller.goToMainLineIndex(3);
      await tester.pumpAndSettle();
      double activeTop() {
        final active = find.byWidgetPredicate(
          (w) => w is PgnReadingPassage && w.active,
        );
        return tester.getTopLeft(active).dy - tester.getTopLeft(_scrollView).dy;
      }

      expect(activeTop(), closeTo(52, 1));
      final board = controller.currentFen;
      await tester.drag(_scrollView, const Offset(0, -220));
      await tester.pumpAndSettle();
      expect(controller.currentFen, board);
      expect(find.text('Back to current move (Esc)'), findsOneWidget);
      expect(controller.returnToReadingMove(), isTrue);
      await tester.pumpAndSettle();
      expect(activeTop(), closeTo(52, 1));

      final view = tester.widget<PgnMovetextView>(find.byType(PgnMovetextView));
      controller.goToVariationNode(view.variationsByPly[1]!.single, 1);
      await tester.pumpAndSettle();
      expect(activeTop(), closeTo(52, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a long note keeps its original heading visible with one scrollbar',
    (tester) async {
      final note = List.filled(70, 'Readable prose needs space.').join(' ');
      final controller = await _pump(
        tester,
        pgn: '1. e4 {$note} e5 *',
        width: 330,
      );
      controller.goForward();
      await tester.pumpAndSettle();
      await tester.drag(_scrollView, const Offset(0, -250));
      await tester.pumpAndSettle();
      expect(_move('e4'), findsOneWidget);
      final headingTop = tester.getTopLeft(_move('e4')).dy;
      expect(headingTop, closeTo(tester.getTopLeft(_scrollView).dy, 2));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(
        find.textContaining('Readable prose needs space.', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
