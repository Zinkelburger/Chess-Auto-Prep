/// Pure Dart CLI tool to measure Lichess Explorer API latency.
///
/// Uses the exact same `http` package and `http.Client` pattern as the
/// Flutter app's ProbabilityService, but runs outside Flutter so we can
/// isolate API/network latency from Flutter event loop overhead.
///
/// Usage:
///   cd tools/dart_api_test
///   dart pub get
///   dart run bin/test_api.dart
///   dart run bin/test_api.dart --parallel
library;

import 'dart:convert';
import 'package:http/http.dart' as http;

const _baseUrl = 'https://explorer.lichess.ovh/lichess';
const _params = 'variant=standard&speeds=blitz,rapid,classical&ratings=1800,2000,2200,2500';

/// Same FENs from the user's generation log.
const _testFens = [
  'rnbqkb1r/pp3ppp/3p1n2/2pP4/8/2N5/PP2PPPP/R1BQKBNR w KQkq - 0 6',
  'rnbqkb1r/pp3ppp/3p1n2/2pP4/4P3/2N5/PP3PPP/R1BQKBNR b KQkq - 0 6',
  'rnbqkb1r/pp3p1p/3p1np1/2pP4/4P3/2N5/PP3PPP/R1BQKBNR w KQkq - 0 7',
  'rnbqkb1r/pp3p1p/3p1np1/2pP4/4PP2/2N5/PP4PP/R1BQKBNR b KQkq - 0 7',
  'rnbqkb1r/1p3p1p/p2p1np1/2pP4/4PP2/2N5/PP4PP/R1BQKBNR w KQkq - 0 8',
  'rnbqkb1r/1p3p1p/p2p1np1/2pP4/4PP2/2N2N2/PP4PP/R1BQKB1R b KQkq - 1 8',
  'rnbqk2r/1p3pbp/p2p1np1/2pP4/4PP2/2N2N2/PP4PP/R1BQKB1R w KQkq - 2 9',
  'rnbqk2r/1p3pbp/p2p1np1/2pP4/P3PP2/2N2N2/1P4PP/R1BQKB1R b KQkq - 0 9',
];

/// Sibling FENs for parallel test (opponent branches at same depth).
const _parallelFens = [
  'rnbqk2r/1p3pbp/p2p1np1/2pP4/4PP2/2N2N2/PP4PP/R1BQKB1R w KQkq - 2 9',
  'rnbq1rk1/1p3pbp/p2p1np1/2pP4/P3PP2/2N2N2/1P4PP/R1BQKB1R w KQ - 1 10',
  'rnbq1rk1/1p3pbp/p2p1np1/2pP4/P3PP2/2NB1N2/1P4PP/R1BQK2R b KQ - 2 10',
  'r1bq1rk1/1p3pbp/p1np1np1/2pP4/P3PP2/2NB1N2/1P4PP/R1BQK2R w KQ - 3 11',
  'r1bq1rk1/1p2npbp/p2p2p1/2pP4/P3PP2/2NB1N2/1P4PP/R1BQK2R w KQ - 1 11',
];

Future<void> main(List<String> args) async {
  final parallel = args.contains('--parallel');

  print('\n╔═══════════════════════════════════════════════════════╗');
  print('║  Dart http.Client API Latency Test (no Flutter)      ║');
  print('║  Same http package + Client pattern as the app       ║');
  print('╚═══════════════════════════════════════════════════════╝\n');

  // --- Sequential with persistent client (exactly like ProbabilityService) ---
  final client = http.Client();

  print('Sequential (persistent http.Client — mirrors ProbabilityService):');
  print('${'─' * 70}');

  final totalSw = Stopwatch()..start();

  for (int i = 0; i < _testFens.length; i++) {
    final fen = _testFens[i];
    final encoded = Uri.encodeComponent(fen);
    final url = '$_baseUrl?$_params&fen=$encoded';

    final sw = Stopwatch()..start();

    // Step 1: build headers (simulates getHeaders — in practice just a map)
    final headers = <String, String>{};
    final headerMs = sw.elapsedMilliseconds;

    // Step 2: HTTP GET (exactly like ProbabilityService)
    sw.reset();
    final response = await client.get(Uri.parse(url), headers: headers);
    final httpMs = sw.elapsedMilliseconds;

    // Step 3: JSON decode + parse (same as ProbabilityService)
    sw.reset();
    final data = json.decode(response.body);
    final moves = (data['moves'] as List?)?.length ?? 0;
    int totalGames = 0;
    for (final m in data['moves'] ?? []) {
      totalGames += (m['white'] as int) + (m['draws'] as int) + (m['black'] as int);
    }
    final parseMs = sw.elapsedMilliseconds;

    final fenShort = fen.split(' ')[0];
    final short = fenShort.length > 30 ? '${fenShort.substring(0, 30)}…' : fenShort;
    print('  [${i + 1}] headers=${headerMs}ms  http=${httpMs}ms  parse=${parseMs}ms  '
        'total=${headerMs + httpMs + parseMs}ms  '
        '$moves moves  $totalGames games  $short');
  }

  final seqMs = totalSw.elapsedMilliseconds;
  print('${'─' * 70}');
  print('  Wall-clock: ${seqMs}ms\n');

  // --- Parallel test ---
  if (parallel) {
    print('Parallel (5 sibling FENs, concurrent futures):');
    print('${'─' * 70}');

    final parSw = Stopwatch()..start();
    final futures = <Future<String>>[];

    for (int i = 0; i < _parallelFens.length; i++) {
      futures.add(_fetchOne(client, _parallelFens[i], i));
    }
    final results = await Future.wait(futures);
    final parMs = parSw.elapsedMilliseconds;

    for (final r in results) {
      print('  $r');
    }
    print('${'─' * 70}');
    print('  Wall-clock (parallel): ${parMs}ms\n');
  }

  client.close();
  print('Done.\n');
}

Future<String> _fetchOne(http.Client client, String fen, int idx) async {
  final encoded = Uri.encodeComponent(fen);
  final url = '$_baseUrl?$_params&fen=$encoded';

  final sw = Stopwatch()..start();
  final response = await client.get(Uri.parse(url));
  final httpMs = sw.elapsedMilliseconds;

  final data = json.decode(response.body);
  final moves = (data['moves'] as List?)?.length ?? 0;
  int totalGames = 0;
  for (final m in data['moves'] ?? []) {
    totalGames += (m['white'] as int) + (m['draws'] as int) + (m['black'] as int);
  }

  final fenShort = fen.split(' ')[0];
  final short = fenShort.length > 30 ? '${fenShort.substring(0, 30)}…' : fenShort;
  return '[${idx + 1}] http=${httpMs}ms  $moves moves  $totalGames games  $short';
}
