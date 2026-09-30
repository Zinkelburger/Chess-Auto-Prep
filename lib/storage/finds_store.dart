import 'dart:io';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../chess/fen.dart';
import '../chess/generation/finds.dart';
import '../diagnostics/log.dart';

/// A find as it is kept: what the search found, where it started, for whom
/// and when.
final class KeptFind {
  const KeptFind({
    required this.id,
    required this.find,
    required this.side,
    required this.rootFen,
    required this.elo,
    required this.foundAt,
  });

  final int id;

  /// The find, its line from [rootFen].
  final Find find;

  /// The side the search was for: every score in [find] is from its side.
  final Side side;

  /// Where [Find.sans] starts: the document's root, not the search's, so
  /// the line reads the way the user came to it.
  final Fen rootFen;

  /// The rating the opponent's replies were predicted for.
  final int elo;
  final DateTime foundAt;
}

/// What the searches found, kept between runs: `finds.db` in the support
/// folder, one table for every search from every position.
///
/// A position is one find of each kind for each side: found again, it is
/// replaced by the newer finding, so running a search twice does not list
/// its finds twice.
///
/// A file that will not open is logged once and the store keeps nothing:
/// the search still runs and shows its tree.
final class FindsStore {
  FindsStore._(this._db);

  /// Opens or creates the store under [support]. Never throws.
  factory FindsStore.open(Directory support) {
    final path = p.join(support.path, 'finds.db');
    Database? opened;
    try {
      support.createSync(recursive: true);
      final db = opened = sqlite3.open(path);
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA synchronous = FULL');
      db.execute(_create);
      return FindsStore._(db);
    } on Object catch (error) {
      opened?.close();
      log.w('open $path', error);
      return FindsStore._(null);
    }
  }

  /// A store that keeps nothing past this process: what a test wants.
  factory FindsStore.inMemory() {
    final db = sqlite3.openInMemory();
    db.execute(_create);
    return FindsStore._(db);
  }

  static const _create = '''
    CREATE TABLE IF NOT EXISTS finds(
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      side TEXT NOT NULL,
      fen TEXT NOT NULL,
      root_fen TEXT NOT NULL,
      line TEXT NOT NULL,
      ply INTEGER NOT NULL,
      key_ply INTEGER NOT NULL,
      eval_cp INTEGER NOT NULL,
      loss_cp INTEGER NOT NULL,
      share REAL NOT NULL,
      reach REAL NOT NULL,
      worth REAL NOT NULL,
      elo INTEGER NOT NULL,
      found_at INTEGER NOT NULL,
      UNIQUE(kind, side, fen)
    )
  ''';

  static const _upsert = '''
    INSERT INTO finds(kind, side, fen, root_fen, line, ply, key_ply, eval_cp,
                      loss_cp, share, reach, worth, elo, found_at)
    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(kind, side, fen) DO UPDATE SET
      root_fen = excluded.root_fen,
      line     = excluded.line,
      ply      = excluded.ply,
      key_ply  = excluded.key_ply,
      eval_cp  = excluded.eval_cp,
      loss_cp  = excluded.loss_cp,
      share    = excluded.share,
      reach    = excluded.reach,
      worth    = excluded.worth,
      elo      = excluded.elo,
      found_at = excluded.found_at
  ''';

  final Database? _db;

  /// Whether the file opened.
  bool get available => _db != null;

  /// Every find kept, in no order; the list sorts. Empty when the file
  /// could not be read.
  List<KeptFind> all() {
    final db = _db;
    if (db == null) return const [];
    try {
      return [
        for (final row in db.select('SELECT * FROM finds'))
          if (_read(row) case final kept?) kept,
      ];
    } on Object catch (error) {
      log.w('read the finds', error);
      return const [];
    }
  }

  /// Keeps [finds], each one's line starting at [rootFen], found for
  /// [side] against [elo] at [at]. One transaction: a search's finds are
  /// kept whole or not at all. Answers whether they were.
  bool keep(
    List<Find> finds, {
    required Side side,
    required Fen rootFen,
    required int elo,
    required DateTime at,
  }) {
    if (finds.isEmpty) return true;
    final db = _db;
    if (db == null) return false;
    try {
      db.execute('BEGIN');
      final insert = db.prepare(_upsert);
      try {
        for (final f in finds) {
          insert.execute([
            f.kind.name,
            _sideName(side),
            f.fen.position,
            rootFen.value,
            f.sans.join(' '),
            f.ply,
            f.keyPly,
            f.evalCp,
            f.lossCp,
            f.share,
            f.reach,
            f.worth,
            elo,
            at.millisecondsSinceEpoch,
          ]);
        }
      } finally {
        insert.close();
      }
      db.execute('COMMIT');
      return true;
    } on Object catch (error) {
      log.w('keep ${finds.length} finds', error);
      try {
        db.execute('ROLLBACK');
      } on Object catch (_) {}
      return false;
    }
  }

  /// Forgets the find [id].
  void remove(int id) {
    try {
      _db?.execute('DELETE FROM finds WHERE id = ?', [id]);
    } on Object catch (error) {
      log.w('remove find $id', error);
    }
  }

  void close() => _db?.close();

  static String _sideName(Side side) => side == Side.white ? 'w' : 'b';

  /// A row as a find; null for one this version cannot read, a kind a
  /// later version added.
  static KeptFind? _read(Row row) {
    final kind = FindKind.values
        .where((k) => k.name == row['kind'])
        .firstOrNull;
    if (kind == null) return null;
    final rootFen = Fen(row['root_fen'] as String);
    final line = row['line'] as String;
    // The position is stored as its four fields, which is what the store
    // is keyed on; the board wants six.
    final fen = Fen('${row['fen'] as String} 0 1');
    return KeptFind(
      id: row['id'] as int,
      find: Find(
        kind: kind,
        sans: line.isEmpty ? const [] : line.split(' '),
        ply: row['ply'] as int,
        keyPly: row['key_ply'] as int,
        fen: fen,
        evalCp: row['eval_cp'] as int,
        lossCp: row['loss_cp'] as int,
        share: (row['share'] as num).toDouble(),
        reach: (row['reach'] as num).toDouble(),
        worth: (row['worth'] as num).toDouble(),
      ),
      side: row['side'] == 'w' ? Side.white : Side.black,
      rootFen: rootFen,
      elo: row['elo'] as int,
      foundAt: DateTime.fromMillisecondsSinceEpoch(row['found_at'] as int),
    );
  }
}

/// The store under [support], opened the first time [store] is asked for,
/// so a run that never searches or lists finds never creates the file.
final class FindsStoreOnDemand {
  FindsStoreOnDemand(this.support);

  final Directory support;
  FindsStore? _opened;

  FindsStore get store {
    if (_opened?.available ?? false) return _opened!;
    _opened?.close();
    return _opened = FindsStore.open(support);
  }

  void close() {
    _opened?.close();
    _opened = null;
  }
}
