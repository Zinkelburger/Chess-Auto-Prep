import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import '../diagnostics/log.dart';
import 'master_book.dart';
import 'master_games_import.dart';

/// Filters use literal text, never SQL or a regular expression supplied by a
/// user. Pagination bounds the results even for a multi-million-game corpus.
final class CorpusFilter {
  const CorpusFilter({
    this.player = '',
    this.event = '',
    this.eco = '',
    this.minimumElo = 0,
    this.since = '',
    this.offset = 0,
    this.strongestFirst = false,
  });
  final String player;
  final String event;
  final String eco;
  final int minimumElo;
  final String since;
  final int offset;
  final bool strongestFirst;
}

typedef CorpusGame = ({
  int id,
  String white,
  String black,
  String event,
  String date,
  String eco,
  String result,
  int whiteElo,
  int blackElo,
});

typedef CorpusPage = ({List<CorpusGame> games, bool more});

/// How much a corpus holds and where it came from: the span of dates its
/// games were played on, the TWIC issues it was built from (0 when none)
/// and how many PGN files were imported into it.
typedef CorpusSize = ({
  int games,
  int bytes,
  String firstDate,
  String lastDate,
  int firstIssue,
  int lastIssue,
  int imports,
});

const CorpusSize emptyCorpus = (
  games: 0,
  bytes: 0,
  firstDate: '',
  lastDate: '',
  firstIssue: 0,
  lastIssue: 0,
  imports: 0,
);

sealed class CorpusResult<T> {
  const CorpusResult();
}

final class CorpusRead<T> extends CorpusResult<T> {
  const CorpusRead(this.value);
  final T value;
}

final class CorpusFailure<T> extends CorpusResult<T> {
  const CorpusFailure(this.detail);
  final String detail;
}

/// The master games database, browsed and added to. Reads open it read-only;
/// [importPgn] writes it through `master_games_import.dart`.
abstract interface class MasterCorpus {
  Future<CorpusResult<CorpusSize>> size(String path);
  Future<CorpusResult<CorpusPage>> search(String path, CorpusFilter filter);
  Future<CorpusResult<String>> game(String path, int id);
  Future<CorpusResult<(int, int)>> importPgn(String source, String path);
}

final class SqliteMasterCorpus implements MasterCorpus {
  const SqliteMasterCorpus();

  @override
  Future<CorpusResult<CorpusSize>> size(String path) =>
      _read('measure master games', () {
        if (!File(path).existsSync()) return emptyCorpus;
        final db = _open(path);
        try {
          final count = db.select('SELECT count(*) AS n FROM games').first;
          var bytes = 0;
          for (final suffix in ['', '-wal', '-shm']) {
            final file = File('$path$suffix');
            if (file.existsSync()) bytes += file.lengthSync();
          }
          // Dates like `????.??.??` sort after the digits; only real years
          // bound the span, read along the date index where there is one.
          String date(String order) =>
              db
                      .select(
                        "SELECT date FROM games WHERE date >= '1' "
                        "AND date < '3' ORDER BY date $order LIMIT 1",
                      )
                      .firstOrNull?['date']
                  as String? ??
              '';
          final tables = {
            for (final row in db.select(
              "SELECT name FROM sqlite_master WHERE type = 'table'",
            ))
              row['name'] as String,
          };
          final issues = tables.contains('twic_issues')
              ? db
                    .select(
                      'SELECT min(issue) AS lo, max(issue) AS hi '
                      'FROM twic_issues',
                    )
                    .first
              : null;
          final imports = tables.contains('imports')
              ? db.select('SELECT count(*) AS n FROM imports').first['n'] as int
              : 0;
          return (
            games: count['n'] as int,
            bytes: bytes,
            firstDate: date('ASC'),
            lastDate: date('DESC'),
            firstIssue: issues?['lo'] as int? ?? 0,
            lastIssue: issues?['hi'] as int? ?? 0,
            imports: imports,
          );
        } finally {
          db.close();
        }
      });

