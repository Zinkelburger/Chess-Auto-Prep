import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../storage/chapter_files.dart';
import '../../chess/explorer_answer.dart';
import '../../chess/explorer_choice.dart';
import '../../workspace/game_fetcher.dart';
import '../../storage/master_corpus.dart';
import '../../storage/pending_writes.dart';
import '../../storage/pgn_document_store.dart';
import '../../storage/pgn_file_picker.dart';
import 'twic_download.dart';

enum DatabaseActivity { idle, reading, importing }

/// Selection and work for the database screen. Search requests coalesce while
/// a query runs: typing never launches an unbounded queue of SQLite workers.
final class DatabaseLibrary extends ChangeNotifier {
  DatabaseLibrary({
    required this.sources,
    required this.corpus,
    required this.picker,
    required this.documents,
    required this.collections,
    required this.pending,
    this.download,
  }) : source = sources.keys.firstOrNull;

  final Map<String, String> sources;
  final MasterCorpus corpus;
  final PgnFilePicker picker;
  final PgnDocumentStore documents;
  final String collections;
  final PendingWrites pending;
  final TwicDownload? download;
  String? source;
  CorpusFilter filter = const CorpusFilter();
  CorpusPage page = (games: const [], more: false);
  CorpusSize size = (games: 0, bytes: 0);
  DatabaseActivity activity = DatabaseActivity.idle;
  String? problem;
  String? message;
  int? opening;
  int _revision = 0;
  int get revision => _revision;
  bool _reading = false;
  bool _disposed = false;

  void select(String value) {
    if (!sources.containsKey(value) || source == value) return;
    source = value;
    filter = const CorpusFilter();
    page = (games: const [], more: false);
    size = (games: 0, bytes: 0);
    unawaited(refresh());
  }

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
    while (!_disposed) {
      final revision = _revision;
      final path = sources[source];
      if (path == null) return;
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

  Future<void> importFile() async {
    final cache = download?.path;
    if (cache == null || activity != DatabaseActivity.idle || _disposed) return;
    activity = DatabaseActivity.importing;
    problem = null;
    message = null;
    _notify();
    final path = await picker.pickPgn();
    if (_disposed) return;
    if (path != null) {
      final work = corpus.importPgn(path, cache);
      pending.watch(this, work);
      final result = await work;
      if (_disposed) return;
      switch (result) {
        case CorpusRead(value: final counts):
          message = counts.$1 == 0
              ? 'This file was already imported.'
              : 'Imported ${counts.$1} games · ${counts.$2} skipped.';
          source =
              sources.entries.where((e) => e.value == cache).firstOrNull?.key ??
              source;
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
    final path = sources[source];
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
