/// Reading and writing a game's stored analysis: the `[%eval]`, `[%pv]` and
/// `[%maia*]` tokens a review pass leaves on each mainline move, in the
/// Lichess export format.
///
/// [parseCachedEvals] restores a [MoveEval] series from those tokens without
/// re-running the engine; [writeEvalComment], [injectBestLines] and
/// [buildAnalyzedMovetext] put them back onto a parsed game so the reader's
/// file can be replaced with the annotated text. The top-level parser is
/// isolate-safe (used through `compute`).
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:dartchess/dartchess.dart';

import 'package:chess_auto_prep/chess_core/pgn/pgn_analysis_variations.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_dummy_mainline.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart'
    show isNullMoveSan, playSanOrNullMove;
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart';
import 'package:chess_auto_prep/chess_core/analysis/move_eval.dart';

// ---------------------------------------------------------------------------
// Start position and mainline replay
// ---------------------------------------------------------------------------

/// The `[FEN]` a `[SetUp "1"]` game starts from, or null for the standard
/// start. Analysis honours the SetUp flag (unlike the viewer's lenient
/// `startPositionFromGame`), so a stray FEN tag on a normal game does not
/// shift every score.
String? setupFenOf(Map<String, String> headers) {
  final setupFlag = headers['SetUp'] ?? headers['Setup'] ?? '';
  final fen = headers['FEN'] ?? '';
  return setupFlag == '1' && fen.isNotEmpty ? fen : null;
}

/// The position [headers]' movetext starts from; see [setupFenOf]. Throws
/// when the FEN header does not parse.
Position gameStartPosition(Map<String, String> headers) {
  final fen = setupFenOf(headers);
  return fen == null ? Chess.initial : Chess.fromSetup(Setup.parseFen(fen));
}

/// One real move of a replayed mainline.
typedef MainlinePly = ({
  // 1-based mainline index, counting null moves.
  int ply,
  PgnNodeData node,
  Position before,
  Position after,
  Move move,
});

/// The replayed mainline and the board it ends on ([end] is the position
/// after the last move that was played, null moves included).
typedef MainlineReplay = ({List<MainlinePly> plies, Position end});

/// Replay [mainline] from [start]: one [MainlinePly] per real move. Null
/// moves advance the board and the ply count but produce no entry. Stops
/// silently at the first move that does not play.
MainlineReplay replayMainline(Position start, List<PgnNodeData> mainline) {
  final plies = <MainlinePly>[];
  var pos = start;
  for (var i = 0; i < mainline.length; i++) {
    final node = mainline[i];
    if (isNullMoveSan(node.san)) {
      final next = playSanOrNullMove(pos, node.san);
      if (next == null) break;
      pos = next;
      continue;
    }
    final move = pos.parseSan(node.san);
    if (move == null) break;
    final before = pos;
    pos = pos.play(move);
    plies.add((ply: i + 1, node: node, before: before, after: pos, move: move));
  }
  return (plies: plies, end: pos);
}

// ---------------------------------------------------------------------------
// Reading stored evals
// ---------------------------------------------------------------------------

/// Restore per-move evals from a game's stored `[%eval]` comments, or null
/// when the game does not count as analyzed (more than
/// [kMaxUnevaluatedPlies] plies lack an eval).
/// Public because the games list derives its review summaries from the same
/// parse (see `features/games/services/game_review_summary.dart`).
typedef CachedGameAnalysis = ({
  List<MoveEval> evals,
  double startWinChance,
  int totalMoves,
});

CachedGameAnalysis? parseCachedEvals(String pgnText) {
  final parsed = parsePgnGame(pgnText);
  promoteNullMoveDummyMainline(parsed.moves);
  return _parseGameEvals(parsed);
}

