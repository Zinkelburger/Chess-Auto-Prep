import '../fen.dart';
import 'search_node.dart';

/// Why a search stopped before it reached the horizon everywhere.
enum StopReason {
  /// The caller asked it to stop.
  cancelled,

  /// The next expansion would not fit in the node budget.
  nodeBudget,
}

/// What a search produced. Every outcome is a value, including the two
/// failures: a build that runs for hours against an engine and a model will
/// sometimes lose one of them, and that is an answer, not an accident.
sealed class SearchResult {
  const SearchResult();
}

/// Expanded to the horizon everywhere. Every node's bounds are equal, so the
/// root's value is the final answer for this model.
final class SearchComplete extends SearchResult {
  const SearchComplete(this.tree);

  final SearchNode tree;
}

/// Stopped early. The tree is whole — no node in it has half an action set —
/// but some of its leaves are [FrontierNode]s, so the root's bounds say how
/// far the answer could still move and its leader is not solved.
final class SearchIncomplete extends SearchResult {
  const SearchIncomplete({required this.tree, required this.reason});

  final SearchNode tree;
  final StopReason reason;
}

/// The opponent model had nothing to say about a position where the opponent
/// is to move, so the search stopped. Nothing is substituted for it: a guess
/// at what the opponent plays would silently change what the tree means.
final class PolicyMissing extends SearchResult {
  const PolicyMissing({
    required this.fen,
    required this.reason,
    required this.tree,
  });

  final Fen fen;
  final String reason;

  /// Everything the search had built when it stopped, with the node it was
  /// expanding left untouched — null only when the root itself never got a
  /// value. A build that has run for hours does not lose its tree because
  /// one position could not be answered for; the caller can show it, save it
  /// and resume from it.
  final SearchNode? tree;
}

/// The engine could not score a position, so the search stopped. The loss
/// window and the horizon both need the score; skipping it would quietly
/// prepare a move on no evidence.
final class EvaluationFailed extends SearchResult {
  const EvaluationFailed({
    required this.fen,
    required this.reason,
    required this.tree,
  });

  final Fen fen;
  final String reason;

  /// What the search had built when the engine gave up, on the same terms as
  /// [PolicyMissing.tree].
  final SearchNode? tree;
}
