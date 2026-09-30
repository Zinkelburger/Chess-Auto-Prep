/// Writes `<support>/master_games.db`, the one master games database: TWIC
/// issues downloaded from the Databases page and PGN files imported there.
/// `SqliteMasterBook` and `SqliteMasterCorpus` read it; so do the Python
/// MCP tools, which is why the schema is fixed at [masterGamesSchema] and
/// every row is written the way the rows already in the file were:
///
/// * `games.movetext` is the main line as numbered SAN without the result,
///   zlib-compressed with the dictionary kept in `meta` (built from the
///   first games written to an empty file);
/// * `book` has one row per position and move over the first [bookPlies]
///   plies, with results, ratings, the strongest and newest game, and the
///   same counts again for classical over-the-board games only;
/// * `twic_issues` and `imports` name what is in, so each issue and each
///   file is imported exactly once, in one transaction with its games.
///
/// Only finished games from the initial position whose text reads without
/// issues are kept; the rest are counted as skipped.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../chess/fen.dart';
import '../chess/pgn/game_text.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/pgn_reader.dart';

/// The `user_version` of the file this writes, and the only one it writes to.
const masterGamesSchema = 4;

/// Plies indexed into `book`: move 15 covers every opening decision while
/// keeping the table a few gigabytes for a five-year corpus.
const bookPlies = 30;

/// Runs [work] on the database at [path], creating it when it is not there.
/// A file SQLite finds damaged or not a database is renamed with its
/// sidecars to `<name>.unreadable-<stamp>` and [work] runs once more on a
/// new file; [setAside] names the copy and [now] stamps it. Every other
/// failure, including a full disk, is rethrown with the unfinished
/// transaction rolled back.
T withMasterGames<T>(
  String path,
  T Function(Database) work, {
  void Function(String copy)? setAside,
  DateTime Function() now = DateTime.now,
}) {
  for (var attempt = 0; ; attempt++) {
    File(path).parent.createSync(recursive: true);
    Database? db;
    try {
      db = sqlite3.open(path);
      db.execute('PRAGMA busy_timeout = 5000');
      // Every issue dirties pages all over `book`; without a limit the
      // write-ahead log grows to the size of the database.
      db.execute('PRAGMA journal_size_limit = 67108864');
      _ensureSchema(db);
      return work(db);
    } on SqliteException catch (error) {
      if (attempt > 0 || !const [11, 26].contains(error.resultCode)) rethrow;
      db?.close();
      db = null;
      final copy = _setAside(path, now());
      setAside?.call(copy);
    } finally {
      db?.close();
    }
  }
}

/// The TWIC issues already in the database at [path].
({Set<int> issues, String? setAside}) masterGamesIssues(
  String path, {
  DateTime Function() now = DateTime.now,
}) {
  String? setAside;
  final issues = withMasterGames(
    path,
    (db) => {
      for (final row in db.select('SELECT issue FROM twic_issues'))
        row['issue'] as int,
    },
    setAside: (copy) => setAside = copy,
    now: now,
  );
  return (issues: issues, setAside: setAside);
}

/// Imports the PGN file at [source] into the database at [path]: (games
/// imported, games skipped), or (0, 0) when the same bytes were imported
/// before. The file itself is never changed.
///
/// The file is read twice in chunks rather than held whole, so a database
/// export of any size costs one game of memory: once for its fingerprint
/// and whether it is UTF-8, and again, only when it is new, for its games.
(int, int) importMasterPgn(String path, String source) {
  final file = File(source).openSync();
  try {
    final (fingerprint, isUtf8) = _scan(file);
    return withMasterGames(
      path,
      (db) => _importFile(db, file, fingerprint, isUtf8: isUtf8),
    );
  } finally {
    file.closeSync();
  }
}

