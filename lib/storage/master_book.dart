import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../chess/explorer_answer.dart';
import '../chess/fen.dart';
import '../chess/pgn/game_text.dart';
import '../diagnostics/log.dart';

/// The master games on this machine, read as an opening book:
/// `<support>/master_games.db`, which `master_games_import.dart` writes.
///
/// The `book` table is keyed by a hash of the position's four FEN fields
/// (FNV-1a, 64-bit, the same sum the Python tools take), one row per move
/// played from it, with the results and, per row, the ids of the strongest
/// and the newest game that played it. Movetext in the `games` table is
/// zlib with a dictionary kept in `meta`.

sealed class BookLookup {
  const BookLookup();
}

final class BookFound extends BookLookup {
  const BookFound(this.answer);

  final ExplorerAnswer answer;
}

/// There is no database on this machine.
final class BookAbsent extends BookLookup {
  const BookAbsent();
}

/// The file is there but could not be read; the tab says so.
final class BookUnreadable extends BookLookup {
  const BookUnreadable(this.detail);

  final String detail;
}

/// Classical only was asked of a book whose classical counts the old app
/// has not finished building (`meta.classical_counts`); they would read as
/// a near-empty answer, so the tab says the index is missing instead.
final class BookClassicalIncomplete extends BookLookup {
  const BookClassicalIncomplete();
}

/// SQLite is a real boundary: [SqliteMasterBook] in the app, a scripted
/// one in tests.
abstract interface class MasterBook {
  /// Whether there is a database to ask. The tab lists TWIC only when
  /// there is.
  Future<bool> available();

  /// The moves from [fen], most played first, with games worth opening.
  /// [classicalOnly] counts classical over-the-board games and no others.
  Future<BookLookup> lookup(Fen fen, {required bool classicalOnly});

  /// The PGN of the game [id] names, or null when it cannot be read.
  Future<String?> gamePgn(String id);
}

/// How many games the answer names: the old app's number for TWIC.
const twicGamesListed = 12;

/// SQLite can wait on the importer or a cold disk. Run reads off the UI
/// isolate so source/filter clicks and closing menus never wait on that lock.
final class SqliteMasterBook implements MasterBook {
  SqliteMasterBook(this.path);
  final String path;

  @override
  Future<bool> available() => _readBook(path, (book) => book.available());

  @override
  Future<BookLookup> lookup(Fen fen, {required bool classicalOnly}) =>
      _readBook(path, (book) => book.lookup(fen, classicalOnly: classicalOnly));

  @override
  Future<String?> gamePgn(String id) =>
      _readBook(path, (book) => book.gamePgn(id));
}

Future<T> _readBook<T>(
  String path,
  Future<T> Function(_SqliteMasterReader) read,
) => Isolate.run(() async {
  final book = _SqliteMasterReader(path);
  try {
    return await read(book);
  } finally {
    book.close();
  }
});

final class _SqliteMasterReader implements MasterBook {
  _SqliteMasterReader(this.path);

  /// `<support>/master_games.db`.
  final String path;

  Database? _db;
  List<int>? _dictionary;

  @override
  Future<bool> available() async {
    if (!await File(path).exists()) return false;
    try {
      return _open().select('SELECT 1 FROM games LIMIT 1').isNotEmpty;
    } on Object {
      return false;
    }
  }

  @override
  Future<BookLookup> lookup(Fen fen, {required bool classicalOnly}) async {
    if (!await File(path).exists()) return const BookAbsent();
    try {
      final db = _open();
      if (db.select('SELECT 1 FROM games LIMIT 1').isEmpty)
        return const BookAbsent();
      if (classicalOnly && !_classicalComplete(db))
        return const BookClassicalIncomplete();
      final rows = db.select(_bookSql, [positionKey(fen)]);
      final moves = <ExplorerMove>[];
      final citedBy = <String, int>{};
      for (final row in rows) {
        final move = _moveOf(row, classicalOnly: classicalOnly);
        if (move.games == 0) continue;
        moves.add(move);
        final column = classicalOnly ? 'topClassical' : 'top';
        citedBy[move.uci] = row[column] as int;
      }
      moves.sort((a, b) => b.games.compareTo(a.games));
      // The games in the moves' order, most played first, each once.
      final gameIds = <int>{
        for (final move in moves)
          if (citedBy[move.uci] case final id? when id != 0) id,
      };
      final games = [
        for (final id in gameIds.take(twicGamesListed))
          if (_gameRow(db, id) case final game?) _summaryOf(game),
      ];
      return BookFound(ExplorerAnswer(moves: moves, games: games));
    } on Object catch (error) {
      log.w('read the master book at $path', error);
      return BookUnreadable('$error');
    }
  }

