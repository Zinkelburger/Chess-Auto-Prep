// A TWIC import killed half-way, on every desktop: the process dies inside
// the issue's transaction and the database must come back with the issues it had,
// no half-issue, and accept the same issue again once.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/master_games_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'harness/master_games_import.dart' show issueZip;

const _harness = 'test/storage/harness/master_games_import.dart';

void main() {
  late Directory folder;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('v2 twic kill é 棋 ');
  });
  tearDown(() => folder.delete(recursive: true));

  test('killing the importer mid-issue loses only that issue', () async {
    final database = p.join(folder.path, 'master_games.db');
    expect(importTwicIssue(database, 1, issueZip(1, 10)), (10, 0));

    final child = await Process.start('dart', [
      'run',
      '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
      _harness,
      'import',
      database,
      '2',
      '20000',
    ], workingDirectory: Directory.current.path);
    final output = StringBuffer();
    final ready = Completer<int>();
    final lines = child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          output.writeln(line);
          if (line.startsWith('ready ') && !ready.isCompleted) {
            ready.complete(int.parse(line.substring(6)));
          }
        });
    final errors = child.stderr.transform(utf8.decoder).listen(output.write);
    int? importer;
    addTearDown(() async {
      if (importer != null) Process.killPid(importer, ProcessSignal.sigkill);
      child.kill(ProcessSignal.sigkill);
      await lines.cancel();
      await errors.cancel();
    });
    importer = await ready.future.timeout(const Duration(minutes: 2));

    // The first issue's checkpoint left the write-ahead log empty; it fills
    // again only while the next issue's transaction is open, long before
    // its commit. Kill the importer then.
    final log = File('$database-wal');
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!log.existsSync() || log.lengthSync() == 0) {
      if (DateTime.now().isAfter(deadline)) {
        fail('the import never opened its transaction:\n$output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    // Kill the importer itself: on Windows, killing the `dart run` launcher
    // leaves it running and still writing the database.
    expect(Process.killPid(importer, ProcessSignal.sigkill), isTrue);
    await child.exitCode.timeout(const Duration(seconds: 20));
    expect('$output', isNot(contains('imported')));

    final db = sqlite3.open(database);
    try {
      expect(db.select('PRAGMA integrity_check').single.values, ['ok']);
      expect(db.select('SELECT count(*) AS n FROM games').single['n'], 10);
    } finally {
      db.close();
    }
    expect(masterGamesIssues(database).issues, {1});
    expect(importTwicIssue(database, 2, issueZip(2, 50)), (50, 0));
    expect(importTwicIssue(database, 2, issueZip(2, 50)), (0, 0));
    expect(masterGamesIssues(database).issues, {1, 2});
  }, timeout: const Timeout(Duration(minutes: 4)));
}
