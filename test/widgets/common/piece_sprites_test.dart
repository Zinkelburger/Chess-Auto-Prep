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
}