  @override
  Future<CorpusResult<CorpusPage>> search(String path, CorpusFilter filter) =>
      _read('browse master games', () => _search(path, filter));

  @override
  Future<CorpusResult<String>> game(String path, int id) =>
      _read('open master game', () async {
        final text = await SqliteMasterBook(path).gamePgn('$id');
        if (text == null) throw StateError('That game is no longer available.');
        return text;
      });

  @override
  Future<CorpusResult<(int, int)>> importPgn(String source, String path) =>
      _read('import master games PGN', () => importMasterPgn(path, source));
}

Future<CorpusResult<T>> _read<T>(
  String action,
  FutureOr<T> Function() work,
) async {
  try {
    return CorpusRead(await Isolate.run(work));
  } on Object catch (error) {
    log.w(action, error);
    return CorpusFailure('$error');
  }
}

/// A game with a real year, not `????.??.??`.
const _dated = "date >= '1' AND date < '3'";

Database _open(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  db.execute('PRAGMA busy_timeout = 2000');
  return db;
}

CorpusPage _search(String path, CorpusFilter filter) {
  if (!File(path).existsSync()) return (games: <CorpusGame>[], more: false);
  final db = _open(path);
  try {
    final where = <String>[];
    final args = <Object>[];
    void contains(String field, String text) {
      if (text.trim().isEmpty) return;
      where.add('instr(lower($field), lower(?)) > 0');
      args.add(text.trim());
    }

    contains("white || ' ' || black", filter.player);
    contains('event', filter.event);
    contains('eco', filter.eco);
    if (filter.minimumElo > 0) {
      where.add('min(coalesce(white_elo, 0), coalesce(black_elo, 0)) >= ?');
      args.add(filter.minimumElo);
    }
    if (filter.since.isNotEmpty) {
      where.add("date >= ? AND date < '3'");
      args.add(filter.since);
    }
    List<Row> select(String also, String order, int limit, int offset) =>
        db.select(
          'SELECT id, white, black, event, date, eco, result, white_elo, '
          'black_elo FROM games WHERE ${[...where, also].join(' AND ')} '
          'ORDER BY $order LIMIT ? OFFSET ?',
          [...args, limit, offset],
        );
    final offset = filter.offset.clamp(0, 100000000);
    final List<Row> rows;
    if (filter.strongestFirst) {
      rows = select(
        '1',
        'min(coalesce(white_elo, 0), coalesce(black_elo, 0)) DESC, '
            '($_dated) DESC, date DESC, id DESC',
        101,
        offset,
      );
    } else {
      // Dates like `????.??.??` sort after the digits, so the dated games
      // are paged first along the date index and the undated ones after.
      rows = [...select(_dated, 'date DESC, id DESC', 101, offset)];
      if (rows.length < 101) {
        final dated = rows.isNotEmpty
            ? offset + rows.length
            : db
                      .select(
                        'SELECT count(*) AS n FROM games '
                        'WHERE ${[...where, _dated].join(' AND ')}',
                        args,
                      )
                      .first['n']
                  as int;
        rows.addAll(
          select(
            // The complement of [_dated] spelled so the date index finds it.
            "(date < '1' OR date >= '3')",
            'id DESC',
            101 - rows.length,
            max(0, offset - dated),
          ),
        );
      }
    }
    return (games: rows.take(100).map(_game).toList(), more: rows.length > 100);
  } finally {
    db.close();
  }
}

CorpusGame _game(Row row) => (
  id: row['id'] as int,
  white: row['white'] as String? ?? '',
  black: row['black'] as String? ?? '',
  event: row['event'] as String? ?? '',
  date: row['date'] as String? ?? '',
  eco: row['eco'] as String? ?? '',
  result: row['result'] as String? ?? '*',
  whiteElo: row['white_elo'] as int? ?? 0,
  blackElo: row['black_elo'] as int? ?? 0,
);
