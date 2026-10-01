import 'package:dartchess/dartchess.dart' show Side;

import '../chess/fen.dart';
import '../chess/generation/eval.dart';
import '../chess/generation/evaluation_source.dart';
import '../chess/generation/mainline_book.dart';
import '../chess/generation/search_config.dart';
import '../chess/generation/search_node.dart';
import '../chess/generation/sources.dart';
import '../chess/generation/tree_wire_v4_reader.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/game_tree.dart';
import '../diagnostics/log.dart';
import '../net/chessdb_moves.dart';
import '../storage/chapter_files.dart';

/// What a search builds: expectimax against the human model, or ChessDB's
/// objectively best book (`chess/generation/mainline_book.dart`).
enum SearchMethod {
  practical('Maia practical'),
  mainline('ChessDB mainline');

  const SearchMethod(this.label);
  final String label;
}

/// What a search is asked for: the opponent's rating and how deep to go.
///
/// Interactive searches use the engine shortlist from the root down. A
/// different [rootMoves] still reuses a search: raising it adds only the new
/// root moves. The owner supplies the shared branching and rare-reply settings.
final class FillRequest {
  const FillRequest({
    required this.elo,
    this.depthPlies,
    this.source = EvaluationSource.stockfish,
    this.rootMoves = 4,
    this.candidateMoves = 4,
    this.replyFloor = 0.01,
    this.method = SearchMethod.practical,
    this.evalDepth = fillEvalDepth,
  });

  final SearchMethod method;
  final EvaluationSource source;

  /// Our moves kept for the first move of the search.
  final int rootMoves;

  /// Our moves kept at every later move of ours.
  final int candidateMoves;
  final double replyFloor;

  /// The engine depth each position is scored at.
  final int evalDepth;

  bool compatibleWith(FillRequest other) =>
      method == other.method &&
      evalDepth == other.evalDepth &&
      elo == other.elo &&
      source == other.source &&
      candidateMoves == other.candidateMoves &&
      replyFloor == other.replyFloor;

  /// The rating the opponent's replies are predicted for.
  final int elo;

  /// How many half-moves past the board the search plays out; null goes on
  /// until the user stops it. The mainline book branches on the
  /// opponent's choices this far and runs on past it.
  final int? depthPlies;

  /// What a saved tree names as its evaluation source, so a resume never
  /// mixes a book into an expectimax search or one source into another.
  String get treeSource =>
      method == SearchMethod.mainline ? 'chessDbMainline' : source.name;

  /// The rating a saved tree records: none for the book, which asks no
  /// model.
  int get treeRating => method == SearchMethod.mainline ? 0 : elo;

  /// The expectimax search this request asks for, playing [side], on top of
  /// the [seeded] positions a resumed tree already holds.
  SearchConfig expectimaxFor(Side side, {int seeded = 0}) => SearchConfig(
    side: side,
    horizonPlies: depthPlies,
    lossLimitCp: null,
    maxOurMoves: candidateMoves,
    rootMoves: rootMoves,
    replyFloor: replyFloor,
    replyMass: fillReplyMass,
    maxReplies: fillMaxReplies,
    nodeBudget: fillNodeBudget + seeded,
  );
}

/// The first of [trees], newest first, [request] can go on from for
/// [side]; or, when there is none, why the newest cannot.
Future<Object> savedSeed(
  Stream<String> trees,
  FillRequest request,
  Side side,
) async {
  String? refused;
  try {
    await for (final text in trees) {
      final decoded =
          await readSearchSeed(
            text,
            opponentRating: request.treeRating,
            side: side,
            evaluationSource: request.treeSource,
            evalDepth: request.evalDepth,
            candidateMoves: request.candidateMoves,
            replyFloor: request.replyFloor,
            replyMass: fillReplyMass,
            maxReplies: fillMaxReplies,
          ).catchError((Object error) {
            log.w('resume search', error);
            return 'The saved search could not be read.';
          });
      if (decoded is SearchNode) return decoded;
      refused ??= decoded as String;
    }
  } on Object catch (error) {
    log.w('resume search', error);
    refused ??= 'The saved search could not be read.';
  }
  return refused ?? 'No saved search starts at this board position.';
}

