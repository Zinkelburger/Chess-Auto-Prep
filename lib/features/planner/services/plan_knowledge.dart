/// What the planner already knows about the user before asking anything:
/// the moves their existing chapters play, and the moves they actually play
/// in their own games. Both are position → move → count maps, so a question
/// at a position can be pre-answered ("your Advance chapter plays …c5 here")
/// or pre-ticked ("you played …c6 here in 40 of 52 games").
///
/// This is deliberately just counting. No inference about "style": if the
/// user has played the move at this position, we know; otherwise we do not.
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';

import '../../../chess_core/pgn/pgn_text.dart' as pgn;
import '../../../services/pgn_tree_core.dart';
import '../../../utils/chess_utils.dart';
import '../../../utils/fen_utils.dart';

/// position (normalized FEN) → SAN → count.
typedef MoveCounts = Map<String, Map<String, int>>;

/// How often the user played one move at a position: its share of their
/// games there, and how many games that is.
typedef OwnMoveShare = ({double share, int games});

/// What counting a corpus of the user's games produced.
typedef OwnGameCounts = ({MoveCounts moves, MoveCounts replies, int games});

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
  OwnMoveShare? ownMoveAt(String fen, String san) =>
      _shareOf(ownMoves, fen, san);

  /// The opponents' share of [san] at [fen] in the user's games.
  OwnMoveShare? ownReplyAt(String fen, String san) =>
      _shareOf(ownReplies, fen, san);

  /// Number of the user's games that reached [fen], whoever is to move.
  /// (Only one of the two maps has entries for a given side to move.)
  int ownGamesAt(String fen) =>
      ownCountsAt(fen).values.fold(0, (a, b) => a + b);

  /// SAN → games for whatever was played at [fen] in the user's games: their
  /// own moves when it is their turn, the opponents' replies otherwise.
  Map<String, int> ownCountsAt(String fen) {
    final key = normalizeFen(fen);
    return ownMoves[key] ?? ownReplies[key] ?? const {};
  }

  bool get hasOwnGames => ownMoves.isNotEmpty || ownReplies.isNotEmpty;

  static OwnMoveShare? _shareOf(MoveCounts counts, String fen, String san) {
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
        if (_isOurTurn(pos, isWhite)) _tally(out, pos.fen, san);
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
  static Future<OwnGameCounts> countOwnGames(
    String pgnText, {
    required String heroNames,
    required bool isWhite,
    int maxPlies = 40,
  }) {
    return Isolate.run(
      () => countOwnGamesSync(
        pgnText,
        heroNames: heroNames,
        isWhite: isWhite,
        maxPlies: maxPlies,
      ),
    );
  }

  /// Same as [countOwnGames], on the calling isolate (small corpora, tests).
  static OwnGameCounts countOwnGamesSync(
    String pgnText, {
    required String heroNames,
    required bool isWhite,
    int maxPlies = 40,
  }) {
    final moves = <String, Map<String, int>>{};
    final replies = <String, Map<String, int>>{};
    var games = 0;
    final hero = heroNames.toLowerCase();
    for (final text in pgn.splitPgnIntoGames(pgnText)) {
      final PgnGame game;
      try {
        game = parsePgnGame(text);
      } catch (_) {
        // An unparsable game is not the user's evidence of anything.
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
        _tally(_isOurTurn(pos, isWhite) ? moves : replies, pos.fen, san);
        final next = playSanOrNullMove(pos, san);
        if (next == null) break;
        pos = next;
      }
    }
    return (moves: moves, replies: replies, games: games);
  }

  static bool _isOurTurn(Position pos, bool isWhite) =>
      (pos.turn == Side.white) == isWhite;

  static void _tally(MoveCounts counts, String fen, String san) {
    final here = counts.putIfAbsent(normalizeFen(fen), () => {});
    here[san] = (here[san] ?? 0) + 1;
  }
}
