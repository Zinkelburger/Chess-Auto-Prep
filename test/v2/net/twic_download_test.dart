import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/features/databases/twic_download.dart';
import 'package:chess_auto_prep/v2/storage/master_book.dart';
import 'package:chess_auto_prep/v2/storage/twic_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const game = '''
[Event "Test Open"]
[Site "London ENG"]
[Date "2026.09.21"]
[White "White"]
[Black "Black"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
''';

Uint8List zipped(String text) {
  final bytes = utf8.encode(text);
  return Uint8List.fromList(
    ZipEncoder().encode(
      Archive()..addFile(ArchiveFile('twic.pgn', bytes.length, bytes)),
    ),
  );
}

void main() {
  late Directory temp;
  late String path;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('twic-download-test-');
    path = p.join(temp.path, 'twic_book.db');
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
    'issue import is readable, classified and idempotent; a bad issue rolls back',
    () async {
      final bytes = zipped(
        '$game\n${game.replaceAll('Test Open', 'Test Blitz').replaceAll('1-0', '0-1')}',
      );
      expect(importTwicIssue(path, 1600, bytes), (2, 0));
      expect(importTwicIssue(path, 1600, bytes), (0, 0));
      final book = SqliteMasterBook(path);
      addTearDown(book.close);
      expect(await book.available(), isTrue);
      final all =
          await book.lookup(Fen.initial, classicalOnly: false) as BookFound;
      expect(all.answer.moves.single.games, 2);
      final classical =
          await book.lookup(Fen.initial, classicalOnly: true) as BookFound;
      expect(classical.answer.moves.single.games, 1);
      expect(await book.gamePgn(all.answer.games.single.id), contains('Nf3'));
      expect(
        () => importTwicIssue(path, 1601, zipped('not a PGN')),
        throwsFormatException,
      );
      expect(downloadedTwicIssues(path), {1600});
      expect(
        (await book.lookup(Fen.initial, classicalOnly: false) as BookFound)
            .answer
            .moves
            .single
            .games,
        2,
      );
    },
  );

  test('download resumes completed issues after HTTP failure', () async {
    var fail = true;
    final asked = <String>[];
    final run = TwicDownload(
      path,
      client: () => MockClient((request) async {
        asked.add(request.url.path);
        if (request.url.path == '/twic')
          return http.Response('<a href="/zips/twic1601g.zip">PGN</a>', 200);
        if (request.url.path.endsWith('1600g.zip') && fail)
          return http.Response('', 503);
        return http.Response.bytes(zipped(game), 200);
      }),
    );
    addTearDown(run.dispose);
    await run.start(2);
    expect(run.problem, contains('503'));
    expect(downloadedTwicIssues(path), {1601});
    fail = false;
    await run.start(2);
    expect(run.problem, isNull);
    expect(downloadedTwicIssues(path), {1600, 1601});
    expect(asked.where((s) => s.endsWith('1601g.zip')), hasLength(1));
  });

  test('stop preserves the completed issue for the next run', () async {
    final run = TwicDownload(
      path,
      client: () => MockClient((request) async {
        if (request.url.path == '/twic')
          return http.Response('twic1601g.zip', 200);
        return http.Response.bytes(zipped(game), 200);
      }),
    );
    addTearDown(run.dispose);
    var stopped = false;
    run.addListener(() {
      if (run.done == 1 && !stopped) {
        stopped = true;
        run.stop();
      }
    });
    await run.start(2);
    expect(run.running, isFalse);
    expect(downloadedTwicIssues(path), {1601});
    expect(run.status, contains('resume'));
  });
}
