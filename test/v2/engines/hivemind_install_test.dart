import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chess_auto_prep/v2/engines/hivemind_install.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A build's bughouse assets: each installed file a few bytes of its own
/// name, gzipped, with a manifest of their sizes and hashes.
final class Bundle {
  Bundle() {
    for (final name in HivemindInstall.installedNames) {
      files[name] = utf8.encode('contents of $name');
    }
  }

  final files = <String, List<int>>{};
  final reads = <String>[];

  /// Overrides what a manifest record says.
  final lies = <String, Map<String, Object>>{};
  bool withManifest = true;

  String get manifest => jsonEncode({
    for (final name in HivemindInstall.installedNames)
      name: lies[name] ?? _record(files[name]!),
  });

  static Map<String, Object> _record(List<int> bytes) => {
    'bytes': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };

  Future<Uint8List?> read(String asset) async {
    reads.add(asset);
    if (asset == 'assets/bughouse/manifest.json') {
      return withManifest ? utf8.encode(manifest) : null;
    }
    final name = p.basenameWithoutExtension(asset);
    final bytes = files[name];
    return bytes == null ? null : Uint8List.fromList(gzip.encode(bytes));
  }
}

void main() {
  late Directory support;
  late Bundle bundle;
  late HivemindInstall install;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('v2-hivemind-');
    bundle = Bundle();
    install = HivemindInstall(
      supportDirectory: support,
      readAsset: bundle.read,
    );
  });

  tearDown(() => support.delete(recursive: true));

  File installed(String name) => File(p.join(support.path, 'bughouse', name));

  test('installs every file into bughouse/ and says where', () async {
    final located = await install.locate() as HivemindReady;
    expect(located.files.directory, p.join(support.path, 'bughouse'));
    expect(p.basename(located.files.model), 'hivemind.onnx');
    for (final name in HivemindInstall.installedNames) {
      expect(await installed(name).readAsString(), 'contents of $name');
    }
  });

  test('a sound install is checked, not written again', () async {
    await install.locate();
    bundle.reads.clear();
    expect(await install.locate(), isA<HivemindReady>());
    expect(bundle.reads, ['assets/bughouse/manifest.json']);
  });

  test('a damaged file of the same size is found and replaced', () async {
    await install.locate();
    final network = installed('hivemind.onnx');
    final size = (await network.readAsBytes()).length;
    await network.writeAsBytes(List.filled(size, 0));
    expect(await install.locate(), isA<HivemindReady>());
    expect(await network.readAsString(), 'contents of hivemind.onnx');
  });

  test('an asset that does not match its manifest replaces nothing', () async {
    await install.locate();
    bundle.files['hivemind.onnx'] = utf8.encode('a different network');
    // The manifest still promises the old bytes, and the installed copy is
    // gone: the new asset is refused rather than trusted.
    await installed('hivemind.onnx').delete();
    bundle.lies['hivemind.onnx'] = {
      'bytes': 26,
      'sha256': sha256
          .convert(utf8.encode('contents of hivemind.onnx'))
          .toString(),
    };
    final located = await install.locate() as HivemindMissing;
    expect(located.reason, contains('does not match its manifest'));
    expect(await installed('hivemind.onnx').exists(), isFalse);
  });

  test('a build without the engine, or a damaged manifest, says so', () async {
    bundle.withManifest = false;
    expect(
      (await install.locate() as HivemindMissing).reason,
      'This build has no bughouse engine.',
    );
    bundle.withManifest = true;
    bundle.lies['hivemind.onnx'] = {'bytes': -1, 'sha256': 'nope'};
    expect(
      (await install.locate() as HivemindMissing).reason,
      contains('manifest is damaged'),
    );
  });

  test('a missing file in the build is named', () async {
    bundle.files.remove('hivemind.onnx');
    bundle.lies['hivemind.onnx'] = {'bytes': 5, 'sha256': 'a' * 64};
    expect(
      (await install.locate() as HivemindMissing).reason,
      'This build is missing hivemind.onnx.',
    );
  });

  test('the mode is offered only when all four assets are built in', () {
    final keys = [
      for (final name in HivemindInstall.installedNames)
        'assets/bughouse/$name.gz',
      'assets/bughouse/manifest.json',
    ];
    expect(HivemindInstall.bundledIn(keys), isTrue);
    expect(HivemindInstall.bundledIn(keys.skip(1)), isFalse);
  });
}
