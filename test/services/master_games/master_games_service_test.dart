@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/services/master_games/master_games_service.dart';
import 'package:chess_auto_prep/services/master_games/twic_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _issuePgn(int issue) =>
    '''
[Event "Issue $issue Open"]
[Site "Somewhere"]
[Date "2026.01.0${issue % 9 + 1}"]
[Round "1"]
[White "Player$issue,A"]
[Black "Other,B"]
[Result "1-0"]
[WhiteElo "2500"]
[BlackElo "2450"]

1. d4 d5 2. c4 e6 3. Nc3 Nf6 1-0
''';

Uint8List _zip(String name, String text) {
  final archive = Archive()
    ..addFile(ArchiveFile.bytes(name, utf8.encode(text)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Serves issues [published] as zips; everything else is a 404.
http.Client _twic(Set<int> published, {List<int>? log}) =>
    MockClient((request) async {
      final m = RegExp(r'twic(\d+)g\.zip$').firstMatch(request.url.path);
      final issue = m == null ? null : int.parse(m.group(1)!);
      log?.add(issue ?? -1);
      if (issue == null || !published.contains(issue)) {
        return http.Response('', 404);
      }
      if (request.method == 'HEAD') return http.Response('', 200);
      return http.Response.bytes(_zip('twic$issue.pgn', _issuePgn(issue)), 200);
    });

void main() {
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('mgsvc');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  MasterGamesService service(http.Client client) => MasterGamesService(
    clientFactory: () => TwicClient(httpClient: client),
    dbPathProvider: () async => '${tmp.path}/master_games.db',
  );

  test('unzips a TWIC issue to PGN text', () {
    final text = TwicClient.unzipPgn(
      _zip('twic1650.pgn', _issuePgn(1650)),
      issue: 1650,
    );
    expect(text, contains('[White "Player1650,A"]'));
  });

  test('sync imports every published issue from the start issue, '
      'registers a job, and is incremental', () async {
    final calls = <int>[];
    final svc = service(_twic({1650, 1651, 1652}, log: calls));
    addTearDown(svc.dispose);
    await svc.load();
    await svc.setStartIssue(1650);

    await svc.sync();

    expect(svc.lastError, isNull);
    expect(svc.stats!.games, 3);
    expect(svc.stats!.firstIssue, 1650);
    expect(svc.stats!.lastIssue, 1652);
    expect(svc.hasGames, isTrue);
    expect(svc.db!.gamesByPlayer('Player1651').single.white, 'Player1651,A');

    final job = JobManager.instance.jobs.firstWhere(
      (j) => j.type == JobType.masterGames,
    );
    expect(job.status, JobStatus.completed);
    expect(job.resumable, isTrue);
    expect(job.progress.fraction, 1);

    // Second sync: nothing new, no downloads beyond the probe.
    calls.clear();
    await svc.sync();
    expect(svc.status, contains('Up to date'));
    expect(svc.stats!.games, 3);
    expect(calls.where((c) => c >= 0).every((c) => c >= 1652), isTrue);
  });

  test('stopping keeps the issues already imported', () async {
    final svc = service(_twic({1650, 1651, 1652}));
    addTearDown(svc.dispose);
    await svc.load();
    await svc.setStartIssue(1650);

    // Cancel as soon as the first issue lands.
    svc.addListener(() {
      if (svc.status.contains('TWIC 1651')) svc.cancel();
    });
    await svc.sync();

    expect(svc.stats!.games, lessThan(3));
    expect(svc.stats!.games, greaterThan(0));
    expect(svc.status, contains('Paused'));
  });

  test('an unreachable site is reported, not thrown', () async {
    final svc = service(MockClient((_) async => http.Response('boom', 500)));
    addTearDown(svc.dispose);
    await svc.load();
    await svc.setStartIssue(1650);
    await svc.sync();
    expect(svc.isSyncing, isFalse);
    expect(svc.lastError, contains('could not reach'));
    final job = JobManager.instance.jobs.firstWhere(
      (j) => j.type == JobType.masterGames,
    );
    expect(job.status, JobStatus.failed);
  });

  test('live: sync the two newest issues from theweekinchess.com '
      '(set TWIC_LIVE=1)', () async {
    if (Platform.environment['TWIC_LIVE'] != '1') {
      markTestSkipped('TWIC_LIVE not set');
      return;
    }
    final svc = MasterGamesService(
      dbPathProvider: () async => '${tmp.path}/live.db',
    );
    addTearDown(svc.dispose);
    await svc.load();
    final client = TwicClient();
    final latest = await client.latestIssue(
      from: twicIssueEstimateFor(DateTime.now()),
    );
    client.close();
    expect(latest, isNotNull);
    await svc.setStartIssue(latest! - 1);
    await svc.sync();
    expect(svc.lastError, isNull);
    expect(svc.stats!.issues, 2);
    expect(svc.stats!.games, greaterThan(5000));
    // ignore: avoid_print
    print('live: ${svc.status}; ${svc.stats!.games} games');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('auto-sync is due only with a database, a new week, and no recent '
      'check', () async {
    final svc = service(_twic({1650, 1651}));
    addTearDown(svc.dispose);
    await svc.load();
    // Empty database: never automatic — the user opts in by downloading.
    expect(svc.isAutoSyncDue(now: DateTime.utc(2026, 9, 1)), isFalse);

    await svc.setStartIssue(1650);
    await svc.sync(); // records a check now
    expect(svc.stats!.lastIssue, 1651);
    // Just checked: not due, even though newer issues exist by the date.
    expect(svc.isAutoSyncDue(now: DateTime.now()), isFalse);
    // A day later, with the calendar past issue 1651: due.
    final later = DateTime.now().add(const Duration(days: 2));
    expect(svc.isAutoSyncDue(now: later), isTrue);
    await svc.setAutoSync(false);
    expect(svc.isAutoSyncDue(now: later), isFalse);
  });

  test('a second caller joins the sync in flight instead of starting '
      'another', () async {
    final calls = <int>[];
    final svc = service(_twic({1650, 1651}, log: calls));
    addTearDown(svc.dispose);
    await svc.load();
    await svc.setStartIssue(1650);

    // Nothing running: the completion future is already done, so a joiner
    // never blocks on a sync that will not happen.
    await svc.syncCompletion.timeout(const Duration(seconds: 1));

    final first = svc.sync();
    expect(svc.isSyncing, isTrue);
    var joined = false;
    final joiner = svc.syncCompletion.then((_) => joined = true);
    expect(joined, isFalse, reason: 'the joiner waits for the real sync');

    await Future.wait([first, joiner]);
    expect(joined, isTrue);
    expect(svc.isSyncing, isFalse);
    expect(svc.stats!.games, 2);
    // One pass over the issues, not two.
    expect(calls.where((c) => c == 1650).length, lessThanOrEqualTo(2));
  });

  test('latestIssue walks down from an overshooting estimate', () async {
    final client = TwicClient(httpClient: _twic({1650, 1651, 1652}));
    expect(await client.latestIssue(from: 1656), 1652);
    expect(await client.latestIssue(from: 1650), 1652);
    expect(await client.latestIssue(from: 1700), isNull);
  });
}
