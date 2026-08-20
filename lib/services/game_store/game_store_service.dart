/// App-scoped owner of the games database ([GameStore]): one lazily opened
/// connection for the UI isolate, isolate-backed bulk imports, and the
/// one-time migration of the flat files the store replaces.
///
/// Not a notifier: consumers that want change signals already have their
/// own (the tactics coordinator, the recent-games controller); this is
/// plumbing they call into.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../storage/app_paths.dart';
import '../storage/sqlite_recovery.dart';
import '../../utils/file_text_reader.dart';
import 'game_store.dart';

class GameStoreService {
  GameStoreService({Future<String> Function()? dbPathProvider})
    : _dbPathProvider = dbPathProvider ?? GameStore.defaultPath;

  static GameStoreService instance = GameStoreService();

  /// Replace the singleton for tests (with a temp-dir path provider).
  @visibleForTesting
  static void setTestInstance(GameStoreService service) {
    instance = service;
  }

  final Future<String> Function() _dbPathProvider;
  GameStore? _store;
  String? _path;
  Future<GameStore>? _opening;

  /// The open store, opening (and migrating legacy files) on first use.
  ///
  /// If the file vanished underneath an open connection (a test tore its
  /// temp dir down, the user cleared the support dir) the connection is
  /// dropped and the store re-created, so work never lands in a deleted
  /// inode.
  Future<GameStore> open() {
    final store = _store;
    if (store != null && !File(store.path).existsSync()) {
      close();
      _path = null;
    }
    final pending = _opening;
    if (pending != null) return pending;
    final opening = _opening = _open();
    // Opening failed?  Drop the cached future, so the next caller retries.
    // Keeping a rejected future here would make a transient problem (the
    // support directory not writable yet, a lock that has since cleared)
    // permanent for the whole session: every later `open()` would await the
    // same failure and nothing could reach the database again.  Cleared
    // through a side future rather than inside [_open] because [_open] can
    // fail before it ever suspends, which would run its handler *before*
    // this assignment and leave the rejected future cached anyway.
    unawaited(
      opening.then(
        (_) {},
        onError: (Object _) {
          if (identical(_opening, opening)) _opening = null;
        },
      ),
    );
    return opening;
  }

  Future<GameStore> _open() async {
    final path = _path ??= await _dbPathProvider();
    final store = openSqlite(
      path,
      () => GameStore.open(path),
      label: 'Games database',
    );
    _store = store;
    try {
      await _migrateLegacyTacticsArchive(store);
    } catch (_) {
      store.close();
      _store = null;
      rethrow;
    }
    return store;
  }

  /// The store if already open (synchronous callers on hot paths).
  GameStore? get storeIfOpen => _store;

  /// Bulk import off the UI isolate.  [replace] clears the collection
  /// first; [keepExisting] makes it append-only.
  Future<GameStoreImportResult> importPgnInBackground({
    required String collection,
    required String pgnText,
    bool replace = false,
    bool keepExisting = false,
  }) async {
    await open();
    final request = GameStoreImportRequest(
      dbPath: _path!,
      collection: collection,
      pgnText: pgnText,
      replace: replace,
      keepExisting: keepExisting,
    );
    return Isolate.run(() => importPgnIntoGameStore(request));
  }

  // ── Legacy migration ──────────────────────────────────────────────────

  /// Name of the flat tactics archive the store replaces (documents root).
  static const String legacyTacticsArchiveName = 'imported_games.pgn';

  /// Import `imported_games.pgn` into the `tactics` collection once, then
  /// rename it aside (`.migrated`) so the games survive in two places until
  /// the user deletes the backup — never delete a user's only copy.
  Future<void> _migrateLegacyTacticsArchive(GameStore store) async {
    try {
      final docs = await AppPaths.documentsDirectory();
      final file = File(
        '${docs.path}${Platform.pathSeparator}$legacyTacticsArchiveName',
      );
      if (!await file.exists()) return;
      if (store.count(GameCollections.tactics) > 0) {
        // Already migrated but the file came back (restored backup?): leave
        // it; the store is the source of truth now.
        return;
      }
      final text = await readTextFile(file);
      if (text.trim().isNotEmpty) {
        // Only plain values cross into the isolate (the store's native
        // handle cannot); the isolate opens its own connection.
        final request = GameStoreImportRequest(
          dbPath: store.path,
          collection: GameCollections.tactics,
          pgnText: text,
        );
        final result = await Isolate.run(() => importPgnIntoGameStore(request));
        debugPrint(
          'GameStore: migrated ${result.total} games from '
          '$legacyTacticsArchiveName',
        );
      }
      await file.rename('${file.path}.migrated');
    } catch (e) {
      debugPrint('GameStore: legacy archive migration failed: $e');
    }
  }

  /// Close the connection (tests).
  void close() {
    _store?.close();
    _store = null;
    _opening = null;
  }
}
