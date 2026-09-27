import 'dart:async';
import 'dart:isolate';

import '../../chess/game_filter.dart';
import '../../chess/pgn/chapter_line.dart';
import '../../chess/pgn/game_order.dart';
import '../../chess/pgn/reading_place.dart';
import '../../diagnostics/log.dart';
import '../../storage/pending_writes.dart';
import '../../storage/viewer_places.dart';
import '../../workspace/document_session.dart';
import '../../workspace/file_filter.dart';

/// Reading metadata follows the immutable document. Latest snapshots coalesce
/// per path; disposal stops capture, never the saves already accepted.
final class ViewerReading {
  ViewerReading({
    required this.session,
    required this.filter,
    required this.pending,
    required this.store,
    required this.activePath,
    required this.sort,
    required this.setSort,
    required this.changed,
  });
  final DocumentSession session;
  final FileFilter filter;
  final PendingWrites pending;
  final ViewerPlaces? store;
  final String? Function() activePath;
  final GameOrder Function() sort;
  final void Function(GameOrder) setSort;
  final void Function() changed;
  final _queued = <String, ReadingPlace>{};
  Future<void>? _writing;
  bool _disposed = false, _restoring = false;
  ChapterLine? _keyOf;
  String? _key;
  String? problem;
  GameFilter? _restoredFilter;

  void start() {
    session.anyChange.addListener(capture);
    filter.addListener(_filterChanged);
  }

  Future<ReadingPlace?> load(String path) async {
    await _writing;
    if (_queued[path] case final accepted?) return accepted;
    try {
      return await store?.load(path);
    } on Object catch (error) {
      _failed(error);
      return null;
    }
  }

  Future<void> restore(ReadingPlace? place, bool Function() current) async {
    if (place == null) {
      filter.apply(GameFilter.none);
      capture();
      return;
    }
    final chapter = session.chapter;
    final cursor = session.cursor;
    final filtering = filter.filter;
    final sorting = sort();
    if (chapter == null) return;
    _restoring = true;
    try {
      final lines = chapter.lines;
      final game = lines.length < 500
          ? place.locate(lines)
          : await Isolate.run(() => place.locate(lines));
      if (_disposed ||
          !current() ||
          !identical(session.chapter, chapter) ||
          session.cursor != cursor ||
          filter.filter != filtering ||
          sort() != sorting)
        return;
      setSort(place.sort);
      _restoredFilter = place.filter.isEmpty ? null : place.filter;
      filter.apply(place.filter);
      if (game >= 0) {
        session.showGame(game);
        final tree = session.tree;
        if (tree != null &&
            (place.fen == null || tree.fenAt(place.path).value == place.fen))
          session.goTo(place.path);
      }
    } finally {
      _restoring = false;
      capture();
    }
    _filterChanged();
    capture();
  }

  void _filterChanged() {
    if (_restoring || filter.busy) return;
    if (_restoredFilter == filter.applied) {
      _restoredFilter = null;
      if (filter.problem == null && filter.kept == 0)
        filter.apply(GameFilter.none);
    }
    capture();
  }

  void capture() {
    final path = activePath();
    final game = session.game;
    final lines = session.chapter?.lines;
    if (_disposed ||
        _restoring ||
        store == null ||
        path == null ||
        game == null ||
        lines == null ||
        game >= lines.length ||
        session.hasHeldEdits ||
        filter.busy)
      return;
    final line = lines[game];
    if (!identical(_keyOf, line)) {
      _keyOf = line;
      _key = readingGameKey(line);
    }
    final place = ReadingPlace(
      game: game,
      key: _key!,
      path: session.cursor,
      fen: session.fen.value,
      sort: sort(),
      filter: filter.applied,
    );
    _queued[path] = place;
    unawaited(retry());
  }

  Future<void> retry() {
    if (_writing != null) return _writing!;
    if (_queued.isEmpty) return Future.value();
    final work = _writing = _drain().whenComplete(() => _writing = null);
    return pending.track(
      this,
      work,
      label: 'Reading position',
      obligation: this,
      problem: (_) => problem,
    );
  }

  Future<void> _drain() async {
    while (_queued.isNotEmpty) {
      final entry = _queued.entries.first;
      try {
        await store!.save(entry.key, entry.value);
      } on Object catch (error) {
        _failed(error);
        return;
      }
      if (identical(_queued[entry.key], entry.value)) _queued.remove(entry.key);
      if (problem != null) {
        problem = null;
        if (!_disposed) changed();
      }
    }
  }

  void _failed(Object error) {
    log.w('keep viewer reading position', error);
    problem = 'The reading position could not be kept. Move again to retry.';
    if (!_disposed) changed();
  }

  void dispose() {
    _disposed = true;
    session.anyChange.removeListener(capture);
    filter.removeListener(_filterChanged);
  }
}
