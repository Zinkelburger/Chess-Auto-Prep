import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../storage/chapter_files.dart';
import '../../chess/explorer_answer.dart';
import '../../chess/explorer_choice.dart';
import '../../workspace/game_fetcher.dart';
import '../../storage/disk_usage.dart';
import '../../storage/master_corpus.dart';
import '../../storage/pending_writes.dart';
import '../../storage/pgn_document_store.dart';
import '../../storage/pgn_file_picker.dart';
import 'twic_download.dart';

enum DatabaseActivity { idle, reading, importing }

/// What the database is, said on the page under its heading.
const databaseAbout =
    'Games from The Week in Chess (theweekinchess.com), a free weekly '
    'bulletin of recent tournament games, and the PGN files you import. The '
    'explorer’s TWIC source reads them.';

/// Browsing and adding to the master games database at [path]. Search
/// requests coalesce while a query runs: typing never launches an unbounded
/// queue of SQLite workers.
final class DatabaseLibrary extends ChangeNotifier {
  DatabaseLibrary({
    required this.path,
    required this.corpus,
    required this.picker,
    required this.documents,
    required this.collections,
    required this.pending,
    this.download,
    this.places,
  });

  /// `<support>/master_games.db`; null where there is none to keep.
  final String? path;

  /// Whether the page offers TWIC: a first download or bringing it up to
  /// date, both into [path].
  bool get offersDownload => download != null;
  final MasterCorpus corpus;
  final PgnFilePicker picker;
  final PgnDocumentStore documents;
  final String collections;
  final PendingWrites pending;
  final TwicDownload? download;

  /// What the Storage list measures; null hides it.
  final StoragePlaces? places;
  List<StoreUsage> storage = const [];
  bool measuring = false;

  /// The store being deleted, until its files are gone.
  String? removing;
  CorpusFilter filter = const CorpusFilter();
  CorpusPage page = (games: const [], more: false);
  CorpusSize size = emptyCorpus;
  DatabaseActivity activity = DatabaseActivity.idle;
  String? problem;
  String? message;
  int? opening;
  int _revision = 0;
  int get revision => _revision;
  bool _reading = false;
  bool _disposed = false;

  Future<void> search(CorpusFilter value) {
    filter = value;
    return refresh();
  }

  Future<void> refresh() async {
    _revision++;
    if (_reading || _disposed || activity == DatabaseActivity.importing) return;
    _reading = true;
    try {
      await _readLatest();
    } finally {
      _reading = false;
      if (activity == DatabaseActivity.reading)
        activity = DatabaseActivity.idle;
      _notify();
    }
  }

  Future<void> _readLatest() async {
    final path = this.path;
    if (path == null) return;
    while (!_disposed) {
      final revision = _revision;
      activity = DatabaseActivity.reading;
      problem = null;
      _notify();
      final count = await corpus.size(path);
      if (_disposed) return;
      if (revision != _revision) continue;
      final result = await corpus.search(path, filter);
      if (_disposed) return;
      if (revision != _revision) continue;
      switch (count) {
        case CorpusRead(:final value):
          size = value;
        case CorpusFailure(:final detail):
          problem = detail;
      }
      switch (result) {
        case CorpusRead(:final value):
          page = value;
        case CorpusFailure(:final detail):
          page = (games: const [], more: false);
          problem = detail;
      }
      return;
    }
  }

  /// Whether an import, a TWIC download or a deletion is writing the
  /// database. This owner runs one at a time: SQLite would make the second
  /// wait on the first's lock and then fail.
  bool get busy =>
      activity == DatabaseActivity.importing ||
      (download?.running ?? false) ||
      removing != null;

  /// Downloads [weeks] of TWIC into the database, unless an import or a
  /// deletion is writing it.
  Future<void> downloadTwic(int weeks) async {
    final download = this.download;
    if (download == null || download.running || _disposed) return;
    if (busy) {
      message = removing != null
          ? 'Wait for the deletion to finish.'
          : 'Wait for the import to finish.';
      _notify();
      return;
    }
    final work = download.start(weeks);
    _notify();
    await work;
    if (_disposed) return;
    _notify();
    await refresh();
  }

  Future<void> importFile() async {
    final database = path;
    if (database == null || activity != DatabaseActivity.idle || _disposed)
      return;
    if (busy) {
      message = removing != null
          ? 'Wait for the deletion to finish.'
          : 'Wait for the TWIC download to finish.';
      _notify();
      return;
    }
    activity = DatabaseActivity.importing;
    problem = null;
    message = null;
    _notify();
    final source = await picker.pickPgn();
    if (_disposed) return;
    if (source != null) {
      final work = corpus.importPgn(source, database);
      pending.watch(this, work);
      final result = await work;
      if (_disposed) return;
      switch (result) {
        case CorpusRead(value: final counts):
          message = counts.$1 == 0
              ? 'This file was already imported.'
              : 'Imported ${counts.$1} games · ${counts.$2} skipped.';
          filter = const CorpusFilter();
        case CorpusFailure(:final detail):
          problem = 'Import failed: $detail';
      }
    }
    activity = DatabaseActivity.idle;
    // A failed import stays visible until the user retries or refreshes.
    if (problem == null) await refresh();
    _notify();
  }

  Future<ChapterRef?> keep(CorpusGame game) async {
    final path = this.path;
    if (path == null || opening != null || _disposed) return null;
    opening = game.id;
    problem = null;
    _notify();
    final result = await corpus.game(path, game.id);
    if (_disposed) return null;
    ChapterRef? kept;
    switch (result) {
      case CorpusRead(:final value):
        final digest = sha256.convert(utf8.encode(value));
        final name = gameFileName(
          ExplorerGame(
            id: '$digest',
            white: game.white,
            black: game.black,
            result: game.result,
            event: game.event,
          ),
          ExplorerSource.twic,
          sourceName: 'database',
        );
        final ref = ChapterRef.at(
          p.join(collections, 'database games', '$name.pgn'),
        );
        switch (await documents.create(ref, value)) {
          case Created() || Collision():
            kept = ref;
          case IoFailure(:final detail):
            problem = 'Could not keep the game: $detail';
        }
      case CorpusFailure(:final detail):
        problem = detail;
    }
    if (_disposed) return null;
    opening = null;
    _notify();
    return kept;
  }

  /// Measures every kept store. Never throws; a second request while one
  /// runs is dropped, since the running one reads the disk afresh.
  Future<void> measure() async {
    final places = this.places;
    if (places == null || measuring || _disposed) return;
    measuring = true;
    _notify();
    try {
      storage = await measureStorage(
        places.stores,
        support: places.support,
        derived: places.derived,
      );
    } finally {
      measuring = false;
      _notify();
    }
  }

  /// Deletes a removable store's files and frees the space. Refused while a
  /// download or import could be writing it.
  Future<void> remove(StoreUsage store) async {
    if (!store.removable || busy || _disposed) return;
    removing = store.path;
    problem = null;
    message = null;
    _notify();
    switch (await deleteDerivedFile(store.path)) {
      case null:
        message = 'Deleted ${store.name} · freed ${formatBytes(store.bytes)}.';
      case final detail:
        problem = 'Could not delete ${store.name}: $detail';
    }
    removing = null;
    if (_disposed) return;
    await measure();
    await refresh();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    download?.dispose();
    super.dispose();
  }
}
