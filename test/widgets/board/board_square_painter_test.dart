import 'dart:ui' as ui;

import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/widgets/board/board_square_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<int>> raster(BoardSquarePainter painter, int pixels) async {
  final recorder = ui.PictureRecorder();
  // Exercise fractional logical squares at a fractional display scale.
  final canvas = Canvas(recorder)..scale(1.25);
  painter.paint(canvas, Size.square(pixels / 1.25));
  final picture = recorder.endRecording();
  final image = await picture.toImage(pixels, pixels);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = bytes!.buffer.asUint32List().toList();
  image.dispose();
  picture.dispose();
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final flipped in [false, true]) {
    for (final pixels in [320, 683]) {
      test(
        'd7 selection stays within its cells ($pixels px, flipped=$flipped)',
        () async {
          final plain = await raster(
            BoardSquarePainter(flipped: flipped),
            pixels,
          );
          final selected = await raster(
            BoardSquarePainter(
              flipped: flipped,
              selectedSquare: 'd7',
              legalMoveSquares: {'d6', 'd5'},
            ),
            pixels,
          );
          final side = pixels / 8;
          final col = flipped ? 4 : 3;
          final rows = flipped ? [6, 5, 4] : [1, 2, 3];
          final cells = [
            for (final row in rows)
              Rect.fromLTRB(
                col * side,
                row * side,
                (col + 1) * side,
                (row + 1) * side,
              ),
          ];
          var changes = 0;
          for (var y = 0; y < pixels; y++) {
            for (var x = 0; x < pixels; x++) {
              final i = y * pixels + x;
              if (plain[i] == selected[i]) continue;
              changes++;
              expect(
                cells.any(
                  // A pixel center exactly on a tile edge may belong to either
                  // adjacent tile; tolerate the tie, not a whole extra pixel.
                  (cell) =>
                      cell.inflate(0.001).contains(Offset(x + 0.5, y + 0.5)),
                ),
                isTrue,
                reason: 'selection leaked beyond d7/d6/d5 at ($x, $y)',
              );
            }
          }
          expect(changes, greaterThan(0));
          // A legal target is tinted edge to edge — corner and centre alike,
          // and to one flat colour, not a marker over a background.
          for (final cell in cells.skip(1)) {
            final corner = cell.topLeft + Offset(side * .15, side * .15);
            final center = cell.center;
            final cornerIndex = corner.dy.floor() * pixels + corner.dx.floor();
            final centerIndex = center.dy.floor() * pixels + center.dx.floor();
            expect(selected[cornerIndex], isNot(plain[cornerIndex]));
            expect(selected[centerIndex], selected[cornerIndex]);
          }
        },
      );
    }
  }

  test('a legal destination tints its own square and no other', () async {
    final plain = await raster(BoardSquarePainter(outlineWidth: 0), 320);
    final target = await raster(
      BoardSquarePainter(legalMoveSquares: {'d5'}, outlineWidth: 0),
      320,
    );
    int at(List<int> image, int x, int y) => image[y * 320 + x];
    // d5 spans x 120..160, y 120..160 unflipped.
    for (final (x, y) in [(123, 123), (140, 140), (157, 157)]) {
      expect(at(target, x, y), isNot(at(plain, x, y)));
      expect(at(target, x, y), at(target, 140, 140));
    }
    // Its neighbours are untouched: no border, no bleed.
    for (final (x, y) in [(118, 140), (162, 140), (140, 118), (140, 162)]) {
      expect(at(target, x, y), at(plain, x, y));
    }
  });

  test(
    'fractional squares have no transparent seams or blended tile edges',
    () async {
      final pixels = await raster(BoardSquarePainter(outlineWidth: 0), 683);
      int rgba(Color c) {
        final argb = c.toARGB32();
        return (argb & 0xff00ff00) |
            ((argb >> 16) & 0xff) |
            ((argb & 0xff) << 16);
      }

      expect(pixels.toSet(), {
        rgba(AppColors.boardLightSquare),
        rgba(AppColors.boardDarkSquare),
      });
    },
  );

  test('selection and explicit hints have stable tint precedence', () async {
    final selected = await raster(
      BoardSquarePainter(selectedSquare: 'd7'),
      320,
    );
    final overlap = await raster(
      BoardSquarePainter(
        selectedSquare: 'd7',
        highlightedSquares: {'d7'},
        recentMoveSquares: {'d7'},
        legalMoveSquares: {'d7'},
      ),
      320,
    );
    expect(overlap, selected);
    final hint = await raster(
      BoardSquarePainter(highlightedSquares: {'d7'}),
      320,
    );
    final recentHint = await raster(
      BoardSquarePainter(highlightedSquares: {'d7'}, recentMoveSquares: {'d7'}),
      320,
    );
    expect(recentHint, hint);
    // A hint keeps its colour when the square is also a legal destination,
    // and a destination keeps its colour over the recent-move trail.
    expect(
      await raster(
        BoardSquarePainter(
          highlightedSquares: {'d7'},
          legalMoveSquares: {'d7'},
        ),
        320,
      ),
      hint,
    );
    final target = await raster(
      BoardSquarePainter(legalMoveSquares: {'d7'}),
      320,
    );
    expect(
      await raster(
        BoardSquarePainter(legalMoveSquares: {'d7'}, recentMoveSquares: {'d7'}),
        320,
      ),
      target,
    );
    expect(target, isNot(hint));
  });

  test('paint state snapshots mutable inputs and compares contents', () {
    final targets = {'d6'};
    final old = BoardSquarePainter(legalMoveSquares: targets);
    targets.add('d5');
    expect(old.legalMoveSquares, {'d6'});
    expect(
      BoardSquarePainter(legalMoveSquares: targets).shouldRepaint(old),
      isTrue,
    );
    expect(
      BoardSquarePainter(legalMoveSquares: {'d6'}).shouldRepaint(old),
      isFalse,
    );
    expect(
      BoardSquarePainter(
        legalMoveSquares: {'d6'},
        recentMoveSquares: {'d6'},
      ).shouldRepaint(old),
      isTrue,
    );
  });
}
