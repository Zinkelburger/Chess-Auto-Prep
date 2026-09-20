// Real Stockfish, so these run only where one is installed: the copy the
// app keeps under its support folder, or CHESS_PREP_STOCKFISH.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String? stockfishPath() {
  final candidates = [
    Platform.environment['CHESS_PREP_STOCKFISH'],
    if (Platform.environment['HOME'] case final home?)
      p.join(home, '.local/share/com.example.chess_auto_prep/stockfish-linux'),
  ];
  for (final path in candidates.nonNulls) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

void main() {
  final stockfish = stockfishPath();
  final skip = !Platform.isLinux
      ? 'Linux only'
      : stockfish == null
      ? 'no Stockfish installed'
      : false;

  test('analyses a position with three lines and quits', () async {
    final engines = EngineSupervisor();
    final start = await engines.start(stockfish!, options: {'Hash': '16'});
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
        stockfish!,
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
