/// Schema of `app_games.db` and the migration that brings an older file up
/// to date.
///
/// Every statement here is on-disk format: change it only with a new
/// [gameStoreSchemaVersion] and a migration step, never in place.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'package:chess_auto_prep/chess_core/pgn/game_identity.dart';

/// `PRAGMA user_version` a fully migrated database carries.
const int gameStoreSchemaVersion = 2;

/// Create the tables when missing and migrate an older schema, in one
/// transaction. A no-op when the file is already at [gameStoreSchemaVersion].
void migrateGameStoreSchema(Database db) {
  final v = db.select('PRAGMA user_version').first.columnAt(0) as int;
  if (v >= gameStoreSchemaVersion) return;
  db.execute('BEGIN IMMEDIATE');
  try {
    db.execute('''
    CREATE TABLE IF NOT EXISTS games(
      id INTEGER PRIMARY KEY,
      collection TEXT NOT NULL,
      game_key TEXT NOT NULL,
      white TEXT NOT NULL DEFAULT '',
      black TEXT NOT NULL DEFAULT '',
      result TEXT NOT NULL DEFAULT '*',
      date TEXT NOT NULL DEFAULT '',
      played_at INTEGER,
      speed TEXT NOT NULL DEFAULT 'unknown',
      white_elo INTEGER,
      black_elo INTEGER,
      eco TEXT NOT NULL DEFAULT '',
      headers_json TEXT NOT NULL,
      pgn TEXT NOT NULL,
      imported_at INTEGER NOT NULL,
      UNIQUE(collection, game_key)
    );
    CREATE INDEX IF NOT EXISTS games_coll_date
      ON games(collection, played_at DESC);
    CREATE INDEX IF NOT EXISTS games_white ON games(white COLLATE NOCASE);
    CREATE INDEX IF NOT EXISTS games_black ON games(black COLLATE NOCASE);

    CREATE TABLE IF NOT EXISTS positions(
      pos INTEGER NOT NULL,
      game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
      ply INTEGER NOT NULL,
      PRIMARY KEY(pos, game_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS positions_game ON positions(game_id);

    CREATE TABLE IF NOT EXISTS collections(
      collection TEXT PRIMARY KEY,
      updated_at INTEGER NOT NULL,
      meta_json TEXT NOT NULL DEFAULT '{}'
    );
  ''');
    db.execute(
      'CREATE TABLE IF NOT EXISTS game_trash (collection TEXT NOT NULL, game_key TEXT NOT NULL, pgn TEXT NOT NULL, deleted_at INTEGER NOT NULL)',
    );
    // Rekey under one transaction without deleting any row or its positions.
    // A temporary namespace avoids unique-key swaps during migration.
    final rows = db.select(
      'SELECT id, collection, headers_json, pgn FROM games',
    );
    for (final row in rows) {
      db.execute('UPDATE games SET game_key = ? WHERE id = ?', [
        'migration-v2:${row['id']}',
        row['id'],
      ]);
    }
    final used = <String>{};
    for (final row in rows) {
      final h = (jsonDecode(row['headers_json'] as String) as Map)
          .cast<String, String>();
      var key = canonicalGameKey(h, row['pgn'] as String);
      if (!used.add('${row['collection']}|$key')) {
        key = '$key:preserved-${row['id']}';
      }
      db.execute('UPDATE games SET game_key = ? WHERE id = ?', [
        key,
        row['id'],
      ]);
    }
    db.execute('PRAGMA user_version = $gameStoreSchemaVersion');
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}
