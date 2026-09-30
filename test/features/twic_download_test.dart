import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:chess_auto_prep/features/databases/twic_download.dart';
import 'package:chess_auto_prep/storage/master_games_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const latest = 1604;

/// A tiny valid issue, its game named after it.
Uint8List issueZip(int issue) {
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
    temp = await Directory.systemTemp.createTemp('twic-download-test-');
    path = p.join(temp.path, 'master_games.db');
    for (var issue = latest - 3; issue < latest; issue++)
      importTwicIssue(path, issue, issueZip(issue));
    asked = [];
  });
  tearDown(() async => temp.delete(recursive: true));

  TwicDownload download({void Function(int issue)? before}) {
    final run = TwicDownload(
      path,
      client: () => MockClient((request) async {
        asked.add(p.basename(request.url.path));
        if (request.url.path == '/twic') {
          return http.Response(
            [
              for (var i = latest - 3; i <= latest; i++) 'twic${i}g.zip',
            ].join(' '),
            200,
          );
        }
        final issue = int.parse(
          RegExp(r'twic(\d+)g').firstMatch(request.url.path)![1]!,
        );
        before?.call(issue);
        return http.Response.bytes(issueZip(issue), 200);
      }),
    );
    addTearDown(run.dispose);
    return run;
  }

  test('a run skips the issues already in the database', () async {
    final run = download();
    await run.start(4);
    expect(run.problem, isNull);
    expect(asked, ['twic', 'twic${latest}g.zip']);
    expect(masterGamesIssues(path).issues, {
      for (var i = latest - 3; i <= latest; i++) i,
    });
  });

  test(
    'a database set aside mid-run is filled again from the whole window',
    () async {
      final run = download(
        before: (issue) {
          if (issue != latest) return;
          File(path).writeAsStringSync('not a database any more ' * 400);
          for (final suffix in ['-wal', '-shm']) {
            final side = File('$path$suffix');
            if (side.existsSync()) side.deleteSync();
          }
        },
      );
      await run.start(4);
      expect(run.problem, isNull);
      expect(run.setAside, isNotNull);
      expect(
        temp.listSync().map((e) => p.basename(e.path)),
        contains(startsWith('master_games.db.unreadable-')),
      );
      expect(asked.toSet(), {
        'twic',
        for (var i = latest - 3; i <= latest; i++) 'twic${i}g.zip',
      });
      expect(masterGamesIssues(path).issues, {
        for (var i = latest - 3; i <= latest; i++) i,
      });
      expect(run.status, contains('set aside'));
    },
  );

  test(
    'an issue imported earlier in the run is kept after a later set-aside',
    () async {
      path = p.join(temp.path, 'partial.db');
      for (var issue = latest - 3; issue < latest - 1; issue++)
        importTwicIssue(path, issue, issueZip(issue));
      var corrupted = false;
      final run = download(
        before: (issue) {
          if (issue != latest - 1 || corrupted) return;
          corrupted = true;
          File(path).writeAsStringSync('not a database any more ' * 400);
          for (final suffix in ['-wal', '-shm']) {
            final side = File('$path$suffix');
            if (side.existsSync()) side.deleteSync();
          }
        },
      );
      await run.start(4);
      expect(run.problem, isNull);
      expect(run.setAside, isNotNull);
      expect(masterGamesIssues(path).issues, {
        for (var i = latest - 3; i <= latest; i++) i,
      });
    },
  );

  test('a database that keeps turning unreadable stops the run instead of '
      'starting over forever', () async {
    final run = download(
      before: (issue) {
        File(path).writeAsStringSync('not a database any more ' * 400);
        for (final suffix in ['-wal', '-shm']) {
          final side = File('$path$suffix');
          if (side.existsSync()) side.deleteSync();
        }
      },
    );
    await run.start(4).timeout(const Duration(seconds: 20));
    expect(run.problem, isNotNull);
    expect(run.running, isFalse);
    expect(
      asked.where((name) => name == 'twic${latest - 1}g.zip').length,
      lessThanOrEqualTo(2),
    );
    final copies = [
      for (final entry in temp.listSync())
        if (p.basename(entry.path) case final name
            when name.startsWith('master_games.db.unreadable-') &&
                !RegExp(r'-(wal|shm|journal)$').hasMatch(name))
          name,
    ];
    expect(copies, hasLength(2));
    for (final copy in copies) expect(run.problem, contains(copy));
  });
}
