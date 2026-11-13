import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:chess_auto_prep/features/databases/database_library.dart';
import 'package:chess_auto_prep/features/databases/twic_download.dart';
import 'package:chess_auto_prep/features/databases/twic_download_dialog.dart';
import 'package:chess_auto_prep/storage/master_corpus.dart';
import 'package:chess_auto_prep/storage/master_games_import.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

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
    for (var issue = latest - 3; issue < latest; issue++) {
      importTwicIssue(path, issue, issueZip(issue));
    }
    asked = [];
  });
  tearDown(() async => temp.delete(recursive: true));

  /// A run on scripted TWIC answers; [own] leaves its disposal to the
  /// caller's library.
  TwicDownload download({void Function(int issue)? before, bool own = false}) {
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
    if (!own) addTearDown(run.dispose);
    return run;
  }

  test('a run that cannot reach TWIC, or that TWIC turns away, says so in '
      'words', () async {
    final offline = TwicDownload(
      path,
      client: () => MockClient(
        (request) async => throw http.ClientException(
          'SocketException: Connection failed (OS Error: Network is '
          'unreachable, errno = 101)',
          request.url,
        ),
      ),
    );
    addTearDown(offline.dispose);
    await offline.start(4);
    expect(
      offline.problem,
      'Could not finish the TWIC download. Could not reach '
      'theweekinchess.com; it needs a connection.',
    );
    final refused = TwicDownload(
      path,
      client: () => MockClient((request) async => http.Response('', 503)),
    );
    addTearDown(refused.dispose);
    await refused.start(4);
    expect(
      refused.problem,
      'Could not finish the TWIC download. TWIC answered HTTP 503.',
    );
  });

  test('a failure that is neither the network nor TWIC says what the user '
      'can act on and never the exception', () async {
    Future<String?> failingWith(Object error) async {
      final run = TwicDownload(
        path,
        client: () => MockClient((request) async => throw error),
      );
      addTearDown(run.dispose);
      await run.start(4);
      return run.problem;
    }

    expect(
      await failingWith(ArgumentError('Internal: _Uint8ArrayView')),
      'Could not finish the TWIC download.',
    );
    expect(
      await failingWith(
        FileSystemException(
          'Cannot open file',
          path,
          OSError('Permission denied', Platform.isWindows ? 5 : 13),
        ),
      ),
      'Could not finish the TWIC download. Permission was denied.',
    );
  });

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
      for (var issue = latest - 3; issue < latest - 1; issue++) {
        importTwicIssue(path, issue, issueZip(issue));
      }
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
    for (final copy in copies) {
      expect(run.problem, contains(copy));
    }
  });

  testWidgets('a finished download leaves only Close: there is nothing '
      'left to cancel or download', (tester) async {
    final run = download(own: true);
    final library = DatabaseLibrary(
      path: path,
      corpus: const SqliteMasterCorpus(),
      picker: ScriptedPicker(),
      documents: ScriptedDocumentStore(),
      collections: p.join(temp.path, 'collections'),
      pending: PendingWrites(),
      download: run,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTwicDownload(context, library),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '1');
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    // The run's isolates answer in real time, and what follows each answer
    // runs in the test's own time: both are let on in turn.
    for (var i = 0; i < 500 && (run.running || !run.finished); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump();
    expect(find.text('TWIC database ready.'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Download'), findsNothing);
    expect(find.text('Weeks'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Close'));
    await tester.pumpAndSettle();
    expect(find.text('Download TWIC'), findsNothing);
    // Opened again, it offers the next download.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Download'), findsOneWidget);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    library.dispose();
  });
}
