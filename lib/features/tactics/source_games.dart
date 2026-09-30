import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/tactics/game_ids.dart';
import '../../chess/tactics/mistake_counts.dart';
import '../../chess/tactics/puzzle.dart';
import '../../chess/tactics/source_game.dart';
import '../../diagnostics/log.dart';
import '../../storage/my_accounts.dart';
import '../../storage/my_games_files.dart';
import 'puzzle_trainer.dart';
import 'tactics_set.dart';

/// What the Game tab shows for the puzzle on the board.
sealed class SourceView {
  const SourceView();
}

/// No puzzle is on the board.
final class NoPuzzleUp extends SourceView {
  const NoPuzzleUp();
}

final class SourceReading extends SourceView {
  const SourceReading();
}

/// The puzzle came from no game the app knows: one made by hand, or one
/// whose set keeps no moves for it.
final class NoSourceGame extends SourceView {
  const NoSourceGame();
}

/// [game], the one [puzzle] was mined from, and the review's [counts] for
/// it when it has them.
final class SourceShown extends SourceView {
  const SourceShown(this.puzzle, this.game, this.counts);

  final Puzzle puzzle;
  final PuzzleGame game;
  final MistakeCounts? counts;
}

/// The games the puzzles were mined from: the saved download each puzzle's
/// `GameId` names, found in the games cache, or — when the cache no longer
/// has it — the game the puzzle's own headers describe.
///
/// It follows the puzzle on the board ([view]) and answers for any puzzle
/// ([gameOf]) for the list's menu. A game found once is kept for the owner's
/// life: a saved game's text does not change under its id. A game the file
/// does not hold is looked for again only once the file has changed.
final class SourceGames extends ChangeNotifier {
  SourceGames({
    required PuzzleTrainer trainer,
    required TacticsSet set,
    required GamesCache cache,
    required AccountStore accounts,
  }) : _trainer = trainer,
       _set = set,
       _cache = cache,
       _accounts = accounts {
    _trainer.addListener(_trainerChanged);
    _set.addListener(_setChanged);
  }

  final PuzzleTrainer _trainer;
  final TacticsSet _set;
  final GamesCache _cache;
  final AccountStore _accounts;

  /// The games looked up and found, by id: only those, not the whole file.
  final _found = <String, String>{};

  /// What each saved file held when last parsed, by path, so a game it did
  /// not hold is not looked for again until the file changes.
  final _ids = <String, SavedIds>{};

  SourceView _view = const NoPuzzleUp();
  Puzzle? _following;
  int _reads = 0;
  bool _disposed = false;

  SourceView get view => _view;

  /// [puzzle]'s game, the saved download when the cache has it.
  Future<PuzzleGame?> gameOf(Puzzle puzzle) async =>
      puzzleGame(puzzle, saved: await _savedText(puzzle.gameId));

  void _trainerChanged() {
    final puzzle = _trainer.up?.puzzle;
    if (puzzle?.fen == _following?.fen && puzzle?.index == _following?.index) {
      return;
    }
    _following = puzzle;
    unawaited(_follow(puzzle));
  }

  /// The review wrote new counts: the game on view takes them.
  void _setChanged() {
    final view = _view;
    if (view is! SourceShown) return;
    final counts = _set.mistakes.value[view.puzzle.gameId];
    if (counts == view.counts) return;
    _become(SourceShown(view.puzzle, view.game, counts));
  }

  Future<void> _follow(Puzzle? puzzle) async {
    final ticket = ++_reads;
    if (puzzle == null) return _become(const NoPuzzleUp());
    _become(const SourceReading());
    final game = await gameOf(puzzle);
    if (_disposed || ticket != _reads) return;
    _become(
      game == null
          ? const NoSourceGame()
          : SourceShown(puzzle, game, _set.mistakes.value[puzzle.gameId]),
    );
  }

  /// The saved game [gameId] names, from the account of its site; null when
  /// it has no id, its site has no account or the cache does not hold it.
  /// The cache only adds to what the puzzle knows, so a read that fails is
  /// logged and answered with nothing.
  Future<String?> _savedText(String gameId) async {
    if (gameId.isEmpty) return null;
    if (_found[gameId] case final text?) return text;
    final site = GameSite.values
        .where((s) => gameId.startsWith('${s.name}_'))
        .firstOrNull;
    if (site == null) return null;
    try {
      final accounts = await _accounts.snapshot();
      if (accounts is! AccountsSnapshot) return null;
      final username = accounts.accounts[site]?.username;
      if (username == null) return null;
      final file = _cache.refFor(site, username).path;
      switch (await _cache.lookUp(site, username, gameId, known: _ids[file])) {
        case SavedGameFound(:final text, :final ids):
          _ids[file] = ids;
          return _found[gameId] = text;
        case SavedGameMissing(:final ids?):
          _ids[file] = ids;
        case SavedGameMissing():
          _ids.remove(file);
        case SavedGameUnreadable(:final detail):
          log.w('read the saved game $gameId', detail);
      }
    } on Object catch (error) {
      log.w('read the saved game $gameId', error);
    }
    return null;
  }

  void _become(SourceView view) {
    if (_disposed) return;
    _view = view;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _trainer.removeListener(_trainerChanged);
    _set.removeListener(_setChanged);
    super.dispose();
  }
}