  @override
  Future<String?> gamePgn(String id) async {
    final number = int.tryParse(id);
    if (number == null || !await available()) return null;
    try {
      final row = _gameRow(_open(), number);
      return row == null ? null : _pgnOf(row);
    } on Object catch (error) {
      log.w('read game $id from the master book', error);
      return null;
    }
  }

  Database _open() {
    final open = _db;
    if (open != null) return open;
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    db.execute('PRAGMA busy_timeout = 2000');
    return _db = db;
  }

  void close() {
    _db?.close();
    _db = null;
  }

  static const _bookSql =
      'SELECT move, games, white_wins, draws, black_wins, top_game AS top, '
      'top_classical_game AS topClassical, classical_games, '
      'classical_white_wins, classical_draws, classical_black_wins '
      'FROM book WHERE pos = ?';

  static const _gameSql =
      'SELECT id, event, site, date, round, white, black, result, '
      'white_elo, black_elo, eco, movetext FROM games WHERE id = ?';

  ExplorerMove _moveOf(Row row, {required bool classicalOnly}) {
    final uci = row['move'] as String;
    return classicalOnly
        ? ExplorerMove(
            uci: uci,
            san: '',
            white: row['classical_white_wins'] as int,
            draws: row['classical_draws'] as int,
            black: row['classical_black_wins'] as int,
          )
        : ExplorerMove(
            uci: uci,
            san: '',
            white: row['white_wins'] as int,
            draws: row['draws'] as int,
            black: row['black_wins'] as int,
          );
  }

  Row? _gameRow(Database db, int id) {
    final rows = db.select(_gameSql, [id]);
    return rows.isEmpty ? null : rows.first;
  }

  ExplorerGame _summaryOf(Row game) => ExplorerGame(
    id: '${game['id']}',
    white: game['white'] as String,
    black: game['black'] as String,
    whiteElo: game['white_elo'] as int?,
    blackElo: game['black_elo'] as int?,
    result: game['result'] as String,
    year: _yearOf(game['date'] as String),
    event: game['event'] as String,
  );

  static int? _yearOf(String date) =>
      date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;

  /// The seven tags and the ratings, then the stored main line and the
  /// result, which the database keeps in its column rather than the moves.
  String _pgnOf(Row game) {
    final tags = <String, Object?>{
      'Event': game['event'],
      'Site': game['site'],
      'Date': game['date'],
      'Round': game['round'],
      'White': game['white'],
      'Black': game['black'],
      'Result': game['result'],
      'WhiteElo': game['white_elo'],
      'BlackElo': game['black_elo'],
      'ECO': game['eco'],
    };
    // Through [PgnTag], which escapes a backslash as well as a quote: a
    // value ending in one would otherwise swallow its closing quote.
    final lines = [
      for (final MapEntry(:key, :value) in tags.entries)
        if (value != null && '$value'.isNotEmpty) PgnTag(key, '$value').text,
    ];
    final movetext = _decode(game['movetext'] as List<int>);
    return '${lines.join('\n')}\n\n$movetext ${game['result']}\n';
  }

  String _decode(List<int> blob) {
    final dictionary = _dictionary ??= _readDictionary();
    final decoder = ZLibDecoder(
      dictionary: dictionary.isEmpty ? null : dictionary,
    );
    return utf8.decode(decoder.convert(blob));
  }

  /// Whether the old app has built every row's classical counts. It marks
  /// a migrated or rebuilding file `incomplete`; a missing key reads as
  /// built, as it does there.
  bool _classicalComplete(Database db) {
    final rows = db.select('SELECT value FROM meta WHERE key = ?', [
      'classical_counts',
    ]);
    if (rows.isEmpty) return true;
    final marker = switch (rows.first['value']) {
      final List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      final String text => text,
      _ => null,
    };
    return marker == 'complete';
  }

  List<int> _readDictionary() {
    final rows = _open().select('SELECT value FROM meta WHERE key = ?', [
      'movetext_dict',
    ]);
    if (rows.isEmpty) return const [];
    return switch (rows.first['value']) {
      final List<int> bytes => bytes,
      _ => const [],
    };
  }
}
