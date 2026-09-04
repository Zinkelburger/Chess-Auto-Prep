import 'package:chess_auto_prep/services/bundled_licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registers the bundled Hivemind notice', () async {
    registerBundledLicenses();

    final entries = await LicenseRegistry.licenses.toList();
    final hivemind = entries.singleWhere(
      (entry) => entry.packages.contains('Hivemind bughouse engine'),
    );
    final paragraphs = hivemind.paragraphs.map((p) => p.text).join('\n');

    expect(paragraphs, contains('Copyright (c) 2026 aminwoo'));
    expect(paragraphs, contains('MIT License'));
    expect(paragraphs, contains('https://github.com/aminwoo/hivemind'));
  });
}
