import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/features/databases/twic_download.dart';
import 'package:chess_auto_prep/storage/master_book.dart';
import 'package:chess_auto_prep/storage/master_games_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

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
    temp = await Directory.systemTemp.createTemp('master-games-import-test-');
    path = p.join(temp.path, 'master_games.db');
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
    'TWIC issues and imported PGN files are one book for the explorer',
    () async {
      importTwicIssue(path, 1600, zipped(game));
      final source = File(p.join(temp.path, 'mine.pgn'))
        ..writeAsStringSync(
          game.replaceAll('Test Open', 'Club').replaceAll('Nc6', 'Nf6'),
        );
      expect(importMasterPgn(path, source.path), (1, 0));
      expect(importMasterPgn(path, source.path), (0, 0), reason: 'once only');
      final book = SqliteMasterBook(path);
      final start =
          await book.lookup(Fen.initial, classicalOnly: false) as BookFound;
      expect(start.answer.moves.single.games, 2);
      expect(start.answer.moves.single.white, 2);
      // Windows cannot delete the folder while this handle is open.
      final db = sqlite3.open(path, mode: OpenMode.readOnly);
      final ids = [
        for (final row in db.select('SELECT id FROM games ORDER BY id'))
          '${row['id']}',
      ];
      db.close();
      expect(await book.gamePgn(ids.last), contains('[Event "Club"]'));
      expect(
        await book.gamePgn(ids.last),
        endsWith('1. e4 e5 2. Nf3 Nf6 1-0\n'),
      );
    },
  );

  test('a new file is schema 4 with its movetext dictionary; the stored '
      'moves carry no result', () {
    importTwicIssue(path, 1600, zipped(game));
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    addTearDown(db.close);
    expect(db.select('PRAGMA user_version').first.columnAt(0), 4);
    expect(db.select('PRAGMA journal_mode').first.columnAt(0), 'wal');
    final dictionary =
        db
                .select("SELECT value FROM meta WHERE key = 'movetext_dict'")
                .single['value']
            as List<int>;
    final stored =
        db.select('SELECT movetext FROM games').single['movetext'] as List<int>;
    expect(
      utf8.decode(ZLibDecoder(dictionary: dictionary).convert(stored)),
      '1. e4 e5 2. Nf3 Nc6',
    );
    final row = db.select("SELECT * FROM book WHERE move = 'e2e4'").single;
    expect(row['ply'], 0);
    expect(row['classical_games'], 1);
    expect(row['top_classical_game'], 1);
  });

  test('a database of another schema version is refused, not changed', () {
    final db = sqlite3.open(path)
      ..execute('CREATE TABLE games (id INTEGER PRIMARY KEY)')
      ..execute('PRAGMA user_version = 3');
    db.close();
    expect(
      () => importTwicIssue(path, 1600, zipped(game)),
      throwsA(isA<StateError>()),
    );
    final after = sqlite3.open(path, mode: OpenMode.readOnly);
    addTearDown(after.close);
    expect(after.select('PRAGMA user_version').first.columnAt(0), 3);
  });

  test(
    'issue import is readable, classified and idempotent; a bad issue rolls back',
    () async {
      final bytes = zipped(
        '$game\n${game.replaceAll('Test Open', 'Test Blitz').replaceAll('1-0', '0-1')}',
      );
      expect(importTwicIssue(path, 1600, bytes), (2, 0));
      expect(importTwicIssue(path, 1600, bytes), (0, 0));
      final book = SqliteMasterBook(path);
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
      expect(masterGamesIssues(path).issues, {1600});
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
    expect(masterGamesIssues(path).issues, {1601});
    fail = false;
    await run.start(2);
    expect(run.problem, isNull);
    expect(masterGamesIssues(path).issues, {1600, 1601});
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
    expect(masterGamesIssues(path).issues, {1601});
    expect(run.status, contains('resume'));
  });

  test(
    'an unreadable database is set aside and the download starts a new one',
    () async {
      await File(
        path,
      ).writeAsString('this is not a database, just text ' * 200);
      final run = TwicDownload(
        path,
        client: () => MockClient((request) async {
          if (request.url.path == '/twic')
            return http.Response('twic1601g.zip', 200);
          return http.Response.bytes(zipped(game), 200);
        }),
      );
      addTearDown(run.dispose);
      await run.start(1);
      expect(run.problem, isNull);
      final copy = run.setAside!;
      expect(p.basename(copy), startsWith('master_games.db.unreadable-'));
      expect(run.status, contains(p.basename(copy)));
      expect(await File(copy).readAsString(), startsWith('this is not'));
      final reopened = masterGamesIssues(path);
      expect(reopened.issues, {1601});
      expect(reopened.setAside, isNull);
    },
  );

  test('a damaged page found mid-import is set aside too', () {
    importTwicIssue(path, 1600, zipped(game));
    final bytes = File(path).readAsBytesSync();
    // Keep the header, wreck every page after the first.
    for (var i = 4096; i < bytes.length; i++) bytes[i] = 0xAB;
    File(path).writeAsBytesSync(bytes);
    expect(importTwicIssue(path, 1601, zipped(game)), (1, 0));
    expect(masterGamesIssues(path).issues, {1601});
    expect(
      temp.listSync().map((e) => p.basename(e.path)),
      contains(startsWith('master_games.db.unreadable-')),
    );
  });

  List<List<Object?>> stored() {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return [
        for (final row in db.select(
          'SELECT event, white, black, result FROM games ORDER BY id',
        ))
          row.values,
      ];
    } finally {
      db.close();
    }
  }

  test('a UTF-8 file keeps its names, a character cut by a read boundary '
      'included, and imports once', () {
    // The first line puts the И of the second at byte 65535, across the
    // first 64 KiB the file is read in.
    final long = 'a' * 65515;
    final source = File(p.join(temp.path, 'utf8.pgn'))
      ..writeAsBytesSync(
        utf8.encode(
          '[Event "$long"]\r\n[White "Иванчук, Василий"]\r\n'
          '[Black "李超"]\r\n[Result "1/2-1/2"]\r\n\r\n'
          '1. e4 e5 1/2-1/2\r\n\r\n'
          '[Event "Unfinished"]\r\n[Result "*"]\r\n\r\n1. d4 *\r\n\r\n'
          '[Event "Ωmega"]\r\n[White "Ærø"]\r\n[Black "Łódź"]\r\n'
          '[Result "0-1"]\r\n\r\n1. c4 {Про\r\n[Event "X"] тест} e5 0-1\r\n',
        ),
      );
    expect(importMasterPgn(path, source.path), (2, 1));
    expect(stored(), [
      [long, 'Иванчук, Василий', '李超', '1/2-1/2'],
      ['Ωmega', 'Ærø', 'Łódź', '0-1'],
    ]);
    expect(importMasterPgn(path, source.path), (0, 0));
  });

  test('a file that is not UTF-8 past its first read is read as Latin-1 '
      'throughout, and imports once', () {
    final ascii = [
      for (var i = 0; i < 2000; i++)
        '[Event "Filler $i"]\n[Result "1-0"]\n\n1. e4 e5 2. Nf3 1-0\n\n',
    ].join();
    expect(ascii.length, greaterThan(65536));
    final source = File(p.join(temp.path, 'latin1.pgn'))
      ..writeAsBytesSync([
        ...ascii.codeUnits,
        ...latin1.encode(
          '[Event "Café"]\n[White "Müller"]\n[Black "Ñúñez"]\n'
          '[Result "0-1"]\n\n1. d4 d5 0-1\n',
        ),
      ]);
    expect(importMasterPgn(path, source.path), (2001, 0));
    expect(stored().last, ['Café', 'Müller', 'Ñúñez', '0-1']);
    expect(stored().first, ['Filler 0', '', '', '1-0']);
    expect(importMasterPgn(path, source.path), (0, 0));
  });

  test('a PGN file far larger than memory needs is read a game at a time', () {
    // About 200 MB: 200 short finished games, each carrying a 1 MB
    // comment. Takes a few seconds; the peak it checks is what stops a
    // large database export taking the whole app down.
    final source = File(p.join(temp.path, 'large.pgn'));
    final comment = 'a long note ' * ((1 << 20) ~/ 12);
    final out = source.openSync(mode: FileMode.write);
    for (var i = 0; i < 200; i++) {
      out.writeStringSync(
        '[Event "Large $i"]\n[Result "1-0"]\n\n'
        '1. e4 {$comment} e5 2. Nf3 1-0\n\n',
      );
    }
    out.closeSync();
    final size = source.lengthSync();
    expect(size, greaterThan(200 * 1000 * 1000));
    final before = ProcessInfo.maxRss;
    expect(importMasterPgn(path, source.path), (200, 0));
    expect(ProcessInfo.maxRss - before, lessThan(size));
  });

  test('a full disk reads as one', () {
    expect(
      describeImportFailure(
        SqliteException(
          extendedResultCode: 13,
          message: 'database or disk is full',
        ),
      ),
      'The disk is full.',
    );
    expect(
      describeImportFailure(
        FileSystemException(
          'write',
          'x',
          OSError('full', Platform.isWindows ? 112 : 28),
        ),
      ),
      'The disk is full.',
    );
    expect(
      describeImportFailure(
        SqliteException(extendedResultCode: 4874, message: 'disk I/O error'),
      ),
      'The disk is full.',
    );
    expect(describeImportFailure(StateError('other')), contains('other'));
  });
}
