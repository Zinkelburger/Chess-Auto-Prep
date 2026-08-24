/// Wall-clock benchmark for the tactics mining pipeline.
///
/// Deliberately named without a `_test` suffix so a bare `flutter test`
/// (and CI) never runs it. Run it explicitly:
///
///   ~/flutter/bin/flutter test test/benchmark/tactics_mining_benchmark.dart
///
/// It spawns the real Stockfish binary the app already extracted to the
/// application-support directory and mines a sandboxed copy of the user's
/// stored games (`~/Documents/imported_games.pgn`). All writes go to a temp
/// directory; real app data is never touched.
///
/// Two scenarios, chosen to bracket real usage:
///  * incremental — 2 games (the daily auto-fetch case)
///  * bulk        — every stored game
library;

import 'dart:io';

import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_database.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_import_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int kDepth = 12;
const int kWorkers = 6;
const String kChesscomUsername = 'BigManArkhangelsk';

/// Documents → per-scenario sandbox (all storage writes land there).
/// Support → the real app-support dir, read-only, so [ProcessConnection]
/// finds the already-extracted Stockfish binary instead of needing assets.
class _BenchPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _BenchPathProvider({required this.documents, required this.support});
  final String documents;
  final String support;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getApplicationSupportPath() async => support;
}

String get _home => Platform.environment['HOME']!;

String get _realSupportPath =>
    p.join(_home, '.local', 'share', 'com.example.chess_auto_prep');

String get _realImportedPgnsPath =>
    p.join(_home, 'Documents', 'imported_games.pgn');

Future<({int games, int tactics, int searches, Duration wall})> _runScenario(
  List<String> games,
) async {
  final sandbox = await Directory.systemTemp.createTemp('tactics_bench');
  PathProviderPlatform.instance = _BenchPathProvider(
    documents: sandbox.path,
    support: _realSupportPath,
  );
  File(
    p.join(sandbox.path, 'imported_games.pgn'),
  ).writeAsStringSync(games.join('\n\n'));

  final database = TacticsDatabase();
  final service = TacticsImportService(database: database);
  await service.initialize();

  EvalWorker.searchCount = 0;
  final wall = Stopwatch()..start();
  final result = await service.resumeStoredPgns(
    lichessUsername: null,
    chesscomUsername: kChesscomUsername,
    depth: kDepth,
    maxCores: kWorkers,
  );
  wall.stop();

  return (
    games: result.gamesAnalyzed,
    tactics: result.positions.length,
    searches: EvalWorker.searchCount,
    wall: wall.elapsed,
  );
}

void _report(
  String label,
  ({int games, int tactics, int searches, Duration wall}) r,
) {
  final secs = (r.wall.inMilliseconds / 1000).toStringAsFixed(1);
  stdout.writeln(
    '[bench] $label: ${r.games} games, ${r.tactics} tactics, '
    '${r.searches} searches, ${secs}s wall '
    '(depth $kDepth, $kWorkers workers)',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> allGames;

  setUpAll(() {
    // flutter_test defaults the target platform to Android, which would
    // route engine creation to the mobile FFI package instead of the
    // desktop process spawn.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues({});

    final binary = File(p.join(_realSupportPath, 'stockfish-linux'));
    if (!binary.existsSync()) {
      fail(
        'Stockfish binary not found at ${binary.path} — launch the app '
        'once so it extracts the engine, then re-run the benchmark.',
      );
    }
    final imported = File(_realImportedPgnsPath);
    if (!imported.existsSync()) {
      fail('No stored games at ${imported.path} — nothing to benchmark.');
    }
    allGames = splitPgnIntoGames(imported.readAsStringSync());
    stdout.writeln('[bench] ${allGames.length} stored games available');
  });

  tearDownAll(() {
    StockfishPool.instance.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('incremental: 2 games', () async {
    final r = await _runScenario(allGames.take(2).toList());
    _report('incremental', r);
    expect(r.games, 2);
  }, timeout: Timeout.none);

  test('bulk: all stored games', () async {
    final r = await _runScenario(allGames);
    _report('bulk', r);
    expect(r.games, allGames.length);
  }, timeout: Timeout.none);
}