CachedGameAnalysis? _parseGameEvals(PgnGame<PgnNodeData> parsed) {
  final mainline = parsed.moves.mainline().toList();
  if (mainline.isEmpty) return null;

  final replay = replayMainline(gameStartPosition(parsed.headers), mainline);
  final results = <MoveEval>[];
  var missingCount = 0;
  for (final ply in replay.plies) {
    final stored = _StoredMoveTokens.of(ply.node);
    if (ply.after.isCheckmate) {
      // Mate delivered on the board: the result is a fact of the position,
      // not an engine score. Any stored [%eval] here is ignored — a mate-0
      // engine score has no sign, so trusting it misclassifies the winner's
      // mating move as a blunder.
      final whiteWon = ply.after.turn == Side.black;
      results.add(
        MoveEval(
          ply: ply.ply,
          san: ply.node.san,
          fenBefore: ply.before.fen,
          fenAfter: ply.after.fen,
          winningChance: whiteWon ? 1.0 : -1.0,
          deliversCheckmate: true,
          maiaProb: stored.maiaProb,
          maiaTopMove: stored.maiaTop?.move,
          maiaTopProb: stored.maiaTop?.prob,
        ),
      );
      continue;
    }

    final evalData = stored.eval;
    if (evalData == null) {
      missingCount++;
      if (missingCount > kMaxUnevaluatedPlies) return null;
      continue;
    }

    results.add(
      MoveEval(
        ply: ply.ply,
        san: ply.node.san,
        fenBefore: ply.before.fen,
        fenAfter: ply.after.fen,
        scoreCp: evalData.cp,
        scoreMate: evalData.mate,
        winningChance: cpToWinningChance(evalData.cp, evalData.mate),
        maiaProb: stored.maiaProb,
        maiaTopMove: stored.maiaTop?.move,
        maiaTopProb: stored.maiaTop?.prob,
        bestLine: stored.bestLine,
        depth: evalData.depth,
      ),
    );
  }

  final realPlies = replay.plies.length;
  if (results.length < realPlies - kMaxUnevaluatedPlies) return null;

  final startWinChance = initialWinChance();
  return (
    evals: _classifySeries(results, startWinChance),
    startWinChance: startWinChance,
    totalMoves: realPlies,
  );
}

/// Each eval of [series] with its verdict, measured against the winning
/// chance the previous eval left (the first against [startWinChance]).
List<MoveEval> _classifySeries(List<MoveEval> series, double startWinChance) {
  var prevWinChance = startWinChance;
  final classified = <MoveEval>[];
  for (final e in series) {
    final loss = winningChanceLoss(
      isWhiteMove: e.isWhiteMove,
      before: prevWinChance,
      after: e.winningChance,
    );
    classified.add(
      e.copyWith(classification: classifyMove(loss, maiaProb: e.maiaProb)),
    );
    prevWinChance = e.winningChance;
  }
  return classified;
}

/// The analysis tokens a move's comments carry, first occurrence of each.
class _StoredMoveTokens {
  const _StoredMoveTokens({
    this.eval,
    this.maiaProb,
    this.maiaTop,
    this.bestLine = const [],
  });

  final ({int? cp, int? mate, int? depth})? eval;
  final double? maiaProb;
  final ({String move, double prob})? maiaTop;
  final List<String> bestLine;

  static _StoredMoveTokens of(PgnNodeData node) {
    ({int? cp, int? mate, int? depth})? eval;
    double? maiaProb;
    ({String move, double prob})? maiaTop;
    var bestLine = const <String>[];
    for (final comment in node.comments ?? const <String>[]) {
      eval ??= parseEvalComment(comment);
      maiaProb ??= parseMaiaComment(comment);
      maiaTop ??= parseMaiaTopComment(comment);
      if (bestLine.isEmpty) {
        final pv = parsePvComment(comment);
        if (pv.isNotEmpty) bestLine = pv;
      }
    }
    return _StoredMoveTokens(
      eval: eval,
      maiaProb: maiaProb,
      maiaTop: maiaTop,
      bestLine: bestLine,
    );
  }
}

// ---------------------------------------------------------------------------
// Writing analysis back onto a game
// ---------------------------------------------------------------------------

