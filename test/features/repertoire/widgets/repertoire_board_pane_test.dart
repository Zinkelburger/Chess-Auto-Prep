import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_board_pane.dart';
import 'package:chess_auto_prep/widgets/board/board_square_painter.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The builder's board answers "where am I, and what would that move do?"
/// with tinted squares — the same mark for both, and nothing painted over
/// the pieces.
void main() {
  Position positionFromFen(String fen) => Chess.fromSetup(Setup.parseFen(fen));

  const afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

  Future<BoardSquarePainter> pump(
    WidgetTester tester,
    BoardPreviewController preview, {
    Set<String> recentMoveSquares = const {},
    String fen = afterE4,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 320,
            child: RepertoireBoardPane(
              boardPreview: preview,
              fen: fen,
              positionFromFen: positionFromFen,
              boardFlipped: false,
              onMove: (_) {},
              recentMoveSquares: recentMoveSquares,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<BoardSquarePainter>()
        .single;
  }

  testWidgets('marks the move that reached the position', (tester) async {
    final preview = BoardPreviewController();
    addTearDown(preview.dispose);

    final surface = await pump(
      tester,
      preview,
      recentMoveSquares: {'e2', 'e4'},
    );
    expect(surface.recentMoveSquares, {'e2', 'e4'});
    expect(surface.highlightedSquares, isEmpty);
  });

  testWidgets('a hovered move tints the squares it would use', (tester) async {
    final preview = BoardPreviewController();
    addTearDown(preview.dispose);

    await pump(tester, preview, recentMoveSquares: {'e2', 'e4'});
    preview.setHoverMove('g8f6');
    await tester.pump();

    final surface = await pump(
      tester,
      preview,
      recentMoveSquares: {'e2', 'e4'},
    );
    expect(surface.highlightedSquares, {'g8', 'f6'});
    // The trail stays put: hovering answers a different question.
    expect(surface.recentMoveSquares, {'e2', 'e4'});

    preview.setHoverMove(null);
    await tester.pump();
    final cleared = await pump(
      tester,
      preview,
      recentMoveSquares: {'e2', 'e4'},
    );
    expect(cleared.highlightedSquares, isEmpty);
  });

  testWidgets('a position preview marks the move that produced it', (
    tester,
  ) async {
    final preview = BoardPreviewController();
    addTearDown(preview.dispose);

    await pump(tester, preview, recentMoveSquares: {'e2', 'e4'});
    preview.setPreview(
      'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
      lastMoveUci: 'e7e5',
    );
    await tester.pump(BoardPreviewController.previewDelay);

    final surface = await pump(
      tester,
      preview,
      recentMoveSquares: {'e2', 'e4'},
    );
    // The cursor's own trail belongs to the position we left.
    expect(surface.recentMoveSquares, {'e7', 'e5'});
    expect(surface.highlightedSquares, isEmpty);
  });
}
