import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../diagnostics/log.dart';

/// What ships in the app that is not a Dart package: engines, a model,
/// fonts, piece images and data, each with the licence file bundled
/// beside it.
///
/// Flutter's [LicenseRegistry] already holds every Dart package's licence
/// and the engine's own; these are the rest, so the licence page lists
/// everything a release contains. A new bundled binary, model or font gets
/// a line here and its licence file under `assets/`.
const bundledLicences = <({String name, String asset})>[
  (name: 'Stockfish engine', asset: 'assets/licenses/STOCKFISH_LICENSE.txt'),
  (
    name: 'Hivemind bughouse engine',
    asset: 'assets/licenses/HIVEMIND_LICENSE.txt',
  ),
  (name: 'Maia 3', asset: 'assets/licenses/MAIA3_LICENSE.txt'),
  (name: 'ONNX Runtime', asset: 'assets/licenses/ONNXRUNTIME_LICENSE.txt'),
  (
    name: 'ONNX Runtime third-party notices',
    asset: 'assets/licenses/ONNXRUNTIME_THIRD_PARTY_NOTICES.txt',
  ),
  (name: 'Inter font', asset: 'assets/fonts/LICENSE-Inter.txt'),
  (
    name: 'Source Code Pro font',
    asset: 'assets/fonts/LICENSE-SourceCodePro.txt',
  ),
  (
    name: 'Noto Sans Symbols 2 font',
    asset: 'assets/fonts/LICENSE-NotoSansSymbols2.txt',
  ),
  (
    name: 'cburnett chess pieces',
    asset: 'assets/licenses/CBURNETT_PIECES_LICENSE.txt',
  ),
  (
    name: 'lichess chess-openings (opening names)',
    asset: 'assets/data/openings/COPYING.txt',
  ),
];

/// Adds [bundledLicences] to the licence page. The files are read when the
/// page is first opened, not at start; one that cannot be read is logged
/// and left out, and the page still opens with the rest.
void registerBundledLicences([AssetBundle? bundle]) {
  final assets = bundle ?? rootBundle;
  LicenseRegistry.addLicense(() async* {
    for (final (:name, :asset) in bundledLicences) {
      final String text;
      try {
        text = await assets.loadString(asset);
      } catch (error) {
        log.w('Read the licence $asset', error);
        continue;
      }
      yield LicenseEntryWithLineBreaks([name], text);
    }
  });
}
