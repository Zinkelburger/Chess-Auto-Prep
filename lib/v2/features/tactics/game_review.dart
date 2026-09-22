import '../../chess/fen.dart';
import '../../chess/pgn/pgn_reader.dart';
import '../../chess/tactics/game_ids.dart';
import '../../chess/tactics/mining.dart';
import '../../engines/engine.dart';
import '../../engines/engine_line.dart';

/// The depth every move is judged at: the old app's default, so the same
/// game gives the same puzzles in both apps.
const reviewDepth = 15;

/// The engine's pass over one of the user's games: the position before each
/// of their moves, and the one after it unless they played the engine's own
/// choice. Answers the puzzles the game's mistakes make, an empty list for a
/// game that is not theirs, not standard chess or not readable, and null
/// when the engine stopped answering part way — the game is then not done,
/// and is looked at again next time.
Future<List<MinedPuzzle>?> reviewGame(
  Engine engine,
  String gameText,
  String username, {
  int depth = reviewDepth,
}) async {
  final read = readGame(gameText);
  final tree = read.tree;
  final side = sideOf(read.tags, username);
  if (tree == null || side == null || !isStandardChess(read.tags)) {
    return const [];
  }
  final game = SourceGame.of(read.tags, tree, gameIdIn(gameText));
  final found = <MinedPuzzle>[];
  for (final move in movesBy(tree, side)) {
    if (isOver(move.after)) continue;
    final before = await verdictAt(engine, move.before, depth: depth);
    if (before == null) return null;
    if (playedBest(move, before)) continue;
    final after = await verdictAt(engine, move.after, depth: depth);
    if (after == null) return null;
    final puzzle = minedFrom(move, before, after, game);
    if (puzzle != null) found.add(puzzle);
  }
  return found;
}

/// One fixed-depth search of [fen]: the last best line the engine reported,
/// or null when it reached neither [depth] nor a mate — an engine that died
/// or was quit under the review.
Future<Verdict?> verdictAt(Engine engine, Fen fen, {required int depth}) async {
  EngineLine? last;
  try {
    final search = engine.analyse(fen, multiPv: 1, depth: depth);
    await for (final line in search.lines) {
      if (line.multiPv == 1) last = line;
    }
  } on EngineFailure {
    return null;
  }
  if (last == null) return null;
  if (last.depth < depth && last.score is! MateIn && last.pv.isNotEmpty) {
    return null;
  }
  return switch (last.score) {
    Centipawns(:final value) => Verdict(cp: value, pv: last.pv),
    MateIn(:final moves) => Verdict(mate: moves, pv: last.pv),
  };
}