/// One PGN file into an open database, as one transaction.
(int, int) _importFile(
  Database db,
  RandomAccessFile file,
  String fingerprint, {
  required bool isUtf8,
}) {
  String? read;
  return _transaction(
    db,
    done: () => db.select('SELECT 1 FROM imports WHERE fingerprint = ?', [
      fingerprint,
    ]).isNotEmpty,
    games: () => gamesOfLines(_lines(file, isUtf8, (digest) => read = digest)),
    issue: null,
    record: (games) {
      // The fingerprint names the games written, so a file changed between
      // the two reads is recorded as neither version.
      if (read != fingerprint) {
        throw FileSystemException(
          'The file changed while importing',
          file.path,
        );
      }
      db.execute('INSERT INTO imports VALUES (?, ?)', [fingerprint, games]);
    },
  );
}

/// Imports one TWIC issue's zip into the database at [path]. Runs off the
/// UI isolate; an interrupted import leaves the whole issue out.
(int, int) importTwicIssue(String path, int issue, Uint8List zip) =>
    withMasterGames(path, (db) => importTwicIssueInto(db, issue, zip));

/// One issue into an open database, as one transaction.
(int, int) importTwicIssueInto(Database db, int issue, Uint8List zip) =>
    _transaction(
      db,
      done: () => db.select('SELECT 1 FROM twic_issues WHERE issue = ?', [
        issue,
      ]).isNotEmpty,
      games: () => _unzip(
        zip,
      ).expand((t) => splitChapterText(t).games.map((g) => g.text)),
      issue: issue,
      record: (games) => db.execute(
        'INSERT INTO twic_issues VALUES (?, ?, ?)',
        [issue, games, DateTime.now().millisecondsSinceEpoch],
      ),
    );

/// Why writing the database failed, in words the user can act on.
String describeImportFailure(Object error) {
  final full = switch (error) {
    // SQLITE_FULL, or SQLITE_IOERR_SHMSIZE: no room to open the
    // write-ahead log's shared-memory index.
    SqliteException(:final resultCode, :final extendedResultCode) =>
      resultCode == 13 || extendedResultCode == 4874,
    FileSystemException(:final osError?) =>
      Platform.isWindows
          ? const [39, 112].contains(osError.errorCode)
          : osError.errorCode == 28,
    _ => false,
  };
  return full ? 'The disk is full.' : '$error';
}

/// Creates the tables in a new file; refuses a file of another version
/// rather than guess at its columns. A current file is only read, so listing
/// its issues never waits for an import's write lock.
void _ensureSchema(Database db) {
  if (!_schemaReady(db)) _createTables(db);
  // Outside the transaction, where SQLite allows the change. It stays with
  // the file, so readers never wait on an import's commit.
  db.execute('PRAGMA journal_mode = WAL');
}

void _createTables(Database db) {
  db.execute('BEGIN IMMEDIATE');
  try {
    // Checked again under the lock: another writer may have got here first.
    if (_isEmpty(db)) {
      db.execute(_schema);
      db.execute('INSERT INTO meta VALUES (?, ?)', [
        'classical_counts',
        utf8.encode('complete'),
      ]);
      db.execute('PRAGMA user_version = $masterGamesSchema');
    }
    // Added after version 4 was fixed; the other readers ignore it.
    db.execute(_importsTable);
    db.execute('COMMIT');
  } on Object {
    _rollBack(db);
    rethrow;
  }
}

/// Whether the file holds every table this writes: false for a new file;
/// a file of another version throws.
bool _schemaReady(Database db) {
  if (_isEmpty(db)) return false;
  final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
  if (version != masterGamesSchema) {
    throw StateError(
      'The master games database is schema version $version; this app '
      'writes version $masterGamesSchema.',
    );
  }
  return db
      .select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' "
        "AND name = 'imports'",
      )
      .isNotEmpty;
}

bool _isEmpty(Database db) =>
    db.select('PRAGMA user_version').first.columnAt(0) == 0 &&
    db.select("SELECT 1 FROM sqlite_master WHERE type = 'table'").isEmpty;

