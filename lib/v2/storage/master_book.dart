import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../chess/explorer_answer.dart';
import '../chess/fen.dart';
import '../diagnostics/log.dart';

/// The master games on this machine, read as an opening book: the old
/// app's `master_games.db` in the support folder, filled by its TWIC
/// import. Read only, and read as the old app writes it, so both apps see
/// one database and `v2` never has to import anything to have it.
///
/// The `book` table is keyed by a hash of the position's four FEN fields
/// (FNV-1a, 64-bit, the same sum the old app and the Python tools take),
/// one row per move played from it, with the results and, per row, the ids
/// of the strongest and the newest game that played it. Movetext in the
/// `games` table is zlib with a dictionary the importer kept in `meta`.

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

final class SqliteMasterBook implements MasterBook {
  SqliteMasterBook(this.path);

  /// `<support>/master_games.db`.
  final String path;

  Database? _db;
  List<int>? _dictionary;

  @override
  Future<bool> available() => File(path).exists();

  @override
  Future<BookLookup> lookup(Fen fen, {required bool classicalOnly}) async {
    if (!await available()) return const BookAbsent();
    try {
      final db = _open();
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

  /// The seven tags and the ratings, then the movetext as it was imported,
  /// which already ends in the result.
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
    final lines = [
      for (final MapEntry(:key, :value) in tags.entries)
        if (value != null && '$value'.isNotEmpty)
          '[$key "${'$value'.replaceAll('"', '\\"')}"]',
    ];
    final movetext = _decode(game['movetext'] as List<int>);
    return '${lines.join('\n')}\n\n$movetext\n';
  }

  String _decode(List<int> blob) {
    final dictionary = _dictionary ??= _readDictionary();
    final decoder = ZLibDecoder(
      dictionary: dictionary.isEmpty ? null : dictionary,
    );
    return utf8.decode(decoder.convert(blob));
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

const _fnvOffset = -3750763034362895579; // 0xcbf29ce484222325 as signed
const _fnvPrime = 1099511628211;

/// The book's key for [fen]: 64-bit FNV-1a over its four position fields,
/// the same sum the old app's importer took, so its rows are found.
int positionKey(Fen fen) {
  final text = fen.position;
  var hash = _fnvOffset;
  for (var i = 0; i < text.length; i++) {
    hash ^= text.codeUnitAt(i);
    hash *= _fnvPrime;
  }
  return hash;
}
