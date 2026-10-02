/// A resumable worker over the same Dart search, engines and SQLite cache as
/// Bughouse Lab. tools/bughouse_db/expectimax.py seeds and supervises workers.
import 'dart:io';
import 'dart:convert';
import 'package:dartchess/dartchess.dart' show Crazyhouse, Setup;
import 'package:sqlite3/sqlite3.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/chess/bughouse/expectimax.dart';
import 'package:chess_auto_prep/engines/bughouse_backend.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/hivemind_install.dart';
import 'package:chess_auto_prep/storage/bughouse_expectimax.dart';

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    final index = args.indexOf('--$name');
    return index < 0 ? fallback : args[index + 1];
  }

  final path = File(option('db', 'bughouse_expectimax.db')).absolute.path;
  final nodes = int.parse(option('nodes', '800'));
  final plies = int.parse(option('plies', '2'));
  final cores = int.parse(option('cores', '4'));
  final worker = option('worker', '$pid');
  final support = Directory(option('support', Directory.current.path)).absolute;
  final book = BughouseExpectimaxBook(path);
  final queue = sqlite3.open(path)..execute('PRAGMA busy_timeout=10000');
  final supervisor = EngineSupervisor();
  var stopping = false;
  final signal = ProcessSignal.sigterm.watch().listen((_) => stopping = true);
  final interrupt = ProcessSignal.sigint.watch().listen((_) => stopping = true);
  try {
    final install = HivemindInstall(
      supportDirectory: support,
      readAsset: (asset) async =>
          File(asset).existsSync() ? File(asset).readAsBytes() : null,
    );
    final located = await install.locate();
    if (located is HivemindMissing) throw StateError(located.reason);
    final native = await BughouseBackend.start(
      crazyara: () => supervisor.startCrazyara(support.path),
      hivemind: () => supervisor.startHivemind(
        (located as HivemindReady).files,
        cores: cores,
      ),
      nodes: nodes,
    );
    while (!stopping) {
      final job = claim(queue, worker);
      if (job == null) break;
      final watch = Stopwatch()..start();
      try {
        final fens = (job['fen'] as String).split('|');
        final position = TablePosition(
          Crazyhouse.fromSetup(Setup.parseFen(fens[0])),
          Crazyhouse.fromSetup(Setup.parseFen(fens[1])),
        );
        final board = job['board'] == 'A' ? BoardNumber.one : BoardNumber.two;
        final options = BughouseSearchOptions(plies: plies, nodes: nodes);
        if (await book.load(position, board, options) == null) {
          final search = BughouseExpectimax(
            board: board,
            policy: native.policy,
            evaluate: (p, b) =>
                book.evaluate(p, b, nodes, native.identity, native.evaluate),
            options: options,
            cancelled: () => stopping,
          );
          final rows = await search.search(position).toList();
          await book.save(position, board, options, rows);
        }
        queue.execute(
          "UPDATE job SET status='done', worker=NULL, error=NULL WHERE id=?",
          [job['id']],
        );
        stdout.writeln(
          jsonEncode({
            'worker': worker,
            'done': job['id'],
            'board': job['board'],
            'seconds': watch.elapsed.inSeconds,
            'nodes': nodes,
            'plies': plies,
          }),
        );
      } on Object catch (error) {
        queue.execute(
          'UPDATE job SET status=?, worker=NULL, error=? WHERE id=?',
          [stopping ? 'queued' : 'failed', '$error', job['id']],
        );
        stderr.writeln('Job ${job['id']}: $error');
        if (!stopping) rethrow;
      }
    }
    await native.close();
  } finally {
    await supervisor.dispose();
    await signal.cancel();
    await interrupt.cancel();
    queue.close();
    book.close();
  }
}

Row? claim(Database db, String worker) {
  db.execute('BEGIN IMMEDIATE');
  try {
    final rows = db.select(
      "SELECT * FROM job WHERE status='queued' ORDER BY priority,id LIMIT 1",
    );
    if (rows.isEmpty) {
      db.execute('COMMIT');
      return null;
    }
    final row = rows.single;
    db.execute(
      "UPDATE job SET status='running', worker=?, started=? WHERE id=?",
      [worker, DateTime.now().millisecondsSinceEpoch ~/ 1000, row['id']],
    );
    db.execute('COMMIT');
    return row;
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}
