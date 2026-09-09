import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chess_auto_prep/services/engine/stockfish_bundle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('lock key matches this OS', () {
    if (Platform.isLinux) {
      expect(stockfishLockKey(), 'stockfish-linux');
      expect(stockfishBinaryName(), 'stockfish-linux');
    } else if (Platform.isWindows) {
      expect(stockfishLockKey(), 'stockfish-windows');
      expect(stockfishBinaryName(), 'stockfish-windows.exe');
    } else if (Platform.isMacOS) {
      expect(stockfishBinaryName(), 'stockfish-macos');
      expect(
        stockfishLockKey(),
        anyOf('stockfish-macos-arm64', 'stockfish-macos-x86_64'),
      );
    }
  });

  test('largest zip member is the engine-sized file', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('docs/Copying.txt', [1, 2, 3]))
      ..addFile(ArchiveFile.bytes('stockfish/stockfish', List.filled(50, 7)));
    final zip = ZipEncoder().encode(archive);
    final got = stockfishLargestArchiveMember(
      Uint8List.fromList(zip),
      'https://example/stockfish-windows-x86-64.zip',
    );
    expect(got, List.filled(50, 7));
  });

  test('largest tar member is the engine-sized file', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('stockfish/README.md', [9]))
      ..addFile(
        ArchiveFile.bytes('stockfish/stockfish-linux', List.filled(40, 4)),
      );
    final tar = TarEncoder().encode(archive);
    final got = stockfishLargestArchiveMember(
      Uint8List.fromList(tar),
      'https://example/stockfish-ubuntu-x86-64.tar',
    );
    expect(got, List.filled(40, 4));
  });

  test('extracts the Stockfish 19 tar.gz download', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('stockfish/README.md', [9]))
      ..addFile(
        ArchiveFile.bytes(
          'stockfish/stockfish-linux-x86-64-universal',
          List.filled(40, 4),
        ),
      );
    final compressed = gzip.encode(TarEncoder().encode(archive));
    expect(
      stockfishLargestArchiveMember(
        Uint8List.fromList(compressed),
        'https://example/stockfish-linux-x86-64-universal.tar.gz',
      ),
      List.filled(40, 4),
    );
  });

  group('installed engine upgrades', () {
    late Directory dir;
    late PathProviderPlatform originalPaths;
    late List<int> bundled;
    late Map<String, Object> lockEntry;
    var assetLoads = 0;
    const sourceHash = 'release-19-source-hash';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() async {
      StockfishBundle.resetForTest();
      dir = await Directory.systemTemp.createTemp('stockfish-upgrade-');
      originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(dir.path);
      bundled = gzip.encode(utf8.encode('new engine'));
      lockEntry = {
        'source_sha256': sourceHash,
        'output_sha256': sha256.convert(bundled).toString(),
        'url': 'https://example.invalid/stockfish.tar.gz',
      };
      assetLoads = 0;
      messenger.setMockMessageHandler('flutter/assets', (message) async {
        final key = utf8.decode(
          message!.buffer.asUint8List(
            message.offsetInBytes,
            message.lengthInBytes,
          ),
        );
        if (key == kStockfishLockAsset) {
          return ByteData.sublistView(
            Uint8List.fromList(
              utf8.encode(jsonEncode({stockfishLockKey(): lockEntry})),
            ),
          );
        }
        if (key == 'assets/executables/${stockfishBinaryName()}.gz') {
          assetLoads++;
          return ByteData.sublistView(Uint8List.fromList(bundled));
        }
        return null;
      });
    });

    tearDown(() async {
      messenger.setMockMessageHandler('flutter/assets', null);
      PathProviderPlatform.instance = originalPaths;
      StockfishBundle.resetForTest();
      await dir.delete(recursive: true);
    });

    for (final previous in [
      'missing',
      'unstamped',
      'platform-only',
      'older-release',
      'current',
    ]) {
      test('installs or reuses engine with $previous stamp', () async {
        final binary = File(p.join(dir.path, stockfishBinaryName()));
        final stamp = File('${binary.path}.origin');
        final identity = '${stockfishLockKey()}:$sourceHash';
        if (previous != 'missing') {
          await binary.writeAsString('existing engine');
        }
        if (previous == 'platform-only') {
          await stamp.writeAsString(stockfishLockKey());
        }
        if (previous == 'older-release') {
          await stamp.writeAsString(
            '${stockfishLockKey()}:release-18-source-hash',
          );
        }
        if (previous == 'current') await stamp.writeAsString(identity);

        expect(await StockfishBundle.ensureExecutable(), binary.path);
        expect(
          await binary.readAsString(),
          previous == 'current' ? 'existing engine' : 'new engine',
        );
        expect(await stamp.readAsString(), identity);
        expect(assetLoads, previous == 'current' ? 0 : 1);
        // Pool workers reuse the installed executable without another extraction.
        await StockfishBundle.ensureExecutable();
        expect(assetLoads, previous == 'current' ? 0 : 1);
      });
    }

    test('does not stamp a stale bundled asset as the new release', () async {
      bundled = gzip.encode(utf8.encode('old bundle'));
      await expectLater(StockfishBundle.ensureExecutable(), throwsStateError);
      expect(
        await File(
          p.join(dir.path, '${stockfishBinaryName()}.origin'),
        ).exists(),
        isFalse,
      );
    });
  });
}