/// The engine depth a search scores positions at unless the Expectimax
/// tab asks for another; the shared cache is keyed on the depth.
const fillEvalDepth = 14;

/// The range the engine depth may be set to.
const minFillEvalDepth = 1;
const maxFillEvalDepth = 40;

/// One user-started search adds at most this many positions, under the interactive branching policy.
const fillNodeBudget = 25000;

/// The opponent's replies a search keeps at each of its positions: the
/// likeliest until they cover this share of Maia's distribution, at most
/// [fillMaxReplies], renormalised. Maia gives every legal move some weight,
/// and the 30-odd it barely expects would otherwise cost an engine
/// evaluation each.
const fillReplyMass = 0.9;
const fillMaxReplies = 5;

/// The range a search's depth may be set to, when it is set at all.
const minFillDepth = 1;
const maxFillDepth = 64;

/// What a search needs and where it comes from: an engine and the model, or
/// why there are none.
sealed class FillToolsResult {
  const FillToolsResult();
}

final class FillReady extends FillToolsResult {
  const FillReady({
    required this.evaluator,
    required this.policy,
    this.candidates,
    this.continuations,
    required this.release,
  });

  final PositionEvaluator evaluator;
  final OpponentPolicy policy;
  final CandidateSource? candidates;

  /// The engine with nothing in front of it, whose answers carry its best
  /// line: what a drafted line the search stopped mid-fight is continued
  /// with when the run itself did not score its last position (the cache
  /// keeps scores, not lines). Null where no engine is behind the tools.
  final PositionEvaluator? continuations;

  /// Hands the engine back; called once, when the run is over or cancelled.
  final Future<void> Function() release;
}

/// What the mainline book is built from: ChessDB's moves, for this run,
/// and the replies masters played ([practiceAt], most played first); none
/// there, and the book is ChessDB's mainline alone.
final class BookReady extends FillToolsResult {
  const BookReady({required this.chessDb, required this.practiceAt});

  final ChessDbMoves chessDb;
  final Future<List<PlayedMove>> Function(Fen fen) practiceAt;

  /// Ends the run's ChessDB lookups; called once, when the run is over.
  Future<void> release() async => chessDb.close();
}

final class FillUnavailable extends FillToolsResult {
  const FillUnavailable(this.reason);

  /// A sentence for the screen.
  final String reason;
}

typedef FillToolsFactory = Future<FillToolsResult> Function(FillRequest);

sealed class FillState {
  const FillState();
}

final class FillIdle extends FillState {
  const FillIdle();
}

final class FillRunning extends FillState {
  const FillRunning({
    required this.nodes,
    required this.depth,
    required this.of,
    this.cancelling = false,
    this.finishing = false,
    this.lastPly,
  });

  final int nodes;
  final int depth;

  /// The depth asked for; null when the search goes on until stopped.
  final int? of;
  final bool cancelling;

  /// The depth the search was asked to stop at once it is done there; null
  /// until it is.
  final int? lastPly;

  /// Asked to stop and keep what it has: the expansion under way is
  /// finished, then the tree as it stands is read.
  final bool finishing;

  /// Whether a stop has been asked for, either kind.
  bool get stopping => cancelling || finishing;

  FillRunning copyWith({
    int? nodes,
    int? depth,
    bool? cancelling,
    bool? finishing,
    int? lastPly,
  }) => FillRunning(
    nodes: nodes ?? this.nodes,
    depth: depth ?? this.depth,
    of: of,
    cancelling: cancelling ?? this.cancelling,
    finishing: finishing ?? this.finishing,
    lastPly: lastPly ?? this.lastPly,
  );
}

