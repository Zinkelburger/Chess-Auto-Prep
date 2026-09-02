import 'dart:io';

import 'package:chess_auto_prep/services/eval/zstd_stream.dart';
import 'package:flutter_test/flutter_test.dart';

import 'raw_zstd_frame.dart';

void main() {
  late Directory tmp;
  late File archive;
  const payload = '{"fen":"8/8/8/8/8/8/8/K6k w - -"}\nsecond line\n';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zstd_stream');
    archive = File('${tmp.path}/sample.zst');
    await archive.writeAsBytes(rawZstdFrame(payload.codeUnits));
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> readAll(ZstdBackend backend) async {
    final out = StringBuffer();
    await for (final chunk in openZstdStream(archive.path, prefer: backend)) {
      out.write(String.fromCharCodes(chunk));
    }
    return out.toString();
  }

  test('a backend is available on this machine', () async {
    expect(await probeZstdBackend(), isNot(ZstdBackend.none));
  });

  test('libzstd expands the frame', () async {
    if (await probeZstdBackend() != ZstdBackend.library) {
      markTestSkipped('libzstd is not loadable on this machine');
      return;
    }
    expect(await readAll(ZstdBackend.library), payload);
  });

  test('the zstd command expands the same frame', () async {
    if (!await hasZstdCommand()) {
      markTestSkipped('no zstd executable on PATH');
      return;
    }
    expect(await readAll(ZstdBackend.commandLine), payload);
  });

  test('a truncated archive is an error, not silent short data', () async {
    // A frame that promises 99 bytes and then stops after ten.
    final broken = File('${tmp.path}/broken.zst');
    final full = rawZstdFrame(List<int>.filled(99, 0x41));
    await broken.writeAsBytes(full.sublist(0, 17));
    await expectLater(() async {
      await for (final _ in openZstdStream(broken.path)) {}
    }, throwsA(isA<ZstdException>()));
  });

  test('asking for a backend that is not there says so', () async {
    await expectLater(() async {
      await for (final _ in openZstdStream(
        archive.path,
        prefer: ZstdBackend.none,
      )) {}
    }, throwsA(isA<ZstdException>()));
  });
}
