import 'package:chess_auto_prep/models/board_display_settings.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/widgets/board/board_coordinates.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/common/piece_image.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const sq = 50.0;

  List<CoordinateLabel> labels(
    BoardCoordinates mode, {
    bool flipped = false,
    double squareSize = sq,
    double margin = 0,
  }) => coordinateLabels(
    mode: mode,
    flipped: flipped,
    squareSize: squareSize,
    margin: margin,
  );

  String textAt(List<CoordinateLabel> all, int col, int row) => all
      .singleWhere((l) => l.cell.left == col * sq && l.cell.top == row * sq)
      .text;

  group('coordinateLabels', () {
    test('none, and any thumbnail, draw nothing', () {
      expect(labels(BoardCoordinates.none), isEmpty);
      expect(labels(BoardCoordinates.inside, squareSize: 20), isEmpty);
      expect(labels(BoardCoordinates.everySquare, squareSize: 12), isEmpty);
    });

    test('inside: files along the bottom rank, ranks up the right file', () {
      final all = labels(BoardCoordinates.inside);
      expect(all, hasLength(16));

      final files = all.where((l) => l.alignment == Alignment.bottomRight);
      expect(files.map((l) => l.text), [
        'a',
        'b',
        'c',
        'd',
        'e',
        'f',
        'g',
        'h',
      ]);
      expect(files.every((l) => l.cell.top == 7 * sq), isTrue);

      final ranks = all.where((l) => l.alignment == Alignment.topRight);
      expect(ranks.map((l) => l.text), [
        '8',
        '7',
        '6',
        '5',
        '4',
        '3',
        '2',
        '1',
      ]);
      expect(ranks.every((l) => l.cell.left == 7 * sq), isTrue);
    });

    test('inside, flipped: the board is read from the black side', () {
      final all = labels(BoardCoordinates.inside, flipped: true);
      final files = all.where((l) => l.alignment == Alignment.bottomRight);
      expect(files.map((l) => l.text), [
        'h',
        'g',
        'f',
        'e',
        'd',
        'c',
        'b',
        'a',
      ]);
      final ranks = all.where((l) => l.alignment == Alignment.topRight);
      expect(ranks.map((l) => l.text), [
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
      ]);
    });

    test(
      'the ink alternates with the square so a letter is never on its own colour',
      () {
        final all = labels(BoardCoordinates.inside);
        // a1 is dark: its "a" takes the light-square colour. b1 is light.
        final a = all.singleWhere((l) => l.text == 'a');
        final b = all.singleWhere((l) => l.text == 'b');
        expect(a.color, AppColors.boardLightSquare);
        expect(b.color, AppColors.boardDarkSquare);
        // h1 is light: its "1" takes the dark-square colour.
        final one = all.singleWhere((l) => l.text == '1');
        expect(one.color, AppColors.boardDarkSquare);
      },
    );

    test('every square names itself', () {
      final all = labels(BoardCoordinates.everySquare);
      expect(all, hasLength(64));
      expect(textAt(all, 0, 0), 'a8');
      expect(textAt(all, 7, 7), 'h1');
      expect(textAt(all, 4, 4), 'e4');
      final flipped = labels(BoardCoordinates.everySquare, flipped: true);
      expect(textAt(flipped, 0, 0), 'h1');
      expect(textAt(flipped, 4, 4), 'd5');
    });

    test('outside: labels sit in the margin, not on the squares', () {
      final all = labels(BoardCoordinates.outside, margin: 18);
      expect(all, hasLength(16));
      final files = all.where((l) => l.cell.top == 8 * sq);
      expect(files.map((l) => l.text), [
        'a',
        'b',
        'c',
        'd',
        'e',
        'f',
        'g',
        'h',
      ]);
      expect(files.every((l) => l.cell.height == 18), isTrue);
      final ranks = all.where((l) => l.cell.left == -18);
      expect(ranks.map((l) => l.text), [
        '8',
        '7',
        '6',
        '5',
        '4',
        '3',
        '2',
        '1',
      ]);
      expect(all.every((l) => l.color == AppColors.onSurfaceMuted), isTrue);
    });
  });

  group('coordinateMargin', () {
    test('only the outside mode reserves room, and never on a thumbnail', () {
      expect(coordinateMargin(BoardCoordinates.inside, 400), 0);
      expect(coordinateMargin(BoardCoordinates.everySquare, 400), 0);
      expect(coordinateMargin(BoardCoordinates.outside, 400), 18);
      expect(coordinateMargin(BoardCoordinates.outside, 800), 22);
      expect(coordinateMargin(BoardCoordinates.outside, 250), 14);
      expect(coordinateMargin(BoardCoordinates.outside, 160), 0);
    });
  });

  group('ChessBoardWidget', () {
    Widget board(BoardCoordinates? mode, {double size = 400}) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: ChessBoardWidget(
            position: Chess.initial,
            enableUserMoves: false,
            coordinates: mode,
          ),
        ),
      ),
    );

    List<Offset> pieceOrigins(WidgetTester tester) {
      final origin = tester.getTopLeft(find.byType(ChessBoardWidget));
      return find
          .byType(PieceImage)
          .evaluate()
          .map((el) => tester.getTopLeft(find.byWidget(el.widget)) - origin)
          .toList();
    }

    testWidgets('inside coordinates leave the squares where they were', (
      tester,
    ) async {
      await tester.pumpWidget(board(BoardCoordinates.inside));
      final origins = pieceOrigins(tester);
      expect(origins.map((o) => o.dx).reduce((a, b) => a < b ? a : b), 0);
      expect(origins.map((o) => o.dy).reduce((a, b) => a > b ? a : b), 350);
    });

    testWidgets('outside coordinates shrink the squares into the margin', (
      tester,
    ) async {
      await tester.pumpWidget(board(BoardCoordinates.outside));
      final margin = coordinateMargin(BoardCoordinates.outside, 400);
      final squareSize = (400 - margin) / 8;
      final origins = pieceOrigins(tester);
      expect(
        origins.map((o) => o.dx).reduce((a, b) => a < b ? a : b),
        moreOrLessEquals(margin),
      );
      expect(
        origins.map((o) => o.dy).reduce((a, b) => a > b ? a : b),
        moreOrLessEquals(7 * squareSize),
      );
      // The board still fills its box: the margin came out of the squares.
      expect(
        tester.getSize(find.byType(ChessBoardWidget)),
        const Size(400, 400),
      );
    });

    testWidgets('follows the Display preference when no mode is given', (
      tester,
    ) async {
      final settings = BoardDisplaySettings.fresh(
        coordinates: BoardCoordinates.outside,
      );
      await tester.pumpWidget(
        DisplaySettingsScope(settings: settings, child: board(null)),
      );
      final margin = coordinateMargin(BoardCoordinates.outside, 400);
      expect(
        pieceOrigins(tester).map((o) => o.dx).reduce((a, b) => a < b ? a : b),
        moreOrLessEquals(margin),
      );

      await settings.setCoordinates(BoardCoordinates.inside);
      await tester.pump();
      expect(
        pieceOrigins(tester).map((o) => o.dx).reduce((a, b) => a < b ? a : b),
        0,
      );
    });
  });
}