/// The run is over and its tree is in `FillGaps.found`: [depth] half-moves
/// deep over [nodes] positions, the whole way when [complete].
/// [budgetReached], [sourceLost] and [stoppedBy] say why it stopped short:
/// the position budget, ChessDB no longer answering the mainline book, or
/// the engine or the model giving up on one position.
final class FillDone extends FillState {
  const FillDone({
    required this.nodes,
    required this.depth,
    required this.complete,
    this.budgetReached = false,
    this.sourceLost = false,
    this.stoppedBy,
  });

  final int nodes;
  final int depth;
  final bool complete;
  final bool budgetReached;
  final bool sourceLost;

  /// A few words for the status line when the engine or the model could not
  /// answer one position; the position and the reason go to the log. The
  /// tree above it is kept.
  final String? stoppedBy;
}

final class FillFailed extends FillState {
  const FillFailed(this.reason);

  /// A sentence for the screen; the log has the same one.
  final String reason;
}

/// What became of turning a chapter's search into lines.
sealed class LinesState {
  const LinesState();
}

final class LinesWriting extends LinesState {
  const LinesWriting();
}

/// The lines are in the draft chapter [draft].
final class LinesWritten extends LinesState {
  const LinesWritten({required this.draft, required this.lines});

  final ChapterRef draft;
  final int lines;
}

final class LinesFailed extends LinesState {
  const LinesFailed(this.reason);

  final String reason;
}

/// Where a run began: the document's root and the moves from it to the
/// board, the side searched for, and — when the run can become lines —
/// the chapter as it was and its file.
final class FillTarget {
  const FillTarget({
    required this.rootFen,
    required this.cursor,
    required this.sans,
    required this.side,
    this.chapter,
  });

  final Fen rootFen;
  final NodePath cursor;
  final List<String> sans;
  final Side side;
  final (Chapter, ChapterRef)? chapter;

  /// How the log names the run.
  String get label => chapter?.$2.path ?? 'the board';

  /// The same start searched for the other side, for its values alone: it
  /// is never written as lines.
  FillTarget get mirror => FillTarget(
    rootFen: rootFen,
    cursor: cursor,
    sans: sans,
    side: side.opposite,
  );
}

/// [seed]'s position as the search for the other side starts from it: not
/// expanded, with the score the engine already gave it, which is the same
/// fact from the other side.
SearchNode? mirrorStart(SearchNode? seed) => seed == null || !seed.evaluated
    ? null
    : FrontierNode(fen: seed.fen, evalForUs: Eval(-seed.evalForUs.cp));

/// The tree of the last run, where it was started and what it was asked.
final class FillFound {
  const FillFound({
    required this.target,
    required this.request,
    required this.tree,
  });

  final FillTarget target;
  final FillRequest request;

  /// The search tree from the position the run started at.
  final SearchNode tree;

  Side get side => target.side;

  /// The chapter the run can be written into as lines, and its file.
  (Chapter, ChapterRef)? get chapter => target.chapter;

  /// The node for the position reached from [root] by [sans], or null when
  /// that position is not in the search: another document, a line that
  /// leaves the tree, or a position before the one the run started at.
  SearchNode? at(Fen root, List<String> sans) {
    if (root != target.rootFen || sans.length < target.sans.length) {
      return null;
    }
    for (final (i, san) in target.sans.indexed) {
      if (sans[i] != san) return null;
    }
    SearchNode node = tree;
    for (final san in sans.skip(target.sans.length)) {
      final next = switch (node) {
        OurNode(:final candidates) =>
          candidates.where((c) => c.move.san == san).firstOrNull?.child,
        OpponentNode(:final replies) =>
          replies.where((r) => r.move.san == san).firstOrNull?.child,
        _ => null,
      };
      if (next == null) return null;
      node = next;
    }
    return node;
  }
}
