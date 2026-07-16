/// Value types for the "Build by Playing" session.
///
/// Extracted verbatim from `build_by_playing_controller.dart` and re-exported
/// there, so existing imports keep resolving these names unchanged.
library;

enum BuildByPlayingPhase {
  /// No session running.
  idle,

  /// Auto-playing covered repertoire answers / navigating to a popped branch.
  advancing,

  /// Fetching database stats and playing the opponent's reply.
  opponentThinking,

  /// Parked at a decision point — the user's turn, no repertoire answer yet.
  awaitingUserMove,

  /// The user is playing ephemeral scratchpad moves from the decision point.
  exploring,

  /// A commit is being written to the repertoire file.
  committing,

  /// Explorer failure, rate limit, or external navigation. [resume] recovers.
  paused,

  /// The pending-branch stack is empty — every line reached a cutoff.
  sessionComplete,
}

/// An opponent reply queued for later: when the current line ends, the
/// session backtracks here and plays [opponentSan].
class PendingBranch {
  const PendingBranch({
    required this.pathFromRoot,
    required this.opponentSan,
    required this.opponentUci,
    required this.probability,
    required this.cumulativeProbability,
    required this.games,
    required this.epdAfter,
  });

  /// SAN moves from the tree root to the opponent-to-move position.
  final List<String> pathFromRoot;

  /// The queued reply.
  final String opponentSan;
  final String opponentUci;

  /// Local play fraction of the reply at its position.
  final double probability;

  /// Product of opponent move probabilities, including this reply.
  final double cumulativeProbability;

  /// Games of this reply in the database.
  final int games;

  /// Normalised FEN after the reply — for transposition dedup.
  final String epdAfter;
}
