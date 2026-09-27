import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../diagnostics/log.dart';
import 'master_book.dart';
import 'twic_import.dart';

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
typedef CorpusSize = ({int games, int bytes});

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

/// A selected corpus is one physical source. Existing master databases stay
/// read-only; imports go exclusively to the separate v2 cache.
abstract interface class MasterCorpus {
  Future<CorpusResult<CorpusSize>> size(String path);
  Future<CorpusResult<CorpusPage>> search(String path, CorpusFilter filter);
  Future<CorpusResult<String>> game(String path, int id);
  Future<CorpusResult<(int, int)>> importPgn(String source, String cache);
}

final class SqliteMasterCorpus implements MasterCorpus {
  const SqliteMasterCorpus();

  @override
  Future<CorpusResult<CorpusSize>> size(String path) =>
      _read('measure master games', () {
        if (!File(path).existsSync()) return (games: 0, bytes: 0);
        final db = _open(path);
        try {
          final count = db.select('SELECT count(*) AS n FROM games').first;
          var bytes = 0;
          for (final suffix in ['', '-wal', '-shm']) {
            final file = File('$path$suffix');
            if (file.existsSync()) bytes += file.lengthSync();
          }
          return (games: count['n'] as int, bytes: bytes);
        } finally {
          db.close();
        }
      });

  @override
  Future<CorpusResult<CorpusPage>> search(String path, CorpusFilter filter) =>
      _read('browse master games', () => _search(path, filter));

  @override
  Future<CorpusResult<String>> game(String path, int id) => _read(
    'open master game',
    () async {
      final book = SqliteMasterBook(path);
      try {
        final text = await book.gamePgn('$id');
        if (text == null) throw StateError('That game is no longer available.');
        return text;
      } finally {
        book.close();
      }
    },
  );

  @override
  Future<CorpusResult<(int, int)>> importPgn(String source, String cache) =>
      _read('import master games PGN', () => importMasterPgn(cache, source));
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
      where.add('date >= ?');
      args.add(filter.since);
    }
    final order = filter.strongestFirst
        ? 'min(coalesce(white_elo, 0), coalesce(black_elo, 0)) DESC, date DESC, id DESC'
        : 'date DESC, id DESC';
    final rows = db.select(
      'SELECT id, white, black, event, date, eco, result, white_elo, black_elo '
      'FROM games ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
      'ORDER BY $order LIMIT 101 OFFSET ?',
      [...args, filter.offset.clamp(0, 100000000)],
    );
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
