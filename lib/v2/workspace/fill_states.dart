import '../chess/generation/evaluation_source.dart';
import '../chess/generation/sources.dart';
import '../storage/chapter_files.dart';

/// What a search is asked for: the opponent's rating and how deep to go.
///
/// Nothing else narrows it. Every legal move of ours is played and every
/// reply the model gives any weight is answered, level by level, so what a
/// search finds is not decided in advance by a window or a cover rule.
final class FillRequest {
  const FillRequest({
    required this.elo,
    this.depthPlies,
    this.source = EvaluationSource.stockfish,
  });

  final EvaluationSource source;

  /// The rating the opponent's replies are predicted for.
  final int elo;

  /// How many half-moves past the board the search plays out; null goes on
  /// until the user stops it.
  final int? depthPlies;
}

/// The engine depth every search scores positions at: the old app's
/// default, and what the shared cache is keyed on.
const fillEvalDepth = 14;

/// One user-started search adds at most this many positions, without pruning.
const fillNodeBudget = 25000;

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
    required this.release,
  });

  final PositionEvaluator evaluator;
  final OpponentPolicy policy;

  /// Hands the engine back; called once, when the run is over or cancelled.
  final Future<void> Function() release;
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
final class FillDone extends FillState {
  const FillDone({
    required this.nodes,
    required this.depth,
    required this.complete,
    this.budgetReached = false,
  });

  final int nodes;
  final int depth;
  final bool complete;
  final bool budgetReached;
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
