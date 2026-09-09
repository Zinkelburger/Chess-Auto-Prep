import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/pgn/comment_diagram.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _fen = 'rnbqk2r/ppp1ppbp/3p1np1/8/2PPP3/2N5/PP3PPP/R1BQKBNR w KQkq - 0 5';

void main() {
  testWidgets('nested diagram keeps comment moves separate and FEN-anchored', (
    tester,
  ) async {
    final controller = PgnViewerWidgetController();
    final writes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PgnViewerWidget(
            controller: controller,
            onCommentsChanged: writes.add,
            pgnText:
                '1. d4 {Compare @@StartBracket@@this position '
                '@@StartFEN@@$_fen@@EndFEN@@  5.h3  O-O  '
                '@@StartBracket@@a useful pause@@EndBracket@@  '
                '6.Nf3  @@EndBracket@@ and continue.} Nf6 *',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CommentDiagramBoard), findsOneWidget);
    expect(
      tester
          .widget<ChessBoardWidget>(find.byType(ChessBoardWidget))
          .position
          .fen,
      _fen,
    );
    expect(find.textContaining('@@', findRichText: true), findsNothing);
    final move = find.text('Nf3', findRichText: true);
    await tester.ensureVisible(move);
    final beforeTap = tester.getTopLeft(move).dy;
    await tester.tap(move);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(move).dy, closeTo(beforeTap, 1));
    Position expected = Chess.fromSetup(Setup.parseFen(_fen));
    for (final san in ['h3', 'O-O', 'Nf3']) {
      expected = expected.play(expected.parseSan(san)!);
    }
    expect(controller.currentFen, expected.fen);
    expect(controller.inVariation, isTrue);
    expect(controller.mainLineMoves, ['d4', 'Nf6']);
    expect(controller.hasSavedSidelines, isFalse);
    expect(writes, isEmpty);
    expect(find.text('Comment preview'), findsOneWidget);
    controller.returnToMainline();
    await tester.pumpAndSettle();
    expect(controller.inVariation, isFalse);
    expect(controller.mainLineMoves, ['d4', 'Nf6']);
  });

  testWidgets('bare diagrams render without opting into book formatting', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PgnViewerWidget(pgnText: '1. d4 {Before $_fen after.} Nf6 *'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CommentDiagramBoard), findsOneWidget);
    expect(find.textContaining('Before', findRichText: true), findsOneWidget);
    expect(find.textContaining('after.', findRichText: true), findsOneWidget);
  });

  testWidgets('invalid FEN content remains readable at narrow widths', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: PgnViewerWidget(
              pgnText:
                  '1. d4 {Before @@StartFEN@@broken position@@EndFEN@@ after.} *',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('broken position', findRichText: true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain prose keeps move numbers, ellipses and annotations', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PgnViewerWidget(
            pgnText: '1. d4 {Consider 1...Nf6!? or ...d5.} Nf6 *',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final text = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((widget) => widget.text.toPlainText())
        .join(' ');
    expect(text, contains('1...'));
    expect(text, contains('!?'));
    expect(text, contains('or '));
    expect(text, contains('...'));
    expect(find.text('d5', findRichText: true), findsOneWidget);
    expect(find.byTooltip('Preview comment move'), findsWidgets);
  });
  testWidgets('Black ellipsis cannot preview a legal White pawn move', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PgnViewerWidget(
            pgnText:
                '1. d4 Nf6 2. c4 g6 {Black plans ...c5 or …c5. Develop the knight to f3.} *',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Preview comment move'), findsNothing);
    expect(
      find.textContaining(
        'Black plans ...c5 or …c5. Develop the knight to f3.',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });
}
