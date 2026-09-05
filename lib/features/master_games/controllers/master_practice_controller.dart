/// State behind the master-practice review dialog.
///
/// One review over the games it is given, a selection, and the hand-off of a
/// master game to the Games viewer. The walk itself lives in
/// [MasterPracticeReviewer]; this only owns when it runs and what is shown.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../services/master_games/master_games_db.dart';
import '../../../services/master_games/master_games_service.dart';
import '../../../services/storage/app_paths.dart';
import '../../../utils/atomic_file.dart';
import '../../../utils/safe_change_notifier.dart';
import '../../games/models/recent_game.dart';
import '../services/master_practice_review.dart';

class MasterPracticeController extends ChangeNotifier with SafeChangeNotifier {
  MasterPracticeController({
    MasterGamesService? service,
    MasterPracticeReviewer? reviewer,
  }) : _service = service ?? MasterGamesService.instance {
    _reviewer = reviewer;
  }

  /// The file the viewer opens a key game from. One file, rewritten per
  /// entry: the viewer reads it on open, and a folder of one PGN per click
  /// is not a collection anyone wants.
  static const String collectionName = 'master-practice.pgn';

  final MasterGamesService _service;
  MasterPracticeReviewer? _reviewer;

  MasterPracticeReview? _review;
  bool _loading = false;
  bool _cancelled = false;
  String? _error;
  MasterPracticeEntry? _selected;

  MasterPracticeReview? get review => _review;
  bool get isLoading => _loading;
  String? get error => _error;
  MasterPracticeEntry? get selected => _selected;
  MasterGamesStats? get stats => _service.stats;

  MasterPracticeReviewer? _reviewerFor(MasterGamesDb db) => _reviewer ??=
      MasterPracticeReviewer(lookup: db.bookMoves, gameById: db.game);

  /// Walk [games] and select the first entry worth looking at.
  Future<void> run(List<RecentGame> games) async {
    final db = _service.db;
    if (db == null) {
      _error = 'The master games database is not open.';
      notifyListeners();
      return;
    }
    final reviewer = _reviewerFor(db)!;
    _loading = true;
    _cancelled = false;
    _error = null;
    notifyListeners();
    try {
      final result = await reviewer.review(
        games,
        isCancelled: () => _cancelled,
      );
      _review = result;
      _selected = result.mine.isNotEmpty
          ? result.mine.first
          : result.theirs.isNotEmpty
          ? result.theirs.first
          : result.inBook.firstOrNull;
    } catch (e) {
      _error = 'Could not check your games: $e';
      _review = null;
      _selected = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void cancel() {
    if (_loading) _cancelled = true;
  }

  void select(MasterPracticeEntry? entry) {
    if (identical(entry, _selected)) return;
    _selected = entry;
    notifyListeners();
  }

  /// Write [entry]'s key games as one PGN collection and return its path and
  /// the index of [focus] in it, for the viewer.
  Future<({String path, int index})> writeKeyGames(
    MasterPracticeEntry entry, {
    required MasterGame focus,
  }) async {
    final dir = await AppPaths.pgnCollectionsDirectory(create: true);
    final file = File(p.join(dir.path, collectionName));
    final buffer = StringBuffer();
    var index = 0;
    for (var i = 0; i < entry.keyGames.length; i++) {
      final game = entry.keyGames[i].game;
      if (game.id == focus.id) index = i;
      buffer.write(game.toPgn());
    }
    await writeTextFileAtomically(file, buffer.toString());
    return (path: file.path, index: index);
  }
}
