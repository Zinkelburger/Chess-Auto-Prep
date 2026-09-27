import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sqlite3/sqlite3.dart';

import '../chess/fen.dart';
import '../chess/pgn/game_text.dart';
import '../chess/pgn/move_text.dart';
import '../chess/pgn/pgn_reader.dart';

/// A separate derived cache: importing here never migrates or writes the
/// older app's master database. Each issue and its book counts commit together.
Set<int> downloadedTwicIssues(String path) {
  if (!File(path).existsSync()) return {};
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return {
      for (final row in db.select('SELECT issue FROM issues'))
        row['issue'] as int,
    };
  } finally {
    db.close();
  }
}

/// Runs off the UI isolate. An interrupted import rolls back the whole issue.
(int, int) importTwicIssue(String path, int issue, Uint8List zip) {
  final texts = _unzip(zip);
  File(path).parent.createSync(recursive: true);
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute(_schema);
    return _transaction(db, issue, texts);
  } finally {
    db.close();
  }
}

List<String> _unzip(Uint8List zip) {
  final archive = ZipDecoder().decodeBytes(zip, verify: true);
  final texts = <String>[];
  for (final file in archive.files) {
    if (!file.isFile || !file.name.toLowerCase().endsWith('.pgn')) continue;
    try {
      texts.add(utf8.decode(file.content));
    } on FormatException {
      texts.add(latin1.decode(file.content));
    }
  }
  if (texts.isEmpty) {
    throw const FormatException('TWIC archive contains no PGN.');
  }
  return texts;
}

(int, int) _transaction(Database db, int issue, List<String> texts) {
  db.execute('BEGIN IMMEDIATE');
  try {
    if (db.select('SELECT issue FROM issues WHERE issue = ?', [
      issue,
    ]).isNotEmpty) {
      db.execute('ROLLBACK');
      return (0, 0);
    }
    final (imported, skipped) = _games(db, texts);
    if (imported == 0) {
      throw const FormatException('No supported games in this TWIC issue.');
    }
    db.execute('INSERT INTO issues VALUES (?, ?, ?)', [
      issue,
      imported,
      skipped,
    ]);
    db.execute('COMMIT');
    return (imported, skipped);
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

(int, int) _games(Database db, List<String> texts) {
  final insert = db.prepare(
    'INSERT INTO games '
    '(event, site, date, round, white, black, result, white_elo, black_elo, eco, movetext) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
  );
  final move = db.prepare(_addMove);
  var imported = 0;
  var skipped = 0;
  try {
    for (final span in texts.expand((text) => splitChapterText(text).games)) {
      if (_game(db, insert, move, readGame(span.text))) {
        imported++;
      } else {
        skipped++;
      }
    }
    return (imported, skipped);
  } finally {
    insert.dispose();
    move.dispose();
  }
}

bool _game(
  Database db,
  PreparedStatement insert,
  PreparedStatement move,
  GameRead game,
) {
  final tree = game.tree;
  if (tree == null || tree.children.isEmpty || !game.rewritable) return false;
  final tags = {
    for (final tag in game.tags.whereType<PgnTag>()) tag.key: tag.value,
  };
  String tag(String key) => tags[key] ?? '';
  final result = tag('Result');
  final white = result == '1-0' ? 1 : 0;
  final draw = result == '1/2-1/2' ? 1 : 0;
  final black = result == '0-1' ? 1 : 0;
  if (white + draw + black == 0) return false;
  final classical =
      !tag('Site').trimRight().toUpperCase().endsWith('INT') &&
      !RegExp(
        r'blitz|rapid|bullet|armageddon|titled tue|esports',
        caseSensitive: false,
      ).hasMatch(tag('Event'));
  insert.execute([
    for (final key in [
      'Event',
      'Site',
      'Date',
      'Round',
      'White',
      'Black',
      'Result',
    ])
      tag(key),
    int.tryParse(tag('WhiteElo')),
    int.tryParse(tag('BlackElo')),
    tag('ECO'),
    Uint8List.fromList(
      zlib.encode(
        utf8.encode(writeMoveText(tree, terminator: game.terminator)),
      ),
    ),
  ]);
  final id = db.lastInsertRowId;
  var fen = tree.rootFen;
  var children = tree.children;
  final seen = <(int, String)>{};
  for (var ply = 0; ply < 40 && children.isNotEmpty; ply++) {
    final node = children.first;
    final key = (positionKey(fen), node.uci);
    if (seen.add(key)) {
      move.execute([
        key.$1,
        key.$2,
        white,
        draw,
        black,
        id,
        classical ? id : 0,
        classical ? 1 : 0,
        classical ? white : 0,
        classical ? draw : 0,
        classical ? black : 0,
      ]);
    }
    fen = node.fen;
    children = node.children;
  }
  return true;
}

const _schema = '''
CREATE TABLE IF NOT EXISTS issues (issue INTEGER PRIMARY KEY, games INTEGER, skipped INTEGER);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB);
CREATE TABLE IF NOT EXISTS games (
 id INTEGER PRIMARY KEY, event TEXT, site TEXT, date TEXT, round TEXT,
 white TEXT, black TEXT, result TEXT, white_elo INTEGER, black_elo INTEGER,
 eco TEXT, movetext BLOB
);
CREATE TABLE IF NOT EXISTS book (
 pos INTEGER, move TEXT, games INTEGER, white_wins INTEGER, draws INTEGER,
 black_wins INTEGER, top_game INTEGER, top_classical_game INTEGER,
 classical_games INTEGER, classical_white_wins INTEGER, classical_draws INTEGER,
 classical_black_wins INTEGER, PRIMARY KEY (pos, move)
) WITHOUT ROWID;
''';

const _addMove = '''
INSERT INTO book VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (pos, move) DO UPDATE SET
 games = games + 1, white_wins = white_wins + excluded.white_wins,
 draws = draws + excluded.draws, black_wins = black_wins + excluded.black_wins,
 classical_games = classical_games + excluded.classical_games,
 classical_white_wins = classical_white_wins + excluded.classical_white_wins,
 classical_draws = classical_draws + excluded.classical_draws,
 classical_black_wins = classical_black_wins + excluded.classical_black_wins,
 top_classical_game = CASE WHEN top_classical_game = 0
 THEN excluded.top_classical_game ELSE top_classical_game END
''';
