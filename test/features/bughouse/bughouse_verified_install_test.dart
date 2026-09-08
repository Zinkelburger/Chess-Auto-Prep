import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/bughouse/services/bughouse_bundle.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Profile extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Profile(this.directory);
  final String directory;
  @override
  Future<String?> getApplicationSupportPath() async => directory;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform original;
  late Map<String, dynamic> manifest;
  late Map<String, Uint8List> payloads;
  setUp(() async {
    rootBundle.evict('assets/bughouse/manifest.json');
    root = await Directory.systemTemp.createTemp('verified-engine-install-');
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Profile(root.path);
    payloads = {
      for (final name in BughouseBundle.installedFileNames)
        name: Uint8List.fromList(utf8.encode('fixture for $name')),
    };
    manifest = {
      for (final entry in payloads.entries)
        entry.key: {
          'bytes': entry.value.length,
          'sha256': sha256.convert(entry.value).toString(),
        },
    };
    binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (
      message,
    ) async {
      final name = utf8.decode(
        message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        ),
      );
      final bytes = name.endsWith('manifest.json')
          ? utf8.encode(jsonEncode(manifest))
          : gzip.encode(
              payloads[p.basename(name).replaceFirst(RegExp(r'\.gz$'), '')]!,
            );
      return ByteData.sublistView(Uint8List.fromList(bytes));
    });
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      null,
    );
    PathProviderPlatform.instance = original;
    await root.delete(recursive: true);
  });

  test(
    'cached installation is rehashed and repaired before the next launch',
    () async {
      final engine = await BughouseBundle.ensureInstalled();
      final installed = File(engine);
      final bytes = await installed.readAsBytes();
      bytes[bytes.length - 1] ^= 0xff;
      await installed.writeAsBytes(bytes);
      await BughouseBundle.ensureInstalled();
      expect(await installed.readAsBytes(), payloads[p.basename(engine)]);
      expect(
        BughouseBundle.installationDiagnostics.join('\n'),
        contains('mismatch'),
      );
      await File(
        p.join(
          BughouseBundle.libraryPath!,
          BughouseBundle.installedFileNames[1],
        ),
      ).delete();
      await BughouseBundle.ensureInstalled();
      expect(
        await File(
          p.join(
            BughouseBundle.libraryPath!,
            BughouseBundle.installedFileNames[1],
          ),
        ).exists(),
        isTrue,
      );
    },
    skip: Platform.isWindows
        ? 'synthetic payloads are not native Windows binaries; native repair has an integration test'
        : null,
  );

  test('a missing checksum cannot silently disable verification', () async {
    final name = payloads.keys.first;
    (manifest[name] as Map).remove('sha256');
    try {
      await BughouseBundle.ensureInstalled();
      fail('expected verification failure');
    } on BughouseBundleBroken catch (e) {
      final report = BughouseEngine.unavailableReport(e);
      expect(report, contains('Missing size/SHA-256 for $name'));
      expect(report, contains(root.path));
      expect(report, endsWith('END BUGHOUSE DIAGNOSTICS'));
    }
  });

  test(
    'bad bundled payload is rejected before replacing an existing file',
    () async {
      final name = payloads.keys.first;
      final target = File(p.join(root.path, 'bughouse', name));
      await target.parent.create();
      await target.writeAsString('existing file');
      (manifest[name] as Map)['sha256'] = '0' * 64;
      await expectLater(
        BughouseBundle.ensureInstalled(),
        throwsA(
          isA<BughouseBundleBroken>().having(
            (e) => e.message,
            'hash error',
            contains('decoded SHA-256'),
          ),
        ),
      );
      expect(await target.readAsString(), 'existing file');
    },
  );
}
