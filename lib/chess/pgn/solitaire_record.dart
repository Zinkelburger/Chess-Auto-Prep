import 'package:dartchess/dartchess.dart' show Move;

import 'game_tree.dart';
import 'tree_edit.dart';

/// What happened to one move tried while playing through a game.
enum SolitaireOutcome { gameMove, goodMove, betterMove, mistake, revealed }

/// One attempt at the source game's position [at], before the move is played.
///
/// The path always refers to the original game, even when [uci] is an
/// alternative. Evaluations are display values supplied by the assessment;
/// recording a session does not run an engine or change its verdict.
final class SolitaireAttempt {
  const SolitaireAttempt({
    required this.at,
    required this.uci,
    required this.outcome,
    this.hinted = false,
    this.evaluation,
    this.gameEvaluation,
  });

  final NodePath at;
  final String uci;
  final SolitaireOutcome outcome;
  final bool hinted;
  final String? evaluation;
  final String? gameEvaluation;
}

/// The whole source game with the session's attempts recorded beside it.
///
/// The original main line, variations, annotations and move spellings stay
/// in place. An attempt already present in the game adds a note to that
/// move; other attempts become single-move variations. Repeated attempts
/// share that move but each keeps its own note. Neither input is mutated.
GameTree solitaireReview(GameTree source, List<SolitaireAttempt> attempts) {
  var review = source;
  for (final attempt in attempts) {
    review = _record(review, source, attempt);
  }
  return review;
}

/// The revealed main line through [frontier], with completed tries only.
///
/// Source comments, NAGs and variations may give away future moves, even
/// when attached to a position already reached, so none enter this tree.
/// Tries at [frontier] wait until its game move has been revealed: attaching
/// one earlier would make the try the main continuation in a PGN tree.
/// [frontier] must be a mainline position in [source].
GameTree solitaireProgress(
  GameTree source,
  List<SolitaireAttempt> attempts,
  NodePath frontier,
) {
  if (frontier.indexes.any((index) => index != 0) ||
      (!frontier.isRoot && source.nodeAt(frontier) == null)) {
    throw ArgumentError.value(frontier, 'frontier', 'Not on the main line');
  }
  var children = const <MoveNode>[];
  for (final move in source.lineTo(frontier).reversed) {
    children = List.unmodifiable([
      MoveNode(
        san: move.san,
        uci: move.uci,
        fen: move.fen,
        spelling: move.spelling,
        children: children,
      ),
    ]);
  }
  var progress = GameTree(rootFen: source.rootFen, children: children);
  for (final attempt in attempts) {
    if (attempt.at != frontier && frontier.startsWith(attempt.at)) {
      progress = _record(progress, source, attempt);
    }
  }
  return progress;
}

GameTree _record(GameTree tree, GameTree source, SolitaireAttempt attempt) {
  final at = attempt.at;
  // A stale or invalid attempt cannot create a position that was never in
  // the game. In particular, fenAt's root fallback is not appropriate here.
  if (at.indexes.any((index) => index < 0) ||
      (!at.isRoot && source.nodeAt(at) == null)) {
    return tree;
  }
  if (source.nodeAt(at.mainChild) == null) return tree;
  final move = Move.parse(attempt.uci);
  final played = move == null ? null : moveNode(source.fenAt(at), move);
  if (played == null) return tree;
  final children = at.isRoot ? tree.children : tree.nodeAt(at)?.children;
  if (children == null) return tree;
  final index = children.indexWhere((node) => node.uci == played.uci);
  final note = _note(attempt);
  if (index < 0) {
    return withChildAdded(tree, at, played.copyWith(comment: note));
  }
  return withNodeChanged(tree, at.child(index), (node) {
    final before = node.comment;
    return node.copyWith(
      comment: before == null || before.isEmpty ? note : '$before $note',
    );
  });
}

String _note(SolitaireAttempt attempt) {
  final verdict = switch (attempt.outcome) {
    SolitaireOutcome.gameMove => 'Game move.',
    SolitaireOutcome.goodMove => 'Good alternative.',
    SolitaireOutcome.betterMove => 'Better than the game move.',
    SolitaireOutcome.mistake => 'Mistake.',
    SolitaireOutcome.revealed => 'Move shown.',
  };
  return [
    'Solitaire: $verdict',
    if (attempt.hinted) 'Hint used.',
    if (_score(attempt.evaluation) case final value?) 'Evaluation: $value.',
    if (_score(attempt.gameEvaluation) case final value?)
      'Game move evaluation: $value.',
  ].join(' ');
}

// Scores are display text, not PGN syntax. Never let an unexpected engine
// value terminate the comment and turn the rest of the report into moves.
String? _score(String? value) {
  final text = value?.replaceAll(RegExp(r'[{}]'), '').trim();
  return text == null || text.isEmpty ? null : text;
}
