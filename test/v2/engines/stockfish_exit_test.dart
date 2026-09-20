// Real Stockfish, unpacked from the bundled asset into a temporary support
// folder, so the test exercises the installer and never depends on what the
// machine happens to have.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/engines/stockfish_install.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The asset keys are repository paths, and `flutter test` runs from the
/// repository root, so the bundle is read straight off disk here.
const _engineAsset = 'assets/executables/stockfish-linux.gz';

Future<Uint8List?> _readAsset(String asset) async {
  final file = File(asset);
  return await file.exists() ? await file.readAsBytes() : null;
}

void main() {
  final skip = !Platform.isLinux
      ? 'Linux only'
      : !File(_engineAsset).existsSync()
      ? 'no bundled engine at $_engineAsset; run tools/fetch_assets.py'
      : false;

  late final Directory support;
  late final String stockfish;

  setUpAll(() async {
    if (skip != false) return;
    support = await Directory.systemTemp.createTemp('v2-stockfish-exit-');
    final located = await StockfishInstall(
      supportDirectory: support,
      readAsset: _readAsset,
    ).locate();
    stockfish = switch (located) {
      StockfishReady(:final path) => path,
      StockfishMissing(:final reason) => fail(reason),
    };
  });

  tearDownAll(() async {
    if (skip == false) await support.delete(recursive: true);
  });

  test('analyses a position with three lines and quits', () async {
    final engines = EngineSupervisor();
    final start = await engines.start(stockfish, options: {'Hash': '16'});
    final engine = (start as Started).engine;
    expect(engine.name, startsWith('Stockfish'));
    final search = engine.analyse(Fen.initial, multiPv: 3);
    final third = await search.lines
        .firstWhere((line) => line.multiPv == 3)
        .timeout(const Duration(seconds: 10));
    expect(third.pv, isNotEmpty);
    await engine.quit();
    expect(engines.pids, isEmpty);
  }, skip: skip);

  test(
    'the engine dies with the process that started it, even on SIGKILL',
    () async {
      final harness = await Process.start('dart', [
        'run',
        p.join('test', 'v2', 'engines', 'harness', 'hold_engine.dart'),
        stockfish,
      ], workingDirectory: Directory.current.path);
      harness.stderr.transform(utf8.decoder).listen(stderr.write);
      final announced = await harness.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((line) => line.startsWith('pid '))
          .timeout(const Duration(seconds: 90));
      final pid = int.parse(announced.substring(4));
      expect(await _alive(pid), isTrue);
      harness.kill(ProcessSignal.sigkill);
      await harness.exitCode;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (await _alive(pid) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await _alive(pid), isFalse, reason: 'engine $pid outlived us');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// A pid that is gone, or a zombie already reaped by init.
Future<bool> _alive(int pid) => Directory('/proc/$pid').exists();
