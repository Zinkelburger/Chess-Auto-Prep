import 'dart:typed_data';

import 'explorer_answer.dart';
import 'fen.dart';
import 'pgn/game_text.dart';
import 'pgn/game_tree.dart';
import 'pgn/pgn_reader.dart';

/// How deep into each game the index reads: move 25, the depth the
/// explorer asks the online databases to.
const indexedPlies = 50;

/// How many games an answer names under its moves.
const gamesListed = 100;

/// Many games merged into one opening tree, looked up by position: the old
/// PGN Viewer's `Tree` tab, which the Explorer tab now shows as `This file`
/// and `My games`.
///
/// Representation: for every position a game's main line passes through in
/// its first [indexedPlies] plies, keyed by [positionKey] (so two move
/// orders that reach one position meet, as on lila), the moves the games
/// played from it, each with the numbers of the games that played it, in
/// the order the games were given. A game's result is kept once, so the
/// counts are worked out when asked, over only the games a filter keeps,
/// without building anything again.
///
/// A game that comes back to a position it has been in plays from it once:
/// counting the second visit would count one game twice.
///
/// Example: games `1. e4 e5 2. Nf3 1-0` and `1. Nf3 e5 2. e4 0-1` both reach
/// the position after 1. e4 e5 2. Nf3 / 1. Nf3 e5 2. e4 — the index has
/// one entry there, and at the start `e4` holds game 0 (a White win) and
/// `Nf3` game 1 (a Black win).
final class OpeningIndex {
  OpeningIndex._(this._moves, this._results, this.games, this.unread);

  /// Reads [texts], one game each, and indexes their main lines.
  ///
  /// [ids] names each game for the games list — the database's id — and
  /// defaults to its place in [texts]. [onProgress] hears how many games
  /// are done, every [progressEvery] games. A text that is not a game — no
  /// moves, a start position that cannot be played from — is counted in
  /// [unread] and indexes nothing.
  factory OpeningIndex.of(
    List<String> texts, {
    List<String>? ids,
    void Function(int done)? onProgress,
  }) {
    final moves = <int, Map<String, List<int>>>{};
    final results = Uint8List(texts.length);
    final games = <ExplorerGame>[];
    var unread = 0;
    for (final (index, text) in texts.indexed) {
      final read = readGame(text);
      results[index] = _resultOf(read).index;
      games.add(_gameOf(read.tags, ids?[index] ?? '$index'));
      final tree = read.tree;
      if (tree == null || tree.isEmpty) {
        unread++;
      } else {
        _addMainLine(moves, index, tree.rootFen, tree.children.first);
      }
      if (onProgress != null && (index + 1) % progressEvery == 0) {
        onProgress(index + 1);
      }
    }
    return OpeningIndex._(moves, results, games, unread);
  }

  /// How often [OpeningIndex.of] reports progress, in games.
  static const progressEvery = 200;

  final Map<int, Map<String, List<int>>> _moves;
  final Uint8List _results;

  /// Every game given, in order, as the games list shows one.
  final List<ExplorerGame> games;

  /// How many of them had no moves to index.
  final int unread;

  int get gameCount => games.length;

  /// What the games say about [fen]: the moves played from it, most played
  /// first (then the one played first in the games' order), and the first
  /// [gamesListed] games that played one, in the order given. [keeps] leaves out every game it answers false for.
  ExplorerAnswer answer(Fen fen, {bool Function(int game)? keeps}) {
    final here = _moves[positionKey(fen)];
    if (here == null) return ExplorerAnswer.empty;
    // Each move with the first game that played it, which orders moves
    // played equally often.
    final moves = <(ExplorerMove, int)>[];
    final listed = <int>[];
    for (final MapEntry(key: uci, value: played) in here.entries) {
      final counts = [0, 0, 0, 0];
      for (final game in played.where((game) => keeps?.call(game) ?? true)) {
        counts[_results[game]]++;
        listed.add(game);
      }
      if (counts.every((n) => n == 0)) continue;
      final move = ExplorerMove(
        uci: uci,
        san: '',
        white: counts[GameResult.white.index],
        draws: counts[GameResult.draw.index],
        black: counts[GameResult.black.index],
        undecided: counts[GameResult.undecided.index],
      );
      moves.add((move, played.firstWhere((g) => keeps?.call(g) ?? true)));
    }
    moves.sort((a, b) {
      final byGames = b.$1.games.compareTo(a.$1.games);
      return byGames != 0 ? byGames : a.$2.compareTo(b.$2);
    });
    listed.sort();
    return ExplorerAnswer(
      moves: [for (final (move, _) in moves) move],
      games: [for (final game in listed.take(gamesListed)) games[game]],
    );
  }
}

/// How a game ended, as the index keeps it: one byte a game.
enum GameResult { white, draw, black, undecided }

/// Adds [game]'s main line from [first] on: each move under the position
/// it was played from, down to [indexedPlies] plies.
void _addMainLine(
  Map<int, Map<String, List<int>>> moves,
  int game,
  Fen start,
  MoveNode first,
) {
  final seen = <int>{};
  var before = start;
  MoveNode? node = first;
  for (var ply = 0; node != null && ply < indexedPlies; ply++) {
    final key = positionKey(before);
    if (seen.add(key)) {
      (moves[key] ??= {}).putIfAbsent(node.uci, () => []).add(game);
    }
    before = node.fen;
    node = node.children.firstOrNull;
  }
}

/// The `[Result]` tag, else the marker the moves ended with.
GameResult _resultOf(GameRead read) {
  final said = tagValue(read.tags, 'Result')?.trim() ?? read.terminator;
  return switch (said) {
    '1-0' => GameResult.white,
    '0-1' => GameResult.black,
    '1/2-1/2' => GameResult.draw,
    _ => GameResult.undecided,
  };
}

/// The game as the explorer's games list names it.
ExplorerGame _gameOf(List<PgnHeader> tags, String id) {
  String known(String key) {
    final value = tagValue(tags, key)?.trim() ?? '';
    return value == '?' ? '' : value;
  }

  final date = known('UTCDate').isEmpty ? known('Date') : known('UTCDate');
  final result = known('Result');
  return ExplorerGame(
    id: id,
    white: known('White'),
    black: known('Black'),
    whiteElo: int.tryParse(known('WhiteElo')),
    blackElo: int.tryParse(known('BlackElo')),
    result: result.isEmpty ? '*' : result,
    year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
    event: known('Event'),
  );
}
