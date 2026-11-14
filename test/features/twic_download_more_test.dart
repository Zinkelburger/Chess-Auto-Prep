// A TWIC download's own bookkeeping: nothing counted before it runs, a
// window of one week to ten years, no issue older than the first TWIC zip,
// Stop heard only while it runs, a second run counted afresh, every step
// heard, and a run taken down mid-way fetching nothing more.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chess_auto_prep/features/databases/twic_download.dart';
import 'package:chess_auto_prep/storage/master_games_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

Uint8List _zip(int issue) {
  final bytes = utf8.encode('''
[Event "TWIC $issue"]
[Site "London ENG"]
[Date "2026.09.21"]
[White "White $issue"]
[Black "Black"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
''');
  return Uint8List.fromList(
    ZipEncoder().encode(
      Archive()..addFile(ArchiveFile('twic$issue.pgn', bytes.length, bytes)),
    ),
  );
}

void main() {
  late Directory temp;
  late String path;
  late List<String> asked;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('twic-more-test-');
    path = p.join(temp.path, 'master_games.db');
    asked = [];
  });
  tearDown(() async => temp.delete(recursive: true));

  /// A run over a TWIC whose newest issue is [latest].
  TwicDownload download({
    int latest = 1604,
    void Function(TwicDownload run, int issue)? before,
    bool own = false,
  }) {
    late final TwicDownload run;
    run = TwicDownload(
      path,
      client: () => MockClient((request) async {
        asked.add(p.basename(request.url.path));
        if (request.url.path == '/twic') {
          return http.Response('twic${latest}g.zip', 200);
        }
        final issue = int.parse(
          RegExp(r'twic(\d+)g').firstMatch(request.url.path)![1]!,
        );
        before?.call(run, issue);
        return http.Response.bytes(_zip(issue), 200);
      }),
    );
    if (!own) addTearDown(run.dispose);
    return run;
  }

  test('before it runs, nothing is counted or finished', () {
    final run = download();
    expect(
      (run.running, run.finished, run.done, run.total, run.skipped),
      (false, false, 0, 0, 0),
    );
  });

  test('asks one week at least and ten years at most', () async {
    final short = download();
    await short.start(0);
    expect(short.total, 1);
    expect(asked, ['twic', 'twic1604g.zip']);
    final long = download(latest: 925);
    await long.start(100000);
    expect(long.total, 520);
  });

  test('goes back no further than issue 920', () async {
    final run = download(latest: 921);
    await run.start(5);
    expect(asked, ['twic', 'twic921g.zip', 'twic920g.zip']);
    expect(run.finished, isTrue);
  });

  test('Stop is heard while it runs, and only then', () async {
    final idle = download();
    idle.stop();
    expect(idle.status, isEmpty);
    final run = download(before: (run, issue) => run.stop());
    await run.start(3);
    expect(run.status, startsWith('Stopped.'));
    expect(run.finished, isFalse);
  });

  test('a second run is counted afresh', () async {
    importTwicIssue(path, 1604, _zip(1604));
    final run = download();
    await run.start(2);
    expect((run.finished, run.done), (true, 2));
    final seen = <(bool, int)>[];
    run.addListener(() => seen.add((run.finished, run.done)));
    await run.start(2);
    expect(seen.first, (false, 0));
  });

  test('every step is heard', () async {
    final run = download();
    var heard = 0;
    run.addListener(() => heard++);
    await run.start(2);
    expect(heard, greaterThan(2));
  });

  test('taken down mid-way, it fetches nothing more', () async {
    final run = download(
      own: true,
      before: (run, issue) {
        if (issue == 1604) run.dispose();
      },
    );
    await run.start(4);
    expect(asked, ['twic', 'twic1604g.zip']);
  });
}
