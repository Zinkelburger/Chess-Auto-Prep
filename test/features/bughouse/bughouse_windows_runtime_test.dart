import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chess_auto_prep/features/bughouse/services/bughouse_bundle.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_windows_runtime.dart';
import 'package:chess_auto_prep/features/bughouse/services/windows_loader_check.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory app;
  late Directory target;
  late Directory archive;
  late Uint8List payload;
  late Map<String, dynamic> manifest;

  Future<List<String>> install() =>
      BughouseBundle.installWindowsRuntime(source: app, target: target);
  File installed(String name) => File(p.join(target.path, name));
  Future<void> saveManifest() async {
    await File(
      p.join(archive.path, 'manifest.json'),
    ).writeAsString(jsonEncode(manifest));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('verified-vc-');
    app = await Directory(p.join(root.path, 'app')).create();
    target = await Directory(p.join(root.path, 'engine')).create();
    archive = await BughouseWindowsRuntime.archiveDirectory(
      app,
    ).create(recursive: true);
    payload = Uint8List(512)
      ..[0] = 0x4d
      ..[1] = 0x5a;
    final data = ByteData.sublistView(payload);
    data.setUint32(0x3c, 0x80, Endian.little);
    payload[0x80] = 0x50;
    payload[0x81] = 0x45;
    data.setUint16(0x84, 0x8664, Endian.little);
    data.setUint16(0x98, 0x20b, Endian.little);
    manifest = {};
    for (final name in WindowsLoaderCheck.appSuppliedDependencies.map(
      (n) => n.toLowerCase(),
    )) {
      manifest[name] = {
        'bytes': payload.length,
        'sha256': sha256.convert(payload).toString(),
      };
      await File(
        p.join(archive.path, '$name.gz'),
      ).writeAsBytes(gzip.encode(payload));
    }
    await saveManifest();
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'installs all four dependencies without loose app DLLs or system files',
    () async {
      final checks = await install();
      for (final name in manifest.keys) {
        expect(await installed(name).readAsBytes(), payload);
      }
      expect(
        checks.where((l) => l.contains('replaced and verified')),
        hasLength(4),
      );
      expect((await install()).where((l) => l.contains('replaced')), isEmpty);
    },
  );

  test(
    'repairs same-size damage and missing DLLs on a repeated check',
    () async {
      await install();
      final altered = Uint8List.fromList(payload)..[300] ^= 0xff;
      await installed('msvcp140.dll').writeAsBytes(altered);
      await installed('vcruntime140.dll').delete();
      final checks = await install();
      expect(await installed('msvcp140.dll').readAsBytes(), payload);
      expect(await installed('vcruntime140.dll').readAsBytes(), payload);
      expect(
        checks.where((l) => l.contains('replaced and verified')),
        hasLength(2),
      );
    },
  );

  test(
    'wrong bundled hash stops repair before deleting the existing file',
    () async {
      final existing = [1, 2, 3];
      await installed('msvcp140.dll').writeAsBytes(existing);
      await File(
        p.join(archive.path, 'msvcp140.dll.gz'),
      ).writeAsBytes(gzip.encode([9, 9]));
      await expectLater(
        install(),
        throwsA(
          isA<BughouseRuntimeFailure>().having(
            (e) => e.lines.join('\n'),
            'evidence',
            allOf(
              contains('Bundled DLL mismatch'),
              contains('msvcp140.dll.gz'),
              contains('SHA-256'),
            ),
          ),
        ),
      );
      expect(await installed('msvcp140.dll').readAsBytes(), existing);
    },
  );

  test(
    'a wrong-architecture archive is rejected even if its hash matches',
    () async {
      final x86 = Uint8List.fromList(payload);
      ByteData.sublistView(x86).setUint16(0x84, 0x14c, Endian.little);
      manifest['msvcp140.dll']['sha256'] = sha256.convert(x86).toString();
      await saveManifest();
      await File(
        p.join(archive.path, 'msvcp140.dll.gz'),
      ).writeAsBytes(gzip.encode(x86));
      await expectLater(
        install(),
        throwsA(
          isA<BughouseRuntimeFailure>().having(
            (e) => e.message,
            'machine',
            contains('Expected x64'),
          ),
        ),
      );
      expect(await installed('msvcp140.dll').exists(), isFalse);
    },
  );

  test(
    'failed replacement stops launch and retains the OS error and path',
    () async {
      await Directory(installed('msvcp140.dll').path).create();
      await expectLater(
        install(),
        throwsA(
          isA<BughouseRuntimeFailure>().having(
            (e) => e.message,
            'OS error',
            allOf(
              contains('OS Error:'),
              contains('errno ='),
              contains(installed('msvcp140.dll').path),
            ),
          ),
        ),
      );
    },
  );

  test(
    'missing manifest cannot fall back to an unverified system runtime',
    () async {
      await File(p.join(archive.path, 'manifest.json')).delete();
      await expectLater(
        install(),
        throwsA(
          isA<BughouseRuntimeFailure>().having(
            (e) => e.message,
            'manifest',
            contains('manifest.json'),
          ),
        ),
      );
    },
  );

  test(
    'missing required record is an error even with other DLLs installed',
    () async {
      manifest.remove('vcruntime140.dll');
      await saveManifest();
      await expectLater(
        install(),
        throwsA(
          isA<BughouseRuntimeFailure>().having(
            (e) => e.message,
            'missing dependency',
            contains('Missing VCRUNTIME140.dll'),
          ),
        ),
      );
    },
  );

  test(
    'manifest cannot address files outside the private engine folder',
    () async {
      manifest['../msvcp140.dll'] = manifest['msvcp140.dll'];
      await saveManifest();
      await expectLater(
        install(),
        throwsA(
          isA<BughouseRuntimeFailure>().having(
            (e) => e.message,
            'path validation',
            contains('Invalid DLL name'),
          ),
        ),
      );
    },
  );

  test(
    'removes obsolete private VC++ copies and leaves other files alone',
    () async {
      await installed('msvcp140_old.dll').writeAsBytes([1]);
      await installed('notes.txt').writeAsString('keep');
      await install();
      expect(await installed('msvcp140_old.dll').exists(), isFalse);
      expect(await installed('notes.txt').readAsString(), 'keep');
    },
  );
}
