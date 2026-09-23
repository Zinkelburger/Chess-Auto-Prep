import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/storage/master_book.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// A master database with the old app's tables, two moves from the start
/// and the two games they cite. Movetext is plain zlib: no dictionary in
/// `meta`, which is what a database looks like before its first import
/// wrote one.
void _fill(String path) {
  final db = sqlite3.open(path);
  _createTables(db);
  _fillBook(db);
  _fillGames(db);
  db.close();
}

void _createTables(Database db) {
  db.execute('''
    CREATE TABLE games(
      id INTEGER PRIMARY KEY, twic INTEGER, event TEXT NOT NULL DEFAULT '',
      site TEXT NOT NULL DEFAULT '', date TEXT NOT NULL DEFAULT '',
      round TEXT NOT NULL DEFAULT '', white TEXT NOT NULL DEFAULT '',
      black TEXT NOT NULL DEFAULT '', result TEXT NOT NULL DEFAULT '*',
      white_elo INTEGER, black_elo INTEGER, white_fide INTEGER,
      black_fide INTEGER, eco TEXT NOT NULL DEFAULT '',
      ply_count INTEGER NOT NULL DEFAULT 0, movetext BLOB NOT NULL,
      authority INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE book(
      pos INTEGER NOT NULL, move TEXT NOT NULL, ply INTEGER NOT NULL,
      games INTEGER NOT NULL, white_wins INTEGER NOT NULL,
      draws INTEGER NOT NULL, black_wins INTEGER NOT NULL,
      elo_sum INTEGER NOT NULL, elo_n INTEGER NOT NULL,
      max_elo INTEGER NOT NULL, last_year INTEGER NOT NULL,
      top_game INTEGER NOT NULL, recent_game INTEGER NOT NULL,
      top_classical_game INTEGER NOT NULL DEFAULT 0,
      classical_max_elo INTEGER NOT NULL DEFAULT 0,
      classical_games INTEGER NOT NULL DEFAULT 0,
      classical_white_wins INTEGER NOT NULL DEFAULT 0,
      classical_draws INTEGER NOT NULL DEFAULT 0,
      classical_black_wins INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(pos, move)
    ) WITHOUT ROWID;
    CREATE TABLE meta(key TEXT PRIMARY KEY, value BLOB NOT NULL);
  ''');
}

void _fillBook(Database db) {
  final key = positionKey(Fen.initial);
  db.execute(
    'INSERT INTO book VALUES(?, ?, 0, 30, 10, 15, 5, 0, 0, 2800, 2024, 1, 1, '
    '2, 2700, 3, 1, 1, 1)',
    [key, 'e2e4'],
  );
  db.execute(
    'INSERT INTO book VALUES(?, ?, 0, 40, 20, 10, 10, 0, 0, 2750, 2023, 2, 2, '
    '0, 0, 0, 0, 0, 0)',
    [key, 'd2d4'],
  );
}

void _fillGames(Database db) {
  List<int> zipped(String movetext) =>
      ZLibEncoder().convert(utf8.encode(movetext));
  db.execute(
    'INSERT INTO games(id, event, site, date, round, white, black, result, '
    'white_elo, black_elo, eco, ply_count, movetext) '
    'VALUES(1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 3, ?)',
    [
      'Tata Steel',
      'Wijk aan Zee',
      '2024.01.13',
      '1',
      'Carlsen, Magnus',
      'Nakamura, Hikaru',
      '1-0',
      2830,
      2780,
      'C42',
      zipped('1. e4 e5 2. Nf3 1-0'),
    ],
  );
  db.execute(
    'INSERT INTO games(id, event, date, white, black, result, movetext) '
    'VALUES(2, ?, ?, ?, ?, ?, ?)',
    [
      'Rapid',
      '2023.05.01',
      'Ding, Liren',
      'Giri, Anish',
      '1/2-1/2',
      zipped('1. d4 1/2-1/2'),
    ],
  );
}

