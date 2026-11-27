import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chess_auto_prep/engines/hypebeast_install.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A build's bughouse assets: each installed file a few bytes of its own
/// name, gzipped, with a manifest of their sizes and hashes.
final class Bundle {
  Bundle() {
    for (final name in HypeBeastInstall.installedNames) {
      files[name] = utf8.encode('contents of $name');
    }
  }

  final files = <String, List<int>>{};
  final reads = <String>[];

  /// Overrides what a manifest record says.
  final lies = <String, Map<String, Object>>{};
  bool withManifest = true;

  String get manifest => jsonEncode({
    for (final name in HypeBeastInstall.installedNames)
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

const _net = HypeBeastInstall.net;

void main() {
  late Directory support;
  late Bundle bundle;
  late HypeBeastInstall install;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('hypebeast-install-');
    bundle = Bundle();
    install = HypeBeastInstall(
      supportDirectory: support,
      readAsset: bundle.read,
    );
  });

  tearDown(() => support.delete(recursive: true));

  File installed(String name) => File(p.join(support.path, 'bughouse', name));

  test('installs every file into bughouse/ and says where', () async {
    final located = await install.locate() as HypeBeastReady;
    expect(located.files.directory, p.join(support.path, 'bughouse'));
    expect(p.basename(located.files.net), 'bughouse-cd8cceab93fe.nnue');
    expect(located.files.executable, startsWith(located.files.directory));
    for (final name in HypeBeastInstall.installedNames) {
      expect(await installed(name).readAsString(), 'contents of $name');
    }
  });

  test('two launches during the first install share one install', () async {
    // The Bughouse mode starting its engine while a match start is still
    // unpacking: each launch makes its own install.
    final both = await Future.wait([
      install.locate(),
      HypeBeastInstall(
        supportDirectory: support,
        readAsset: bundle.read,
      ).locate(),
    ]);
    expect(both, everyElement(isA<HypeBeastReady>()));
    expect(
      bundle.reads.where((asset) => asset.endsWith('.gz')),
      hasLength(HypeBeastInstall.installedNames.length),
      reason: 'each file unpacked once',
    );
    for (final name in HypeBeastInstall.installedNames) {
      expect(await installed(name).readAsString(), 'contents of $name');
    }
    final left = await Directory(
      p.join(support.path, 'bughouse'),
    ).list().map((entry) => p.basename(entry.path)).toList();
    expect(left.where((name) => name.endsWith('.part')), isEmpty);
  });

  test('a sound install is checked, not written again', () async {
    await install.locate();
    bundle.reads.clear();
    expect(await install.locate(), isA<HypeBeastReady>());
    expect(bundle.reads, ['assets/bughouse/manifest.json']);
  });

  test('a damaged file of the same size is found and replaced', () async {
    await install.locate();
    final net = installed(_net);
    final size = (await net.readAsBytes()).length;
    await net.writeAsBytes(List.filled(size, 0));
    expect(await install.locate(), isA<HypeBeastReady>());
    expect(await net.readAsString(), 'contents of $_net');
  });

  test('an asset that does not match its manifest replaces nothing', () async {
    await install.locate();
    bundle.files[_net] = utf8.encode('a different net');
    // The manifest still promises the old bytes, and the installed copy is
    // gone: the new asset is refused rather than trusted.
    await installed(_net).delete();
    bundle.lies[_net] = {
      'bytes': utf8.encode('contents of $_net').length,
      'sha256': sha256.convert(utf8.encode('contents of $_net')).toString(),
    };
    final located = await install.locate() as HypeBeastMissing;
    expect(located.reason, contains('does not match its manifest'));
    expect(await installed(_net).exists(), isFalse);
  });

  test('a build without the engine, or a damaged manifest, says so', () async {
    bundle.withManifest = false;
    expect(
      (await install.locate() as HypeBeastMissing).reason,
      'This build has no bughouse engine.',
    );
    bundle.withManifest = true;
    bundle.lies[_net] = {'bytes': -1, 'sha256': 'nope'};
    expect(
      (await install.locate() as HypeBeastMissing).reason,
      contains('manifest is damaged'),
    );
  });

  test('a manifest that promises an empty file is damaged; a one-byte file '
      'is a file', () async {
    bundle.lies[_net] = {'bytes': 0, 'sha256': 'a' * 64};
    expect(
      (await install.locate() as HypeBeastMissing).reason,
      contains('manifest is damaged'),
    );
    bundle.lies.clear();
    bundle.files[_net] = [7];
    expect(await install.locate(), isA<HypeBeastReady>());
  });

  test('an hour-old install is kept; only a half-written copy left an hour '
      'ago is cleared', () async {
    await install.locate();
    final engine = installed(_net);
    final old = DateTime.now().subtract(const Duration(hours: 2));
    await engine.setLastModified(old);
    final stale = File('${engine.path}.part')..writeAsStringSync('half');
    await stale.setLastModified(old);
    final fresh = File(p.join(support.path, 'bughouse', 'other.part'))
      ..writeAsStringSync('still going');
    bundle.reads.clear();
    expect(await install.locate(), isA<HypeBeastReady>());
    expect(bundle.reads, ['assets/bughouse/manifest.json']);
    expect(await engine.lastModified(), old);
    expect(await stale.exists(), isFalse);
    expect(await fresh.exists(), isTrue);
  });

  test('what Hivemind left in the folder is removed, by name alone', () async {
    final folder = Directory(p.join(support.path, 'bughouse'))
      ..createSync(recursive: true);
    final former = [
      'hivemind-linux',
      'hivemind-windows.exe',
      'hivemind.onnx',
      'libonnxruntime.so.1',
      'hivemind_ort.dll',
      'MSVCP140.dll',
    ];
    for (final name in former) {
      File(p.join(folder.path, name)).writeAsStringSync('old');
    }
    final kept = File(p.join(folder.path, 'notes.txt'))
      ..writeAsStringSync('the user\'s');
    expect(await install.locate(), isA<HypeBeastReady>());
    for (final name in former) {
      expect(
        File(p.join(folder.path, name)).existsSync(),
        isFalse,
        reason: name,
      );
    }
    expect(kept.existsSync(), isTrue);
  });

  test('the engine is made runnable off Windows', () async {
    final located = await install.locate() as HypeBeastReady;
    if (Platform.isWindows) return;
    final mode = (await File(located.files.executable).stat()).mode;
    expect(mode & 0x40, isNot(0), reason: 'owner may execute');
  });

  test('installs into a support folder that is not there yet', () async {
    final deeper = HypeBeastInstall(
      supportDirectory: Directory(p.join(support.path, 'new', 'deeper')),
      readAsset: bundle.read,
    );
    expect(await deeper.locate(), isA<HypeBeastReady>());
  });

  test('a missing file in the build is named', () async {
    bundle.files.remove(_net);
    bundle.lies[_net] = {'bytes': 5, 'sha256': 'a' * 64};
    expect(
      (await install.locate() as HypeBeastMissing).reason,
      'This build is missing $_net.',
    );
  });

  test(
    'the mode is offered only when both files and the manifest are built in',
    () {
      final keys = [
        for (final name in HypeBeastInstall.installedNames)
          'assets/bughouse/$name.gz',
        'assets/bughouse/manifest.json',
      ];
      expect(HypeBeastInstall.bundledIn(keys), isTrue);
      expect(HypeBeastInstall.bundledIn(keys.skip(1)), isFalse);
    },
  );

  test('a leftover another copy of the app renamed away is skipped', () async {
    final root = await Directory.systemTemp.createTemp('hypebeast-sweep-');
    addTearDown(() => root.delete(recursive: true));
    final gone = File(p.join(root.path, 'bughouse-cd8cceab93fe.nnue.123.part'));
    await expectLater(removeStaleLeftover(gone, DateTime.now()), completes);
    final old = File(p.join(root.path, 'bughouse-cd8cceab93fe.nnue.456.part'));
    await old.writeAsString('half');
    await old.setLastModified(DateTime(2020));
    await removeStaleLeftover(old, DateTime.now());
    expect(await old.exists(), isFalse);
  });
}
