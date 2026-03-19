/// Test HTTP performance from inside a spawned Dart isolate.
///
/// This replicates the exact pattern used by db_only_generation_isolate.dart:
///   - Main isolate spawns a child via Isolate.spawn
///   - Child creates its own http.Client
///   - Child makes sequential HTTP requests
///   - Results sent back via SendPort
///
/// Usage:
///   dart run bin/test_isolate.dart
library;

import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

const _baseUrl = 'https://explorer.lichess.ovh/lichess';
const _params =
    'variant=standard&speeds=blitz,rapid,classical&ratings=1800,2000,2200,2500';

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

class _IsolateResult {
  final int index;
  final int httpMs;
  final int parseMs;
  final int moves;
  final int games;
  _IsolateResult(this.index, this.httpMs, this.parseMs, this.moves, this.games);
}

Future<void> _isolateWorker(SendPort sendPort) async {
  final client = http.Client();

  for (int i = 0; i < _testFens.length; i++) {
    final fen = _testFens[i];
    final encoded = Uri.encodeComponent(fen);
    final url = '$_baseUrl?$_params&fen=$encoded';

    final sw = Stopwatch()..start();
    final response = await client.get(Uri.parse(url));
    final httpMs = sw.elapsedMilliseconds;

    sw.reset();
    final data = json.decode(response.body);
    final moves = (data['moves'] as List?)?.length ?? 0;
    int totalGames = 0;
    for (final m in data['moves'] ?? []) {
      totalGames +=
          (m['white'] as int) + (m['draws'] as int) + (m['black'] as int);
    }
    final parseMs = sw.elapsedMilliseconds;

    sendPort.send(_IsolateResult(i, httpMs, parseMs, moves, totalGames));
  }
  sendPort.send('done');
  client.close();
}

Future<void> main() async {
  print('\n╔═══════════════════════════════════════════════════════╗');
  print('║  Dart Isolate.spawn HTTP Test                        ║');
  print('║  Same pattern as db_only_generation_isolate.dart     ║');
  print('╚═══════════════════════════════════════════════════════╝\n');

  print('Spawning isolate and making HTTP requests from inside it...');
  print('${'─' * 70}');

  final receivePort = ReceivePort();
  final wallSw = Stopwatch()..start();

  await Isolate.spawn(_isolateWorker, receivePort.sendPort);

  await for (final msg in receivePort) {
    if (msg is _IsolateResult) {
      final fenShort = _testFens[msg.index].split(' ')[0];
      final short =
          fenShort.length > 30 ? '${fenShort.substring(0, 30)}…' : fenShort;
      print('  [${msg.index + 1}] http=${msg.httpMs}ms  parse=${msg.parseMs}ms  '
          'total=${msg.httpMs + msg.parseMs}ms  '
          '${msg.moves} moves  ${msg.games} games  $short');
    } else if (msg == 'done') {
      break;
    }
  }

  final wallMs = wallSw.elapsedMilliseconds;
  print('${'─' * 70}');
  print('  Wall-clock: ${wallMs}ms\n');

  receivePort.close();
  print('Done.\n');
}
