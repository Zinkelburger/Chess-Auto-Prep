/// State behind the master-games browser.
///
/// Two views of the same corpus, because there are two reasons to open it:
/// looking something up (a player, an opening, an event) and being told what
/// is worth looking at (games that walked into your own books).  The first is
/// a database query; the second is a walk over the first one's results, so the
/// filter bar governs both and the scan never reads more than what is on
/// screen's worth of query.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../services/master_games/master_games_db.dart';
import '../../../services/master_games/master_games_query.dart';
import '../../../services/master_games/master_games_service.dart';
import '../../../services/storage/app_paths.dart';
import '../../../utils/safe_change_notifier.dart';
import '../services/twic_repertoire_scan.dart';

/// Which question the browser is answering.
enum MasterBrowseMode {
  /// Everything matching the filters.
  all,

  /// Only the games that reached one of your books.
  myRepertoire,
}

class MasterGamesBrowserController extends ChangeNotifier
    with SafeChangeNotifier {
  MasterGamesBrowserController({
    MasterGamesService? service,
    TwicRepertoireScanner? scanner,
  }) : _service = service ?? MasterGamesService.instance,
       _scanner = scanner ?? TwicRepertoireScanner();

  /// How many games one page of the list holds.
  static const int pageSize = 200;

  /// The most games one repertoire scan will walk.
  ///
  /// A scan is a trie walk per game and costs well under a millisecond, but
  /// the corpus is two million games; this keeps "scan" a few seconds rather
  /// than a few minutes, and the filter bar is how you aim it at the part you
  /// care about.
  static const int scanLimit = 20000;

  final MasterGamesService _service;
  final TwicRepertoireScanner _scanner;

  MasterGamesQuery _query = const MasterGamesQuery(limit: pageSize);
  List<MasterGame> _results = const [];
  int _total = 0;
  bool _loading = false;
  String? _error;

  MasterBrowseMode _mode = MasterBrowseMode.all;
  TwicScanResult? _scan;
  bool _scanning = false;
  bool _cancelScan = false;
  int _scanDone = 0;
  int _scanTotal = 0;

  MasterGame? _selected;

  MasterGamesQuery get query => _query;
  List<MasterGame> get results => _results;
  int get totalCount => _total;
  bool get isLoading => _loading;
  String? get error => _error;

  MasterBrowseMode get mode => _mode;
  TwicScanResult? get scanResult => _scan;
  bool get isScanning => _scanning;
  int get scanDone => _scanDone;
  int get scanTotal => _scanTotal;

  MasterGame? get selected => _selected;

  MasterGamesStats? get stats => _service.stats;
  bool get hasDatabase => (_service.stats?.games ?? 0) > 0;

  /// The games the list is showing, which is what every action operates on.
  List<MasterGame> get visibleGames => _mode == MasterBrowseMode.myRepertoire
      ? [for (final m in _scan?.matches ?? const <TwicMatch>[]) m.game]
      : _results;

  /// The scan verdict for [game], when there is one.
  TwicMatch? matchFor(MasterGame game) {
    for (final m in _scan?.matches ?? const <TwicMatch>[]) {
      if (m.game.id == game.id) return m;
    }
    return null;
  }

  bool get canLoadMore =>
      _mode == MasterBrowseMode.all && _results.length < _total;

  void select(MasterGame? game) {
    _selected = game;
    notifyListeners();
  }

  /// Replace the filters and re-run.  The scan is dropped rather than kept:
  /// it described a different set of games.
  Future<void> setQuery(MasterGamesQuery next) async {
    _query = next.copyWith(offset: 0, limit: pageSize);
    _scan = null;
    if (_mode == MasterBrowseMode.myRepertoire) _mode = MasterBrowseMode.all;
    await search();
  }

  Future<void> setMode(MasterBrowseMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    _selected = null;
    notifyListeners();
    if (mode == MasterBrowseMode.myRepertoire && _scan == null) {
      await runScan();
    }
  }

  /// Run the current filters.
  Future<void> search() async {
    final db = _service.db;
    if (db == null) {
      _error = 'The master games database is not open.';
      notifyListeners();
      return;
    }
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _total = db.countGames(_query);
      _results = db.searchGames(_query);
      _selected = null;
    } catch (e) {
      _error = 'Search failed: $e';
      _results = const [];
      _total = 0;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Append the next page.
  Future<void> loadMore() async {
    if (_loading || !canLoadMore) return;
    final db = _service.db;
    if (db == null) return;
    _loading = true;
    notifyListeners();
    try {
      final next = _query.copyWith(offset: _results.length);
      _results = [..._results, ...db.searchGames(next)];
    } catch (e) {
      _error = 'Could not load more: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Walk the current filter's games against the designated books.
  Future<void> runScan() async {
    final db = _service.db;
    if (db == null || _scanning) return;
    _scanning = true;
    _cancelScan = false;
    _scanDone = 0;
    _scanTotal = 0;
    _error = null;
    notifyListeners();
    try {
      final games = db.searchGames(
        _query.copyWith(limit: scanLimit, offset: 0),
      );
      _scanTotal = games.length;
      _scan = await _scanner.scan(
        games: games,
        onProgress: (done, total) {
          _scanDone = done;
          _scanTotal = total;
          notifyListeners();
        },
        isCancelled: () => _cancelScan,
      );
      _selected = null;
    } catch (e) {
      _error = 'Scan failed: $e';
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  void cancelScan() {
    if (_scanning) _cancelScan = true;
  }

  /// Write the visible games to a PGN file and return its path.
  ///
  /// This is the "give me the games" answer: one ordinary PGN under the app's
  /// collections folder, which the viewer opens and any other program can too.
  /// [label] becomes part of the file name.
  Future<String> writeCollection({required String label}) async {
    final games = visibleGames;
    final dir = await AppPaths.pgnCollectionsDirectory(create: true);
    final safe = label
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '-');
    final name = safe.isEmpty ? 'twic-games' : safe.toLowerCase();
    final file = File(p.join(dir.path, '$name.pgn'));
    final buffer = StringBuffer();
    for (final game in games) {
      buffer.write(game.toPgn());
    }
    await file.writeAsString(buffer.toString());
    return file.path;
  }

  /// Index of [game] among [visibleGames], for positioning the viewer.
  int indexOf(MasterGame game) {
    final games = visibleGames;
    for (var i = 0; i < games.length; i++) {
      if (games[i].id == game.id) return i;
    }
    return 0;
  }

  /// The newest issues, for the "recent issues" shortcut.
  List<TwicIssueSummary> recentIssues() =>
      _service.db?.recentIssues() ?? const [];
}