void main() {
  late Directory folder;
  late SqliteMasterBook book;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('master-book-');
    final path = p.join(folder.path, 'master_games.db');
    _fill(path);
    book = SqliteMasterBook(path);
  });

  tearDown(() async {
    book.close();
    await folder.delete(recursive: true);
  });

  test('a database that is not there is absent, and so is the book', () async {
    final absent = SqliteMasterBook(p.join(folder.path, 'nowhere.db'));
    expect(await absent.available(), isFalse);
    expect(
      await absent.lookup(Fen.initial, classicalOnly: false),
      isA<BookAbsent>(),
    );
    expect(await absent.gamePgn('1'), isNull);
  });

  test('the moves from the position, most played first, with the games '
      'they cite', () async {
    expect(await book.available(), isTrue);
    final found =
        await book.lookup(Fen.initial, classicalOnly: false) as BookFound;
    expect(found.answer.moves.map((m) => m.uci), ['d2d4', 'e2e4']);
    expect(found.answer.moves.first.games, 40);
    expect(found.answer.moves.last.draws, 15);
    expect(found.answer.games.map((g) => g.id), ['2', '1']);
    expect(found.answer.games.last.white, 'Carlsen, Magnus');
    expect(found.answer.games.last.year, 2024);
    expect(found.answer.games.last.event, 'Tata Steel');
    expect(found.answer.games.first.whiteElo, isNull);
  });

  test('classical only counts the classical columns and cites the '
      'classical game; a move with no classical games gets no row', () async {
    final found =
        await book.lookup(Fen.initial, classicalOnly: true) as BookFound;
    expect(found.answer.moves.map((m) => m.uci), ['e2e4']);
    expect(found.answer.moves.single.games, 3);
    expect(found.answer.games.map((g) => g.id), ['2']);
  });

  test('a position the book has not seen is an empty answer', () async {
    const after = Fen(
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
    );
    final found = await book.lookup(after, classicalOnly: false) as BookFound;
    expect(found.answer.isEmpty, isTrue);
  });

  test('a game is read back as PGN with its tags and movetext', () async {
    final pgn = await book.gamePgn('1');
    expect(pgn, contains('[White "Carlsen, Magnus"]'));
    expect(pgn, contains('[WhiteElo "2830"]'));
    expect(pgn, contains('[ECO "C42"]'));
    expect(pgn, endsWith('\n\n1. e4 e5 2. Nf3 1-0\n'));
    expect(await book.gamePgn('9'), isNull);
    expect(await book.gamePgn('one'), isNull);
  });

  test('a tag value with a backslash or a quote in it reads back as it was '
      'imported', () async {
    const event = r'C:\TWIC\';
    const site = 'The "Kurhaus"';
    final db = sqlite3.open(p.join(folder.path, 'master_games.db'));
    db.execute(
      'INSERT INTO games(id, event, site, result, movetext) '
      'VALUES(3, ?, ?, ?, ?)',
      [event, site, '1-0', ZLibEncoder().convert(utf8.encode('1. e4 1-0'))],
    );
    db.close();

    final read = readGame((await book.gamePgn('3'))!);

    expect(tagValue(read.tags, 'Event'), event);
    expect(tagValue(read.tags, 'Site'), site);
    expect(read.rewritable, isTrue);
  });

  test('a file that is not a database is unreadable, not a crash', () async {
    final path = p.join(folder.path, 'broken.db');
    await File(path).writeAsString('not sqlite');
    final broken = SqliteMasterBook(path);
    addTearDown(broken.close);
    expect(
      await broken.lookup(Fen.initial, classicalOnly: false),
      isA<BookUnreadable>(),
    );
  });

  test('the key is the old app\'s FNV-1a over the four position fields', () {
    // The counters are not part of the position.
    expect(
      positionKey(const Fen('8/8/8/8/8/8/8/K6k w - - 5 40')),
      positionKey(const Fen('8/8/8/8/8/8/8/K6k w - - 0 1')),
    );
    expect(
      positionKey(Fen.initial),
      isNot(positionKey(const Fen('8/8/8/8/8/8/8/K6k w - - 0 1'))),
    );
  });
}
