import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:chess_auto_prep/services/eval/zstd_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'raw_zstd_frame.dart';

/// Block types of the zstd frame format.
const int _raw = 0;
const int _rle = 1;

/// One hand-built block: [size] bytes of expanded output, carried by [body]
/// (the bytes themselves for a raw block, a single byte for an RLE run).
typedef ZstdBlock = ({int type, int size, List<int> body});

ZstdBlock rawBlock(List<int> bytes) =>
    (type: _raw, size: bytes.length, body: bytes);
ZstdBlock rleBlock(int byte, int count) =>
    (type: _rle, size: count, body: [byte]);

/// A single-segment frame carrying [blocks] in order, content size declared.
Uint8List frameOf(List<ZstdBlock> blocks) {
  final total = blocks.fold(0, (sum, b) => sum + b.size);
  final out = BytesBuilder()
    ..add([0x28, 0xB5, 0x2F, 0xFD, 0xA0])
    ..add(
      (ByteData(4)..setUint32(0, total, Endian.little)).buffer.asUint8List(),
    );
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    final last = i == blocks.length - 1 ? 1 : 0;
    final header = (b.size << 3) | (b.type << 1) | last;
    out
      ..add([header & 0xff, (header >> 8) & 0xff, (header >> 16) & 0xff])
      ..add(b.body);
  }
  return out.takeBytes();
}

/// A skippable frame (magic `0x184D2A5?`), which a decoder must step over.
Uint8List skippableFrame(List<int> data) => Uint8List.fromList([
  0x50,
  0x2A,
  0x4D,
  0x18,
  ...(ByteData(
    4,
  )..setUint32(0, data.length, Endian.little)).buffer.asUint8List(),
  ...data,
]);

/// Printable noise of [bytes] bytes that compresses poorly, so a compressed
/// fixture stays large enough to cross the decoder's input buffer.
List<int> noisyText(int bytes, {int seed = 1}) {
  final rng = Random(seed);
  const alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /-';
  return List<int>.generate(
    bytes,
    (i) =>
        i % 80 == 79 ? 0x0a : alphabet.codeUnitAt(rng.nextInt(alphabet.length)),
  );
}

/// JSONL-looking text of about [bytes] bytes, deterministic per [seed].
List<int> jsonlText(int bytes, {int seed = 1}) {
  final rng = Random(seed);
  final out = BytesBuilder();
  while (out.length < bytes) {
    final cp = rng.nextInt(2000) - 1000;
    final depth = 20 + rng.nextInt(40);
    final fen = '8/8/8/8/8/8/${rng.nextInt(8)}p${rng.nextInt(8)}/K6k w - -';
    out.add(
      '{"fen":"$fen","evals":[{"pvs":[{"cp":$cp,"line":"a1a2 h8h7"}],'
              '"knodes":${rng.nextInt(1 << 20)},"depth":$depth}]}\n'
          .codeUnits,
    );
  }
  return out.takeBytes();
}

