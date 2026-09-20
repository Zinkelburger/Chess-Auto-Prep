import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chess_auto_prep/v2/engines/stockfish_install.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory support;
  final engine = Uint8List.fromList(utf8.encode('#!/bin/sh\necho uciok\n'));
  final compressed = Uint8List.fromList(gzip.encode(engine));
  late Map<String, Uint8List?> assets;
  final reads = <String>[];

  String lockWith({required String assetSha, String source = 'src1'}) =>
      jsonEncode({
        'stockfish-linux': {
          'source_sha256': source,
          'output_sha256': assetSha,
          'url': 'https://example.invalid/sf.tar.gz',
        },
      });

  setUp(() async {
    support = await Directory.systemTemp.createTemp('v2-stockfish-');
    reads.clear();
    assets = {
      'tools/assets.lock.json': Uint8List.fromList(
        utf8.encode(lockWith(assetSha: sha256.convert(compressed).toString())),
      ),
      'assets/executables/stockfish-linux.gz': compressed,
    };
  });

  tearDown(() => support.delete(recursive: true));

  StockfishInstall install() => StockfishInstall(
    supportDirectory: Directory(p.join(support.path, 'app')),
    readAsset: (asset) async {
      reads.add(asset);
      return assets[asset];
    },
  );

  test('installs the bundled engine once and runs it from then on', () async {
    final first = await install().locate() as StockfishReady;
    expect(await File(first.path).readAsBytes(), engine);
    expect(
      await File('${first.path}.origin').readAsString(),
      'stockfish-linux:src1',
    );
    expect((await Process.run(first.path, const [])).stdout, 'uciok\n');
    reads.clear();
    final second = await install().locate() as StockfishReady;
    expect(second.path, first.path);
    expect(reads, ['tools/assets.lock.json'], reason: 'no second unpack');
  });

  test('a new release replaces the installed engine', () async {
    await install().locate();
    assets['tools/assets.lock.json'] = Uint8List.fromList(
      utf8.encode(
        lockWith(
          assetSha: sha256.convert(compressed).toString(),
          source: 'src2',
        ),
      ),
    );
    final again = await install().locate() as StockfishReady;
    expect(
      await File('${again.path}.origin').readAsString(),
      'stockfish-linux:src2',
    );
  });

  test('a bundle that does not match its checksums is refused', () async {
    assets['tools/assets.lock.json'] = Uint8List.fromList(
      utf8.encode(lockWith(assetSha: 'not-it')),
    );
    final result = await install().locate();
    expect((result as StockfishMissing).reason, contains('does not match'));
    expect(
      await Directory(p.join(support.path, 'app')).list().toList(),
      isEmpty,
    );
  });

  test('a build without the engine says what to run', () async {
    assets.remove('assets/executables/stockfish-linux.gz');
    final result = await install().locate();
    expect((result as StockfishMissing).reason, contains('fetch_assets'));
  });

  test('a build without checksums cannot install', () async {
    assets.remove('tools/assets.lock.json');
    expect(await install().locate(), isA<StockfishMissing>());
  });
}