/// Add standard quality NAGs to an analyzed game's mainline using the same
/// classifications as cached review. Existing author glyphs and sidelines stay
/// intact; classified PVs become standard RAVs with a best-line path reference.
/// Games without enough stored evaluations are left untouched. Returns whether
/// any PV payload was converted, so editable readers can persist migration.
bool annotateGameMoveQuality(PgnGame<PgnNodeData> game) {
  final analysis = _parseGameEvals(game);
  if (analysis == null) return false;
  final moves = game.moves.mainline().toList();
  for (final eval in analysis.evals) {
    final move = moves[eval.ply - 1];
    move.nags = eval.classification.annotateNags(move.nags);
  }
  return materializeAnalysisVariations(game, {
    for (final eval in analysis.evals)
      if (eval.classification != MoveClassification.normal) eval.ply - 1,
  });
}

/// [pgnText]'s movetext with a `[%pv]` written onto each mainline move named
/// in [linesByPly] (1-based ply → SAN line from the position before it),
/// alongside whatever comment the move already carries. Classified lines are
/// then stored as standard RAVs with a `[%bestline]` path reference. Null when
/// the game does not parse or names no such ply.
String? injectBestLines(String pgnText, Map<int, List<String>> linesByPly) {
  if (linesByPly.isEmpty) return null;
  final PgnGame<PgnNodeData> parsed;
  try {
    parsed = parsePgnGame(pgnText);
  } on Object {
    return null;
  }
  final mainline = parsed.moves.mainline().toList();
  var written = false;
  for (final entry in linesByPly.entries) {
    final index = entry.key - 1;
    if (index < 0 || index >= mainline.length || entry.value.isEmpty) continue;
    _editFirstComment(mainline[index], (c) => setPvInComment(c, entry.value));
    written = true;
  }
  if (!written) return null;
  return buildAnalyzedMovetext(parsed);
}

/// Write [eval]'s score, best line and Maia top move onto [node]'s first
/// comment (creating one when the move has none).
void writeEvalComment(PgnNodeData node, MoveEval eval) {
  _editFirstComment(node, (comment) {
    var updated = setEvalInComment(comment, eval.toEvalComment());
    updated = setPvInComment(updated, eval.bestLine);
    final topMove = eval.maiaTopMove;
    final topProb = eval.maiaTopProb;
    if (topMove != null && topProb != null) {
      updated = setMaiaTopInComment(updated, topMove, topProb);
    }
    return updated;
  });
}

/// Write Maia's probability for the move played onto [node]'s first comment.
void writeMaiaComment(PgnNodeData node, double prob) =>
    _editFirstComment(node, (comment) => setMaiaInComment(comment, prob));

/// Replace [node]'s first comment with [edit] of it, treating a move without
/// comments as one with an empty comment.
void _editFirstComment(PgnNodeData node, String Function(String) edit) {
  final comments = node.comments;
  if (comments != null && comments.isNotEmpty) {
    comments[0] = edit(comments[0]);
  } else {
    node.comments = [edit('')];
  }
}

/// The analyzed [game] as movetext, for the caller to store: its verdicts
/// written as NAGs and its lines as variations ([annotateGameMoveQuality]).
///
/// [game] itself, not its mainline: the pass writes `[%eval]`/`[%pv]` onto
/// the tree's own nodes, and this text goes on to *replace* the game in the
/// reader's file (`ViewerDocumentController.persistMoveCommentsFor`). Serializing
/// the mainline alone deleted every variation and the game's opening
/// comment from that file. Same writer as the comment editor's
/// `ViewerGameController.buildAnnotatedMovetext`, which lands in the same slot.
String buildAnalyzedMovetext(PgnGame<PgnNodeData> game) {
  annotateGameMoveQuality(game);
  return buildGameMovetext(
    moves: game.moves,
    comments: game.comments,
    fen: game.headers['FEN'],
    result: game.headers['Result'],
  );
}
