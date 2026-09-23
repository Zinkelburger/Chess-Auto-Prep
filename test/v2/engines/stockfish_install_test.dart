import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chess_auto_prep/v2/diagnostics/log.dart';
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
  final problems = <LogEntry>[];
  void collect(LogEntry entry) => problems.add(entry);

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
    problems.clear();
    log.install(collect);
    assets = {
      'tools/assets.lock.json': Uint8List.fromList(
        utf8.encode(lockWith(assetSha: sha256.convert(compressed).toString())),
      ),
      'assets/executables/stockfish-linux.gz': compressed,
    };
  });

  tearDown(() {
    log.remove(collect);
    return support.delete(recursive: true);
  });

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

  test('two launches during the first install share one unpack', () async {
    // An engine restart for new cores while the first launch is still
    // unpacking: each launch makes its own install.
    final both = await Future.wait([install().locate(), install().locate()]);
    final paths = [for (final found in both) (found as StockfishReady).path];
    expect(paths.toSet(), hasLength(1));
    expect(
      reads.where((asset) => asset.endsWith('.gz')),
      hasLength(1),
      reason: 'one unpack',
    );
    expect((await Process.run(paths.first, const [])).stdout, 'uciok\n');
    final left = await Directory(
      p.join(support.path, 'app'),
    ).list().map((entry) => p.basename(entry.path)).toList();
    expect(left.where((name) => name.endsWith('.part')), isEmpty);
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

  test('a corrupt engine asset leaves nothing stamped as installed', () async {
    final rubbish = Uint8List.fromList(utf8.encode('not a gzip stream'));
    assets['assets/executables/stockfish-linux.gz'] = rubbish;
    assets['tools/assets.lock.json'] = Uint8List.fromList(
      utf8.encode(lockWith(assetSha: sha256.convert(rubbish).toString())),
    );
    final result = await install().locate();
    expect((result as StockfishMissing).reason, contains('Could not install'));
    final app = Directory(p.join(support.path, 'app'));
    expect(
      await app.list().map((e) => p.basename(e.path)).toList(),
      isNot(contains('stockfish-linux.origin')),
    );
  });

  test('a broken bundle keeps the engine that already runs', () async {
    final first = await install().locate() as StockfishReady;
    final rubbish = Uint8List.fromList(utf8.encode('not a gzip stream'));
    assets['assets/executables/stockfish-linux.gz'] = rubbish;
    assets['tools/assets.lock.json'] = Uint8List.fromList(
      utf8.encode(
        lockWith(assetSha: sha256.convert(rubbish).toString(), source: 'src2'),
      ),
    );

    final result = await install().locate() as StockfishReady;

    expect(result.path, first.path);
    expect((await Process.run(result.path, const [])).stdout, 'uciok\n');
    expect(await File(first.path).readAsBytes(), engine);
    expect(
      await File('${first.path}.origin').readAsString(),
      'stockfish-linux:src1',
      reason: 'a bad release must not disown a working engine',
    );
    expect(
      problems.map((entry) => entry.line),
      anyElement(contains('install stockfish-linux')),
      reason: 'the log says the new bundle was rejected',
    );
    // Which is what makes the next launch of the good release free again.
    assets['assets/executables/stockfish-linux.gz'] = compressed;
    assets['tools/assets.lock.json'] = Uint8List.fromList(
      utf8.encode(lockWith(assetSha: sha256.convert(compressed).toString())),
    );
    reads.clear();
    final back = await install().locate() as StockfishReady;
    expect(back.path, first.path);
    expect(reads, ['tools/assets.lock.json'], reason: 'no second unpack');
  });

  test('a bundle whose checksum is wrong keeps the engine too', () async {
    final first = await install().locate() as StockfishReady;
    assets['tools/assets.lock.json'] = Uint8List.fromList(
      utf8.encode(lockWith(assetSha: 'not-it', source: 'src2')),
    );

    final result = await install().locate() as StockfishReady;

    expect(result.path, first.path);
    expect(await File(first.path).readAsBytes(), engine);
    expect(
      await File('${first.path}.origin').readAsString(),
      'stockfish-linux:src1',
    );
    expect(
      problems.map((entry) => entry.line),
      anyElement(contains('does not match')),
    );
  });

  test('an unstamped binary is not run in place of a failed install', () async {
    // Half an install: a file under the engine's name that nothing vouches
    // for. It is not an engine this app put there, so it does not run.
    final app = Directory(p.join(support.path, 'app'));
    await app.create(recursive: true);
    await File(p.join(app.path, 'stockfish-linux')).writeAsString('rubbish');
    assets['tools/assets.lock.json'] = Uint8List.fromList(
      utf8.encode(lockWith(assetSha: 'not-it')),
    );

    final result = await install().locate();

    expect((result as StockfishMissing).reason, contains('does not match'));
  });

  test('a failed install leaves no half-unpacked file behind', () async {
    final rubbish = Uint8List.fromList(utf8.encode('not a gzip stream'));
    assets['assets/executables/stockfish-linux.gz'] = rubbish;
    assets['tools/assets.lock.json'] = Uint8List.fromList(
      utf8.encode(lockWith(assetSha: sha256.convert(rubbish).toString())),
    );

    expect(await install().locate(), isA<StockfishMissing>());

    final left = await Directory(
      p.join(support.path, 'app'),
    ).list().map((entry) => p.basename(entry.path)).toList();
    expect(left.where((name) => name.endsWith('.part')), isEmpty);
  });

  test('a stamp that cannot be read is reported, not thrown', () async {
    final first = await install().locate() as StockfishReady;
    // A truncated or half-written stamp: bytes that are not text at all.
    await File(
      '${first.path}.origin',
    ).writeAsBytes(Uint8List.fromList(const [0xC3, 0x28]));

    final result = await install().locate();

    expect(result, isA<StockfishMissing>());
    expect((result as StockfishMissing).reason, contains('stamp'));
    expect(
      await File(first.path).readAsBytes(),
      engine,
      reason: 'the engine itself is still there',
    );
  });

  test('a damaged checksum file is reported, not thrown', () async {
    assets['tools/assets.lock.json'] = Uint8List.fromList(
      utf8.encode('{"stockfish-linux": '),
    );
    final result = await install().locate();
    expect((result as StockfishMissing).reason, contains('is damaged'));
  });
}
