import 'dart:io';

import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/stockfish_install.dart';
import 'package:chess_auto_prep/engines/tournament_launch.dart';
import 'package:chess_auto_prep/engines/uci_process.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory support;
  late List<(String, List<String>)> started;
  late EngineSupervisor engines;
  late StockfishInstall noStockfish;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('tournament_launch');
    started = [];
    engines = EngineSupervisor(
      startProcess:
          (
            executable,
            arguments, {
            workingDirectory,
            environment,
            includeParentEnvironment = true,
            runInShell = false,
            mode = ProcessStartMode.normal,
          }) async {
            started.add((executable, arguments));
            throw const ProcessException('engine', [], 'not here');
          },
    );
    noStockfish = StockfishInstall(
      supportDirectory: support,
      readAsset: (_) async => null,
    );
  });

  tearDown(() => support.delete(recursive: true));

  test('a seat that names no program plays the bundled Stockfish, and says '
      'why when there is none', () async {
    for (final path in [null, '']) {
      final start = await launchTournamentEngine(
        TournamentEngine({
          'id': 'sf',
          'name': 'Stockfish',
          'executablePath': ?path,
        }),
        EngineTranscript(),
        stockfish: noStockfish,
        engines: engines,
      );
      expect(start, isA<StartFailed>());
    }
    expect(started, isEmpty);
  });

  test('a seat that names a program starts it with its arguments', () async {
    await launchTournamentEngine(
      TournamentEngine({
        'id': 'mine',
        'name': 'Mine',
        'executablePath': 'mine-engine',
        'arguments': ['--uci'],
      }),
      EngineTranscript(),
      stockfish: noStockfish,
      engines: engines,
    );
    expect(started.single.$1, 'mine-engine');
    expect(started.single.$2, ['--uci']);
  });
}