void main() {
  late Directory tmp;
  late List<ZstdBackend> backends;

  setUpAll(() async {
    backends = [
      if (await probeZstdBackend() == ZstdBackend.library) ZstdBackend.library,
      if (await hasZstdCommand()) ZstdBackend.commandLine,
    ];
    expect(backends, isNotEmpty, reason: 'no zstd on this machine at all');
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zstd_frames');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> archive(String name, List<int> bytes) async {
    final file = File(p.join(tmp.path, name));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  Future<List<int>> readAll(String path, ZstdBackend backend) async {
    final out = BytesBuilder();
    await for (final chunk in openZstdStream(path, prefer: backend)) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  /// Every available backend must expand [path] to exactly [expected].
  Future<void> expectBoth(String path, List<int> expected) async {
    for (final backend in backends) {
      expect(await readAll(path, backend), expected, reason: '$backend');
    }
  }

  /// Every available backend must refuse [path] with a [ZstdException].
  Future<void> expectRefusedByBoth(String path) async {
    for (final backend in backends) {
      await expectLater(
        () async {
          await for (final _ in openZstdStream(path, prefer: backend)) {}
        },
        throwsA(isA<ZstdException>()),
        reason: '$backend accepted a broken archive',
      );
    }
  }

  group('hand-built frames', () {
    test('raw and RLE blocks in one frame expand in order', () async {
      final path = await archive(
        'blocks.zst',
        frameOf([
          rawBlock('abc'.codeUnits),
          rleBlock(0x78, 1000),
          rawBlock('tail\n'.codeUnits),
        ]),
      );
      await expectBoth(path, [
        ...'abc'.codeUnits,
        ...List<int>.filled(1000, 0x78),
        ...'tail\n'.codeUnits,
      ]);
    });

    test('two frames back to back yield both payloads', () async {
      final first = 'first frame\n'.codeUnits;
      final second = 'second frame\n'.codeUnits;
      final path = await archive('two.zst', [
        ...rawZstdFrame(first),
        ...rawZstdFrame(second),
      ]);
      await expectBoth(path, [...first, ...second]);
    });

    test('a skippable frame between two frames is stepped over', () async {
      final first = 'before\n'.codeUnits;
      final second = 'after\n'.codeUnits;
      final path = await archive('skip.zst', [
        ...rawZstdFrame(first),
        ...skippableFrame('metadata that is not content'.codeUnits),
        ...rawZstdFrame(second),
        ...skippableFrame([]),
      ]);
      await expectBoth(path, [...first, ...second]);
    });

    test('a zero-length frame before a real one adds nothing', () async {
      final content = 'real\n'.codeUnits;
      final path = await archive('empty-frame.zst', [
        ...frameOf([rawBlock(const [])]),
        ...rawZstdFrame(content),
      ]);
      await expectBoth(path, content);
    });

    test('a zero-byte archive is refused, not read as empty', () async {
      // libzstd sees no input and used to report success; `zstd -dc` calls
      // the same file "unexpected end of file".  An empty archive must never
      // pass for an empty database, so both backends have to refuse it.
      final path = await archive('empty.zst', const []);
      await expectRefusedByBoth(path);
    });

    test('a frame cut inside its second block is an error', () async {
      final whole = frameOf([
        rawBlock(List<int>.filled(50, 0x41)),
        rawBlock(List<int>.filled(50, 0x42)),
      ]);
      // Magic 4 + descriptor 1 + size 4 + header 3 + 50 + header 3 + 20.
      final path = await archive('cut.zst', whole.sublist(0, 85));
      await expectRefusedByBoth(path);
    });

    test('a whole frame followed by a cut one is still an error', () async {
      final second = rawZstdFrame(List<int>.filled(40, 0x43));
      final path = await archive('cut-second.zst', [
        ...rawZstdFrame('complete\n'.codeUnits),
        ...second.sublist(0, second.length - 10),
      ]);
      await expectRefusedByBoth(path);
    });

    test('trailing garbage after a frame is an error', () async {
      final path = await archive('garbage.zst', [
        ...rawZstdFrame('fine\n'.codeUnits),
        ...'this is not a zstd frame'.codeUnits,
      ]);
      await expectRefusedByBoth(path);
    });
  });

  group('compressor-made frames', () {
    late bool haveCli;

    setUpAll(() async {
      haveCli = await hasZstdCommand();
    });

    /// [data] compressed by the system `zstd` with [flags].
    Future<Uint8List> compress(List<int> data, List<String> flags) async {
      final src = File(p.join(tmp.path, 'src.bin'));
      await src.writeAsBytes(data);
      final result = await Process.run('zstd', [
        '-q',
        '-c',
        ...flags,
        src.path,
      ], stdoutEncoding: null);
      if (result.exitCode != 0) {
        throw StateError('zstd ${flags.join(' ')} failed: ${result.stderr}');
      }
      return Uint8List.fromList(result.stdout as List<int>);
    }

    test('compressed blocks with literals and sequences round-trip', () async {
      if (!haveCli) return markTestSkipped('no zstd executable to compress');
      final data = jsonlText(200 * 1024);
      final frame = await compress(data, ['-19', '--no-check']);
      expect(
        frame.length,
        lessThan(data.length ~/ 4),
        reason: 'the fixture must actually be compressed, not stored',
      );
      await expectBoth(await archive('c.zst', frame), data);
    });

    test('a multi-megabyte stream crosses every buffer boundary', () async {
      if (!haveCli) return markTestSkipped('no zstd executable to compress');
      // Larger than the 256 KB input buffer and the 128 KB output buffer
      // several times over, so the decoder loops on both sides.
      final data = noisyText(1536 * 1024, seed: 9);
      final frame = await compress(data, ['-1']);
      expect(frame.length, greaterThan(512 * 1024));
      await expectBoth(await archive('big.zst', frame), data);
    });

    test('the content checksum is verified', () async {
      if (!haveCli) return markTestSkipped('no zstd executable to compress');
      final data = jsonlText(64 * 1024, seed: 3);
      final frame = await compress(data, ['-3', '--check']);
      await expectBoth(await archive('ok.zst', frame), data);

      // The xxhash sits in the last four bytes; flipping one must be caught
      // rather than yielding the data as if nothing were wrong.
      final corrupt = Uint8List.fromList(frame);
      corrupt[corrupt.length - 1] ^= 0xff;
      await expectRefusedByBoth(await archive('bad-sum.zst', corrupt));
    });

    test('a small window forces many blocks and a window descriptor', () async {
      if (!haveCli) return markTestSkipped('no zstd executable to compress');
      final data = jsonlText(300 * 1024, seed: 5);
      final frame = await compress(data, ['-5', '--zstd=wlog=10']);
      await expectBoth(await archive('small-window.zst', frame), data);
    });

    test('a compressed frame truncated mid-stream is an error', () async {
      if (!haveCli) return markTestSkipped('no zstd executable to compress');
      final data = jsonlText(400 * 1024, seed: 7);
      final frame = await compress(data, ['-3']);
      final path = await archive(
        'cut.zst',
        frame.sublist(0, frame.length ~/ 2),
      );
      await expectRefusedByBoth(path);
    });
  });
}
