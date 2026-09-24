import 'dart:io';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../chess/bughouse/table.dart';
import '../diagnostics/log.dart';

/// The FICS archive the Python tools build under
/// `~/.local/share/chess-prep/bughouse-db/`, read only and never written:
/// `bughouse_book.db` (`tools/bughouse_db/index.py`), what 21 years of FICS
/// games played from a position, with team results.
///
/// It keys a position by [TablePosition.bookKey], so every order of moves
/// that reaches a table finds it. A machine without it is the usual case:
/// the lab hides the archive.

/// Where a book named [fileName] is looked for: `$BUGHOUSE_DB_HOME` alone
/// when it is set — a test profile must never fall through to the user's
/// books — else the tools' folder, then the app's support folder.
List<String> bughouseBookPlaces(
  String fileName, {
  required Map<String, String> environment,
  required String support,
}) {
  final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '';
  final override = environment['BUGHOUSE_DB_HOME'];
  if (override != null && override.isNotEmpty) {
    final expanded = override == '~' || override.startsWith('~/')
        ? home + override.substring(1)
        : override;
    return [p.join(expanded, fileName)];
  }
  return [
    if (home.isNotEmpty)
      p.join(home, '.local', 'share', 'chess-prep', 'bughouse-db', fileName),
    p.join(support, fileName),
  ];
}

/// One continuation the archive recorded from a position.
typedef FicsMove = ({
  BoardNumber board,
  Side mover,
  String san,
  int games,
  int abWins,
  int cdWins,
  int draws,
  int unknown,
  int? averageElo,
});

/// What the archive knows about one table: the games through it, counted
/// before rare continuations were pruned, and the continuations kept, most
/// played first.
typedef FicsPosition = ({int games, List<FicsMove> moves});

/// The archive as a whole, from its own `meta`: how many games, which
/// years, how deep it is indexed and the fewest games a continuation needs
/// to be kept.
typedef FicsArchive = ({int games, String years, int maxPly, int minGames});

sealed class FicsLookup {
  const FicsLookup();
}

final class FicsFound extends FicsLookup {
  const FicsFound(this.archive, this.position);

  final FicsArchive archive;
  final FicsPosition position;
}

final class FicsAbsent extends FicsLookup {
  const FicsAbsent();
}

final class FicsUnreadable extends FicsLookup {
  const FicsUnreadable(this.detail);

  final String detail;
}

abstract interface class FicsBook {
  /// Whether there is an archive to show; the lab offers it only then.
  Future<bool> available();

  Future<FicsLookup> explore(TablePosition position);
}

final class SqliteFicsBook implements FicsBook {
  SqliteFicsBook(this.places);

  final List<String> places;
  final _file = _ReadOnlyFile();
  FicsArchive? _archive;

  @override
  Future<bool> available() async => _file.open(places) is _Opened;

  @override
  Future<FicsLookup> explore(TablePosition position) async {
    switch (_file.open(places)) {
      case null:
        return const FicsAbsent();
      case _Unopened(:final detail):
        return FicsUnreadable(detail);
      case _Opened(:final db):
        try {
          final archive = _archive ??= _readArchive(db);
          return FicsFound(archive, _readPosition(db, position.bookKey));
        } on Object catch (error) {
          log.w('read the FICS archive at ${_file.path}', error);
          _file.close();
          return FicsUnreadable('$error');
        }
    }
  }

  FicsArchive _readArchive(Database db) {
    final meta = {
      for (final row in db.select('SELECT key, value FROM meta'))
        row['key'] as String: '${row['value']}',
    };
    int number(String key) => int.tryParse(meta[key] ?? '') ?? 0;
    final years = [
      for (final year in (meta['years'] ?? '').split(','))
        ?int.tryParse(year.trim()),
    ]..sort();
    return (
      games: number('games'),
      years: years.isEmpty ? '' : '${years.first}–${years.last}',
      maxPly: number('max_ply'),
      minGames: number('min_games'),
    );
  }

  FicsPosition _readPosition(Database db, int key) {
    final node = db.select('SELECT games FROM node WHERE pos = ?', [key]);
    final rows = db.select(
      'SELECT move, games, team_a, team_b, draws, unknown, elo_sum, elo_n '
      'FROM edge WHERE pos = ? ORDER BY games DESC',
      [key],
    );
    final moves = [for (final row in rows) ?_ficsMove(row)];
    final games = node.isEmpty
        ? moves.fold(0, (sum, move) => sum + move.games)
        : node.first['games'] as int;
    return (games: games, moves: moves);
  }

  /// BPGN's tag: the board letter, upper case when White moved (`A:e4`,
  /// `b:N@f3`), then the SAN.
  FicsMove? _ficsMove(Row row) {
    final tag = row['move'] as String;
    if (tag.length < 3) return null;
    final letter = tag[0];
    final eloN = row['elo_n'] as int;
    return (
      board: letter.toUpperCase() == 'A' ? BoardNumber.one : BoardNumber.two,
      mover: letter == letter.toUpperCase() ? Side.white : Side.black,
      san: tag.substring(2),
      games: row['games'] as int,
      abWins: row['team_a'] as int,
      cdWins: row['team_b'] as int,
      draws: row['draws'] as int,
      unknown: row['unknown'] as int,
      averageElo: eloN == 0 ? null : (row['elo_sum'] as int) ~/ eloN,
    );
  }

  void close() => _file.close();
}

sealed class _Open {
  const _Open();
}

final class _Opened extends _Open {
  const _Opened(this.db);

  final Database db;
}

final class _Unopened extends _Open {
  const _Unopened(this.detail);

  final String detail;
}

/// A database file opened read-only the first time it is found, and kept.
/// A file that will not open is asked again next time: a book half-written
/// by a running build may be whole in a minute.
final class _ReadOnlyFile {
  Database? _db;
  String? path;

  /// The open file, why it would not open, or null when none is there.
  _Open? open(List<String> places) {
    final open = _db;
    if (open != null) return _Opened(open);
    final found = places.where((place) => File(place).existsSync()).firstOrNull;
    if (found == null) return null;
    try {
      final db = sqlite3.open(found, mode: OpenMode.readOnly);
      db.execute('PRAGMA busy_timeout = 2000');
      path = found;
      return _Opened(_db = db);
    } on SqliteException catch (error) {
      log.w('open the bughouse book at $found', error);
      return _Unopened(error.message);
    }
  }

  void close() {
    _db?.close();
    _db = null;
  }
}