String _setAside(String path, DateTime now) {
  final iso = now.toUtc().toIso8601String();
  final stamp = iso.replaceAll(RegExp(r'[-:]|\..*'), '');
  const suffixes = ['', '-wal', '-shm', '-journal'];
  // A rename replaces its target, so a name any earlier copy or its
  // sidecars hold is never reused.
  var copy = '$path.unreadable-$stamp';
  for (var n = 2; suffixes.any((s) => File('$copy$s').existsSync()); n++)
    copy = '$path.unreadable-$stamp-$n';
  for (final suffix in suffixes) {
    final file = File('$path$suffix');
    if (file.existsSync()) file.renameSync('$copy$suffix');
  }
  return copy;
}

String _decode(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// The file read from its start in 64 KiB pieces.
Iterable<Uint8List> _chunks(RandomAccessFile file) sync* {
  file.setPositionSync(0);
  for (var chunk = file.readSync(65536); chunk.isNotEmpty;) {
    yield chunk;
    chunk = file.readSync(65536);
  }
}

/// The file's SHA-256 and whether all of it is UTF-8; the text itself is
/// thrown away as it is decoded. A file that is not is Latin-1 throughout,
/// as [_decode] reads it.
(String, bool) _scan(RandomAccessFile file) {
  final digest = _Collect<Digest>();
  final hash = sha256.startChunkedConversion(digest);
  final text = _Collect<String>();
  final decoder = const Utf8Decoder().startChunkedConversion(text);
  var isUtf8 = true;
  for (final chunk in _chunks(file)) {
    hash.add(chunk);
    if (!isUtf8) continue;
    try {
      decoder.add(chunk);
    } on FormatException {
      isUtf8 = false;
    }
    text.items.clear();
  }
  hash.close();
  if (isUtf8) {
    try {
      decoder.close();
    } on FormatException {
      isUtf8 = false;
    }
  }
  return (digest.items.single.toString(), isUtf8);
}

/// The file's lines, each with the `\n` that ends it, decoded as [_scan]
/// found it; [fingerprint] is told the SHA-256 of what was read once the
/// last line is out.
Iterable<String> _lines(
  RandomAccessFile file,
  bool isUtf8,
  void Function(String) fingerprint,
) sync* {
  final digest = _Collect<Digest>();
  final hash = sha256.startChunkedConversion(digest);
  final text = _Collect<String>();
  final decoder = (isUtf8 ? const Utf8Decoder() : const Latin1Decoder())
      .startChunkedConversion(text);
  final line = StringBuffer();
  Iterable<String> cut() sync* {
    for (final piece in text.items) {
      var from = 0;
      for (
        var at = piece.indexOf('\n');
        at >= 0;
        at = piece.indexOf('\n', from)
      ) {
        line.write(piece.substring(from, at + 1));
        yield line.toString();
        line.clear();
        from = at + 1;
      }
      line.write(piece.substring(from));
    }
    text.items.clear();
  }

  for (final chunk in _chunks(file)) {
    hash.add(chunk);
    decoder.add(chunk);
    yield* cut();
  }
  hash.close();
  decoder.close();
  yield* cut();
  if (line.isNotEmpty) yield line.toString();
  fingerprint(digest.items.single.toString());
}

/// Keeps what a chunked conversion hands on until the caller takes it.
final class _Collect<T> implements Sink<T> {
  final items = <T>[];

  @override
  void add(T item) => items.add(item);

  @override
  void close() {}
}

List<String> _unzip(Uint8List zip) {
  final archive = ZipDecoder().decodeBytes(zip, verify: true);
  final texts = [
    for (final file in archive.files)
      if (file.isFile && file.name.toLowerCase().endsWith('.pgn'))
        _decode(file.content),
  ];
  if (texts.isEmpty)
    throw const FormatException('TWIC archive contains no PGN.');
  return texts;
}

/// Imports [games], each one game's text, unless [done] says they are in,
/// then [record]s them, all in one transaction: a failure anywhere leaves
/// the database as it was.
(int, int) _transaction(
  Database db, {
  required bool Function() done,
  required Iterable<String> Function() games,
  required int? issue,
  required void Function(int games) record,
}) {
  final (int, int) counts;
  db.execute('BEGIN IMMEDIATE');
  try {
    if (done()) {
      db.execute('ROLLBACK');
      return (0, 0);
    }
    counts = _Writer(db, issue).write(games());
    if (counts.$1 == 0) {
      throw FormatException(
        issue == null
            ? 'No supported finished games.'
            : 'No supported games in this TWIC issue.',
      );
    }
    record(counts.$1);
    db.execute('COMMIT');
  } on Object {
    _rollBack(db);
    rethrow;
  }
  // Fold the log back into the file now. Best effort: a reader mid-query
  // makes this partial, and one that cannot run costs only disk space.
  try {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  } on SqliteException {
    // See above.
  }
  return counts;
}

/// A failed rollback must not hide the failure that caused it; SQLite rolls
/// an unfinished transaction back on the next open anyway.
void _rollBack(Database db) {
  try {
    if (!db.autocommit) db.execute('ROLLBACK');
  } on SqliteException {
    // Reported through the original failure.
  }
}

/// One game as the database keeps it.
final class _Game {
  _Game(this.tags, this.line) : movetext = _numbered(line);

  final Map<String, String> tags;

  /// The main line from the initial position.
  final List<MoveNode> line;
  final String movetext;

  String tag(String key) => tags[key] ?? '';
  int? rating(String key) => int.tryParse(tag(key).trim());
  int? get whiteElo => rating('WhiteElo');
  int? get blackElo => rating('BlackElo');

  /// The year played, else the event's year, else 0.
  int get year => _year(tag('Date')) ?? _year(tag('EventDate')) ?? 0;

  static int? _year(String date) {
    final year = date.length < 4 ? null : int.tryParse(date.substring(0, 4));
    return year != null && year >= 1000 ? year : null;
  }

  static String _numbered(List<MoveNode> line) => [
    for (final (ply, move) in line.indexed)
      ply.isEven ? '${ply ~/ 2 + 1}. ${move.san}' : move.san,
  ].join(' ');
}

/// Writes games and their book rows through statements prepared once.
final class _Writer {
  _Writer(this.db, this.issue);

  final Database db;
  final int? issue;

  /// (games imported, games skipped) of [games], each one game's text.
  (int, int) write(Iterable<String> games) {
    final read = games.map((text) => _gameOf(readGame(text)));
    final insert = db.prepare(_insertGame);
    final upsert = db.prepare(_upsertBook);
    var imported = 0;
    var skipped = 0;
    try {
      ZLibEncoder? encoder;
      final waiting = <_Game>[];
      void store(_Game game) {
        _store(insert, upsert, encoder!, game);
        imported++;
      }

      for (final game in read) {
        if (game == null) {
          skipped++;
        } else if (encoder != null) {
          store(game);
        } else {
          // An empty database takes its dictionary from its first games.
          waiting.add(game);
          encoder = _encoder(waiting, enough: false);
          if (encoder != null) waiting.forEach(store);
        }
      }
      if (encoder == null && waiting.isNotEmpty) {
        encoder = _encoder(waiting, enough: true);
        waiting.forEach(store);
      }
      return (imported, skipped);
    } finally {
      insert.close();
      upsert.close();
    }
  }

  /// The file's movetext encoder: its stored dictionary, or one made from
  /// [waiting] once they are [enough] for it (32 KiB, zlib's whole window).
  ZLibEncoder? _encoder(List<_Game> waiting, {required bool enough}) {
    final stored = db.select('SELECT value FROM meta WHERE key = ?', [
      'movetext_dict',
    ]);
    if (stored.isNotEmpty) return _zlib(stored.first['value'] as List<int>);
    final sample = utf8.encode(waiting.map((g) => g.movetext).join(' '));
    if (!enough && sample.length < _dictionaryBytes) return null;
    final dictionary = sample.length <= _dictionaryBytes
        ? sample
        : sample.sublist(0, _dictionaryBytes);
    db.execute('INSERT INTO meta VALUES (?, ?)', ['movetext_dict', dictionary]);
    return _zlib(dictionary);
  }

  static ZLibEncoder _zlib(List<int> dictionary) =>
      ZLibEncoder(level: 9, dictionary: dictionary.isEmpty ? null : dictionary);

  static _Game? _gameOf(GameRead read) {
    final tree = read.tree;
    if (tree == null || !read.rewritable || tree.rootFen != Fen.initial) {
      return null;
    }
    final line = <MoveNode>[];
    for (var at = tree.children; at.isNotEmpty; at = at.first.children) {
      // Without its comments and variations, which a game waiting for the
      // movetext dictionary would otherwise keep in memory.
      final move = at.first;
      line.add(MoveNode(san: move.san, uci: move.uci, fen: move.fen));
    }
    final tags = {
      for (final tag in read.tags.whereType<PgnTag>()) tag.key: tag.value,
    };
    final game = _Game(tags, line);
    if (line.isEmpty || !_results.contains(game.tag('Result'))) return null;
    return game;
  }

  void _store(
    PreparedStatement insert,
    PreparedStatement upsert,
    ZLibEncoder encoder,
    _Game game,
  ) {
    final authority = _authority(game.tag('Site'), game.tag('Event'));
    insert.execute([
      issue,
      for (final key in _stringTags) game.tag(key),
      game.whiteElo,
      game.blackElo,
      game.rating('WhiteFideId'),
      game.rating('BlackFideId'),
      game.tag('ECO'),
      game.line.length,
      Uint8List.fromList(encoder.convert(utf8.encode(game.movetext))),
      authority,
    ]);
    final id = db.lastInsertRowId;
    final result = game.tag('Result');
    final (white, draw, black) = (
      result == '1-0' ? 1 : 0,
      result == '1/2-1/2' ? 1 : 0,
      result == '0-1' ? 1 : 0,
    );
    final (whiteElo, blackElo) = (game.whiteElo, game.blackElo);
    final strongest = max(whiteElo ?? 0, blackElo ?? 0);
    final classical = authority == 0;
    var fen = Fen.initial;
    final seen = <(int, String)>{};
    for (final (ply, move) in game.line.take(bookPlies).indexed) {
      // A repetition plays the same move from the same position twice; the
      // game still counts once for it.
      final key = (positionKey(fen), move.uci);
      if (seen.add(key)) {
        upsert.execute([
          key.$1,
          key.$2,
          ply,
          white,
          draw,
          black,
          (whiteElo ?? 0) + (blackElo ?? 0),
          (whiteElo == null ? 0 : 1) + (blackElo == null ? 0 : 1),
          strongest,
          game.year,
          id,
          id,
          classical ? id : 0,
          classical ? strongest : 0,
          classical ? 1 : 0,
          classical ? white : 0,
          classical ? draw : 0,
          classical ? black : 0,
        ]);
      }
      fen = move.fen;
    }
  }
}

const _results = {'1-0', '0-1', '1/2-1/2'};

const _stringTags = [
  'Event',
  'Site',
  'Date',
  'Round',
  'White',
  'Black',
  'Result',
];

const _dictionaryBytes = 32768;

/// `games.authority`: 0 classical over the board, 1 a faster game over the
/// board, 2 online. Every online venue in TWIC writes a `Site` ending in
/// `INT`; the event name carries the speed when there is one. Only
/// classical games are cited and counted as classical in `book`.
int _authority(String site, String event) {
  if (site.trimRight().toUpperCase().endsWith('INT')) return 2;
  final speed = RegExp(
    'blitz|rapid|bullet|armageddon|titled tue|esports',
    caseSensitive: false,
  );
  return speed.hasMatch(event) ? 1 : 0;
}

const _insertGame =
    'INSERT INTO games (twic, event, site, date, round, white, black, result, '
    'white_elo, black_elo, white_fide, black_fide, eco, ply_count, movetext, '
    'authority) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

/// A move already in `book` adds this game's counts; its strongest and
/// newest game change only when this one is stronger or newer.
const _upsertBook = '''
INSERT INTO book (pos, move, ply, games, white_wins, draws, black_wins,
 elo_sum, elo_n, max_elo, last_year, top_game, recent_game,
 top_classical_game, classical_max_elo, classical_games,
 classical_white_wins, classical_draws, classical_black_wins)
VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (pos, move) DO UPDATE SET
 games = games + 1,
 white_wins = white_wins + excluded.white_wins,
 draws = draws + excluded.draws,
 black_wins = black_wins + excluded.black_wins,
 elo_sum = elo_sum + excluded.elo_sum,
 elo_n = elo_n + excluded.elo_n,
 top_game = CASE WHEN excluded.max_elo > max_elo
  THEN excluded.top_game ELSE top_game END,
 max_elo = MAX(max_elo, excluded.max_elo),
 recent_game = CASE WHEN excluded.last_year >= last_year
  THEN excluded.recent_game ELSE recent_game END,
 last_year = MAX(last_year, excluded.last_year),
 top_classical_game = CASE WHEN excluded.top_classical_game != 0
  AND (top_classical_game = 0 OR excluded.classical_max_elo > classical_max_elo)
  THEN excluded.top_classical_game ELSE top_classical_game END,
 classical_max_elo = MAX(classical_max_elo, excluded.classical_max_elo),
 classical_games = classical_games + excluded.classical_games,
 classical_white_wins = classical_white_wins + excluded.classical_white_wins,
 classical_draws = classical_draws + excluded.classical_draws,
 classical_black_wins = classical_black_wins + excluded.classical_black_wins,
 ply = MIN(ply, excluded.ply)
''';

const _importsTable =
    'CREATE TABLE IF NOT EXISTS imports '
    '(fingerprint TEXT PRIMARY KEY, games INTEGER NOT NULL)';

/// Version 4, as the older app created it.
const _schema = '''
CREATE TABLE games (
 id INTEGER PRIMARY KEY, twic INTEGER,
 event TEXT NOT NULL DEFAULT '', site TEXT NOT NULL DEFAULT '',
 date TEXT NOT NULL DEFAULT '', round TEXT NOT NULL DEFAULT '',
 white TEXT NOT NULL DEFAULT '', black TEXT NOT NULL DEFAULT '',
 result TEXT NOT NULL DEFAULT '*', white_elo INTEGER, black_elo INTEGER,
 white_fide INTEGER, black_fide INTEGER, eco TEXT NOT NULL DEFAULT '',
 ply_count INTEGER NOT NULL DEFAULT 0, movetext BLOB NOT NULL,
 authority INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX games_twic ON games(twic);
CREATE INDEX games_white ON games(white COLLATE NOCASE);
CREATE INDEX games_black ON games(black COLLATE NOCASE);
CREATE INDEX games_white_fide ON games(white_fide);
CREATE INDEX games_black_fide ON games(black_fide);
CREATE INDEX games_date ON games(date);
CREATE INDEX games_eco ON games(eco);
CREATE TABLE book (
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
 PRIMARY KEY (pos, move)
) WITHOUT ROWID;
CREATE TABLE twic_issues (
 issue INTEGER PRIMARY KEY, games INTEGER NOT NULL,
 imported_at INTEGER NOT NULL
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
''';
