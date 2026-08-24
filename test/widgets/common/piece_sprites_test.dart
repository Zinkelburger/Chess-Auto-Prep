/// Guards the bundled piece SVGs that [StaticBoardThumbnail] rasterizes.
///
/// The black pieces are the ones at risk: unlike the white set they carry no
/// `fill` attribute and rely on SVG's default black fill, so a renderer (or an
/// asset edit) that drops that default paints them as nothing — a games list
/// full of boards with only White's pieces on them.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/common/static_board_thumbnail.dart';

/// Mirrors `_PieceSprites._rasterize`.
Future<ui.Image> _rasterize(String assetPath, {int size = 48}) async {
  final info = await vg.loadPicture(SvgAssetLoader(assetPath), null);
  try {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final scale =
        size /
        (info.size.width > info.size.height
            ? info.size.width
            : info.size.height);
    canvas.scale(scale);
    canvas.drawPicture(info.picture);
    return await recorder.endRecording().toImage(size, size);
  } finally {
    info.picture.dispose();
  }
}

Future<int> _opaquePixels(ui.Image image) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  var opaque = 0;
  for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
    if (bytes.getUint8(i) > 8) opaque++;
  }
  return opaque;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every piece sprite rasterizes to visible pixels', () async {
    for (final color in const ['w', 'b']) {
      for (final role in const ['K', 'Q', 'R', 'B', 'N', 'P']) {
        final key = '$color$role';
        final opaque = await _opaquePixels(
          await _rasterize('assets/pieces/$key.svg'),
        );
        expect(
          opaque,
          greaterThan(100),
          reason: '$key rasterized blank — thumbnails would omit it',
        );
      }
    }
  });

  group('sprite resolution tracks the square it has to fill', () {
    test('never hands back a raster smaller than the square', () {
      // Every size/DPR pair the app can realistically ask for. The old code
      // answered a flat 48 to all of them, so anything past 48 was upscaled.
      for (final boardSize in const [60.0, 144.0, 240.0, 512.0]) {
        for (final dpr in const [1.0, 1.5, 2.0, 2.625, 3.0]) {
          final squareDevicePx = boardSize / 8 * dpr;
          final bucket = spriteBucketFor(squareDevicePx);
          if (squareDevicePx > maxSpriteBucket) continue;
          expect(
            bucket,
            greaterThanOrEqualTo(squareDevicePx.ceil()),
            reason:
                'board $boardSize @${dpr}x needs $squareDevicePx device px a '
                'square but would draw a $bucket px sprite',
          );
        }
      }
    });

    test('device pixel ratio moves the answer once it matters', () {
      // The regression itself: the raster has to follow the display. A
      // game-card square (18 logical px) is covered by the floor raster at 1x
      // and 2x alike; a larger preview is where the ratio starts to count, and
      // where a single hard-coded size was upscaling.
      const square = 512 / 8;
      expect(spriteBucketFor(square * 2), greaterThan(spriteBucketFor(square)));
    });

    test('picks the smallest covering raster, not simply the largest', () {
      expect(spriteBucketFor(18), lessThan(maxSpriteBucket));
      expect(spriteBucketFor(1), spriteBucketFor(2));
    });

    test('is monotonic and capped', () {
      var previous = 0;
      for (var px = 1.0; px < 400; px += 3) {
        final bucket = spriteBucketFor(px);
        expect(bucket, greaterThanOrEqualTo(previous));
        expect(bucket, lessThanOrEqualTo(maxSpriteBucket));
        previous = bucket;
      }
    });
  });
}
