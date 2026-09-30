import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../diagnostics/log.dart';

/// What the chapter audit keeps between runs, in two files of the support
/// folder, because one of them may be thrown away and the other may not.
///
/// `audit.db` holds the engine's best moves at each position the audit
/// asked about, so a second audit of a chapter — or of another that shares
/// its positions — asks the engine only about what is new. It is derived:
/// deleting it costs engine time, nothing else.
///
/// `audit_dismissed.db` holds the findings the user put aside. That is the
/// user's decision, so it lives apart from the cache. A finding is kept by
/// its own key — which kind, the position, the move — and not by the
/// chapter it was found in: the judgement is about that move in that
/// position, so it holds in whichever chapter plays it, and survives the
/// chapter being renamed, moved or merged into a course file.
///
/// A file that will not open is logged once and that half keeps nothing:
/// the audit still runs, asking the engine every time, or nothing stays
/// dismissed past the window.
final class AuditStore {
  AuditStore._(this._lines, this._dismissed);

  /// Opens or creates both files under [support], carrying over what an
  /// older `audit.db` still holds of the user's dismissals. Never throws.
  factory AuditStore.open(Directory support) {
    final lines = _openFile(support, 'audit.db', _createLines);
    final dismissed = _openFile(
      support,
      'audit_dismissed.db',
      _createDismissed,
    );
    if (lines != null && dismissed != null) _carryOver(lines, dismissed);
    return AuditStore._(lines, dismissed);
  }

  /// The first audit kept dismissals in `audit.db`, per chapter, under the
  /// same finding keys: each is carried into `audit_dismissed.db`, where a
  /// finding put aside in one chapter is put aside in all, and the old
  /// table then dropped. Nothing is dropped unless every row landed; a
  /// failure is logged and tried again the next time.
  static void _carryOver(Database lines, Database dismissed) {
    try {
      final old = lines.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'dismissed'",
      );
      if (old.isEmpty) return;
      final findings = [
        for (final row in lines.select(
          'SELECT DISTINCT finding FROM dismissed',
        ))
          if (row.columnAt(0) case final String finding) finding,
      ];
      dismissed.execute('BEGIN');
      try {
        for (final finding in findings) {
          dismissed.execute(
            'INSERT OR IGNORE INTO dismissed(finding) VALUES(?)',
            [finding],
          );
        }
        dismissed.execute('COMMIT');
      } on Object {
        dismissed.execute('ROLLBACK');
        rethrow;
      }
      lines.execute('DROP TABLE dismissed');
    } on Object catch (error) {
      log.w('carry over the dismissed findings', error);
    }
  }

  /// A store that keeps nothing past this process: what a test wants.
  factory AuditStore.inMemory() => AuditStore._(
    sqlite3.openInMemory()..execute(_createLines),
    sqlite3.openInMemory()..execute(_createDismissed),
  );

  static Database? _openFile(Directory support, String name, String create) {
    final path = p.join(support.path, name);
    Database? opened;
    try {
      support.createSync(recursive: true);
      final db = opened = sqlite3.open(path);
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA synchronous = NORMAL');
      db.execute(create);
      return db;
    } on Object catch (error) {
      opened?.close();
      log.w('open $path', error);
      return null;
    }
  }

  static const _createLines = '''
    CREATE TABLE IF NOT EXISTS lines(
      fen TEXT PRIMARY KEY,
      depth INTEGER NOT NULL,
      count INTEGER NOT NULL,
      moves TEXT NOT NULL
    )
  ''';

  static const _createDismissed = '''
    CREATE TABLE IF NOT EXISTS dismissed(finding TEXT PRIMARY KEY)
  ''';

  final Database? _lines;
  final Database? _dismissed;

  /// Whether the engine lines can be kept.
  bool get available => _lines != null;

  /// The engine's best moves kept for [fen4], the four-field FEN, when they
  /// were worked out at least [depth] deep and as at least [count] lines;
  /// null otherwise. Scores are from the side to move.
  List<({String uci, int cp})>? lines(
    String fen4, {
    required int depth,
    required int count,
  }) {
    final db = _lines;
    if (db == null) return null;
    try {
      final rows = db.select(
        'SELECT moves FROM lines WHERE fen = ? AND depth >= ? AND count >= ?',
        [fen4, depth, count],
      );
      if (rows.isEmpty) return null;
      return _decode(rows.first.columnAt(0) as String);
    } on Object catch (error) {
      log.w('read the audit lines', error);
      return null;
    }
  }

  /// Keeps [moves] for [fen4]. A write that fails is a log line: the next
  /// audit asks the engine again.
  void keepLines(
    String fen4,
    List<({String uci, int cp})> moves, {
    required int depth,
    required int count,
  }) {
    final db = _lines;
    if (db == null) return;
    try {
      db.execute(
        'INSERT OR REPLACE INTO lines(fen, depth, count, moves) '
        'VALUES(?, ?, ?, ?)',
        [fen4, depth, count, _encode(moves)],
      );
    } on Object catch (error) {
      log.w('write the audit lines', error);
    }
  }

  /// Every finding put aside, by key.
  Set<String> dismissed() {
    final db = _dismissed;
    if (db == null) return {};
    try {
      return {
        for (final row in db.select('SELECT finding FROM dismissed'))
          row.columnAt(0) as String,
      };
    } on Object catch (error) {
      log.w('read the dismissed findings', error);
      return {};
    }
  }

  /// Puts [finding] aside. False when it could not be kept: the file did
  /// not open or the write failed (logged).
  bool dismiss(String finding) => _write(
    'dismiss a finding',
    'INSERT OR IGNORE INTO dismissed(finding) VALUES(?)',
    [finding],
  );

  /// Brings [findings] back. False when one of them could not be.
  bool restore(Iterable<String> findings) {
    var kept = true;
    for (final finding in findings) {
      kept &= _write(
        'restore a dismissed finding',
        'DELETE FROM dismissed WHERE finding = ?',
        [finding],
      );
    }
    return kept;
  }

  bool _write(String action, String sql, List<Object?> values) {
    final db = _dismissed;
    if (db == null) return false;
    try {
      db.execute(sql, values);
      return true;
    } on Object catch (error) {
      log.w(action, error);
      return false;
    }
  }

  /// `e2e4:31 d2d4:25`: each move and its score.
  static String _encode(List<({String uci, int cp})> moves) =>
      moves.map((move) => '${move.uci}:${move.cp}').join(' ');

  static List<({String uci, int cp})>? _decode(String text) {
    final moves = <({String uci, int cp})>[];
    for (final word in text.split(' ')) {
      final parts = word.split(':');
      final cp = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (cp == null) return null;
      moves.add((uci: parts[0], cp: cp));
    }
    return moves;
  }

  void close() {
    _lines?.close();
    _dismissed?.close();
  }
}

/// The store under [support], opened the first time it is asked for, so a
/// window where nobody audits never creates the file.
final class AuditStoreOnDemand {
  AuditStoreOnDemand(this.support);

  final Directory support;
  AuditStore? _opened;

  AuditStore get store => _opened ??= AuditStore.open(support);

  void close() {
    _opened?.close();
    _opened = null;
  }
}
