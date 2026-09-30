import 'dart:io';

import 'package:chess_auto_prep/app/bundled_licences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers from [texts], and fails for any other asset.
final class _Bundle extends CachingAssetBundle {
  _Bundle(this.texts);

  final Map<String, String> texts;

  @override
  Future<ByteData> load(String key) async {
    final text = texts[key];
    if (text == null) throw FlutterError('no asset $key');
    return ByteData.sublistView(Uint8List.fromList(text.codeUnits));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every bundled licence is a file the release carries', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final (:name, :asset) in bundledLicences) {
      expect(File(asset).existsSync(), isTrue, reason: '$name: $asset');
      final listed =
          pubspec.contains('- $asset\n') ||
          pubspec.contains(
            '- ${asset.substring(0, asset.lastIndexOf('/') + 1)}\n',
          );
      expect(listed, isTrue, reason: '$asset is not a pubspec asset');
    }
  });

  test('the engines, the model and the fonts are all on the page', () {
    final names = bundledLicences.map((l) => l.name).join(' ');
    for (final part in [
      'Stockfish',
      'Hivemind',
      'Maia',
      'Inter',
      'Source Code Pro',
    ]) {
      expect(names, contains(part));
    }
  });

  test(
    'a licence that cannot be read is left out and the rest still show',
    () async {
      LicenseRegistry.reset();
      addTearDown(LicenseRegistry.reset);
      final texts = {
        for (final (:name, :asset) in bundledLicences) asset: '$name terms',
      }..remove(bundledLicences.first.asset);
      registerBundledLicences(_Bundle(texts));
      final entries = await LicenseRegistry.licenses.toList();
      final packages = entries.expand((e) => e.packages).toList();
      expect(packages, isNot(contains(bundledLicences.first.name)));
      expect(
        packages,
        containsAll(texts.values.map((t) => t.replaceAll(' terms', ''))),
      );
    },
  );
}
