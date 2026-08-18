/// What the planner already knows about the user before asking anything:
/// the moves their existing chapters play, and the moves they actually play
/// in their own games. Both are position → move → count maps, so a question
/// at a position can be pre-answered ("your Advance chapter plays …c5 here")
/// or pre-ticked ("you played …c6 here in 40 of 52 games").
///
/// This is deliberately just counting. No inference about "style": if the
/// user has played the move at this position, we know; otherwise we do not.
library;

import 'dart:isolate';

import 'package:dartchess/dartchess.dart';

import '../../../services/pgn_parsing_service.dart' as pgn;
import '../../../services/pgn_tree_core.dart';
import '../../../utils/chess_utils.dart';
import '../../../utils/fen_utils.dart';

/// position (normalized FEN) → SAN → count.
typedef MoveCounts = Map<String, Map<String, int>>;

class PlanKnowledge {
  /// Our moves in the repertoire's existing chapters.
  final MoveCounts chapterMoves;

  /// Our moves in the user's own games (games where they had our colour).
  final MoveCounts ownMoves;

  /// The opponents' replies in those same games.
  final MoveCounts ownReplies;

  const PlanKnowledge({
    this.chapterMoves = const {},
    this.ownMoves = const {},
    this.ownReplies = const {},
  });

  static const empty = PlanKnowledge();

  /// SANs the chapters play at [fen] (usually one).
  Set<String> chapterMovesAt(String fen) =>
      (chapterMoves[normalizeFen(fen)] ?? const {}).keys.toSet();

  /// Own-game share of [san] at [fen] and the number of games there.
  ({double share, int games})? ownMoveAt(String fen, String san) =>
      _shareOf(ownMoves, fen, san);

  ({double share, int games})? ownReplyAt(String fen, String san) =>
      _shareOf(ownReplies, fen, san);

  int ownGamesAt(String fen) =>
      (ownMoves[normalizeFen(fen)] ?? const {}).values.fold(0, (a, b) => a + b);

  static ({double share, int games})? _shareOf(
    MoveCounts counts,
    String fen,
    String san,
  ) {
    final here = counts[normalizeFen(fen)];
    if (here == null || here.isEmpty) return null;
    final total = here.values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return null;
    return (share: (here[san] ?? 0) / total, games: total);
  }

  PlanKnowledge copyWith({
    MoveCounts? chapterMoves,
    MoveCounts? ownMoves,
    MoveCounts? ownReplies,
  }) => PlanKnowledge(
    chapterMoves: chapterMoves ?? this.chapterMoves,
    ownMoves: ownMoves ?? this.ownMoves,
    ownReplies: ownReplies ?? this.ownReplies,
  );

  // ── Builders ───────────────────────────────────────────────────────────

  /// Count our moves along each line (SAN lists from the start position).
  static MoveCounts countOurMovesInLines(
    Iterable<List<String>> lines, {
    required bool isWhite,
    int maxPlies = 40,
  }) {
    final out = <String, Map<String, int>>{};
    for (final moves in lines) {
      Position pos = Chess.initial;
      for (var i = 0; i < moves.length && i < maxPlies; i++) {
        final san = moves[i];
        final ours = (pos.turn == Side.white) == isWhite;
        if (ours) {
          final key = normalizeFen(pos.fen);
          final here = out.putIfAbsent(key, () => {});
          here[san] = (here[san] ?? 0) + 1;
        }
        final next = playSanOrNullMove(pos, san);
        if (next == null) break;
        pos = next;
      }
    }
    return out;
  }

  /// Count the user's moves and their opponents' replies in a PGN corpus.
  /// Only games where the user (matched by [heroNames], `;`-separated) held
  /// [isWhite]'s colour count. Runs off the UI isolate.
  static Future<({MoveCounts moves, MoveCounts replies, int games})>
  countOwnGames(
    String pgnText, {
    required String heroNames,
    required bool isWhite,
    int maxPlies = 40,
  }) {
    return Isolate.run(
      () => _countOwnGamesSync(
        pgnText,
        heroNames: heroNames,
        isWhite: isWhite,
        maxPlies: maxPlies,
      ),
    );
  }

  static ({MoveCounts moves, MoveCounts replies, int games}) _countOwnGamesSync(
    String pgnText, {
    required String heroNames,
    required bool isWhite,
    required int maxPlies,
  }) {
    final moves = <String, Map<String, int>>{};
    final replies = <String, Map<String, int>>{};
    var games = 0;
    final hero = heroNames.toLowerCase();
    for (final text in pgn.splitPgnIntoGames(pgnText)) {
      final PgnGame game;
      try {
        game = PgnGame.parsePgn(text);
      } catch (_) {
        continue;
      }
      final white = (game.headers['White'] ?? '').toLowerCase();
      final black = (game.headers['Black'] ?? '').toLowerCase();
      final heroWhite = userNameMatchesHeader(white, hero);
      final heroBlack = userNameMatchesHeader(black, hero);
      if (heroWhite == heroBlack) continue; // unknown or both
      if (heroWhite != isWhite) continue;
      games++;
      Position pos = Chess.initial;
      var ply = 0;
      for (final node in game.moves.mainline()) {
        if (ply++ >= maxPlies) break;
        final san = node.san;
        final ours = (pos.turn == Side.white) == isWhite;
        final key = normalizeFen(pos.fen);
        final target = ours ? moves : replies;
        final here = target.putIfAbsent(key, () => {});
        here[san] = (here[san] ?? 0) + 1;
        final next = playSanOrNullMove(pos, san);
        if (next == null) break;
        pos = next;
      }
    }
    return (moves: moves, replies: replies, games: games);
  }
}
