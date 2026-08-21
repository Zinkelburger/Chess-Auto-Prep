/// Per-move annotation for extracted repertoire lines.
///
/// Everything the reader is told *about* a move — its eval, how hard it is to
/// find, whether it was forced, what the natural-looking alternative loses,
/// how badly the opponent erred — as opposed to which moves the line contains.
/// Carved out of [LineExtractor], whose job is the walk.
///
/// Pure: a function of the valued tree plus two policy values, with no owner
/// state. That is why the values are passed rather than supplied by callback —
/// the extractor never reassigns them mid-run, so a snapshot cannot desync.
library;

import '../../../models/build_tree_node.dart';
import 'move_annotation.dart';

/// Turns [BuildTreeNode]s into [MoveAnnotation]s.
class MoveAnnotator {
  const MoveAnnotator({required this.playAsWhite, required this.maxEvalLossCp});

  /// The side the repertoire is for — every eval is reported from here.
  final bool playAsWhite;

  /// The build's eval-loss window, which sets the bar for calling a move
  /// forced and stands in for the lead when no alternative was evaluated.
  final int maxEvalLossCp;

  /// Scaled to the build's eval-loss window: the expander never stores an
  /// alternative worse than [TreeBuildConfig.maxEvalLossCp], so with the
  /// default 50cp window a fixed 100cp bar could never be met.  A stored
  /// alternative that loses most of the window is what "forced" looks like
  /// in the tree.  A move with *no* stored sibling is not called forced:
  /// the fast search narrows or skips alternatives at cold nodes, so a sole
  /// child usually means unexplored rather than only.
  static const int _onlyMoveGapCp = 100;

  int get _onlyMoveThresholdCp {
    final scaled = maxEvalLossCp * 4 ~/ 5;
    return scaled < _onlyMoveGapCp ? scaled : _onlyMoveGapCp;
  }

  MoveAnnotation annotateOurMove(BuildTreeNode selected, int gapCp) {
    final isOnlyMove =
        _hasEvaluatedSibling(selected) && gapCp >= _onlyMoveThresholdCp;
    final natural = _naturalAlternative(selected);
    return MoveAnnotation(
      evalCp: selected.hasEngineEval ? selected.evalForUs(playAsWhite) : null,
      expectimaxValue: selected.hasExpectimax ? selected.expectimaxValue : null,
      myEase: selected.myEase >= 0 ? selected.myEase : null,
      isOnlyMove: isOnlyMove,
      onlyMoveLeadCp: isOnlyMove ? gapCp : null,
      humanFrequency: selected.maiaFrequency >= 0
          ? selected.maiaFrequency
          : null,
      naturalAlternativeSan: natural?.moveSan,
      naturalAlternativeLossCp: natural != null && natural.hasEngineEval
          ? selected.evalForUs(playAsWhite) - natural.evalForUs(playAsWhite)
          : null,
      practicalScore: _practicalScore(selected),
      gameCount: selected.totalGames > 0 ? selected.totalGames : null,
      lastPlayedYear: selected.lastPlayedYear > 0
          ? selected.lastPlayedYear
          : null,
    );
  }

  bool _hasEvaluatedSibling(BuildTreeNode selected) =>
      selected.parent?.children.any(
        (c) => !identical(c, selected) && c.hasEngineEval,
      ) ??
      false;

  /// The sibling humans clearly prefer to [selected], when there is one.
  ///
  /// Only siblings the tree holds can be named, and the expander keeps only
  /// moves inside the eval-loss window — so the alternative is always a
  /// *playable* natural move, which is the one worth warning about.  A
  /// natural move that simply loses never became a child and is not named.
  BuildTreeNode? _naturalAlternative(BuildTreeNode selected) {
    final parent = selected.parent;
    if (parent == null || selected.maiaFrequency < 0) return null;
    if (selected.maiaFrequency >= MoveAnnotation.kHardToFindFrequency) {
      return null;
    }
    BuildTreeNode? best;
    for (final sibling in parent.children) {
      if (identical(sibling, selected) || sibling.maiaFrequency < 0) continue;
      if (best == null || sibling.maiaFrequency > best.maiaFrequency) {
        best = sibling;
      }
    }
    if (best == null ||
        best.maiaFrequency - selected.maiaFrequency <
            MoveAnnotation.kNaturalAlternativeMargin) {
      return null;
    }
    return best;
  }

  /// Flag the last move with master games when the line then leaves them, so
  /// the reader sees where practice ends and the engine continuation starts.
  /// A line still in book at its leaf, or never in book, is left alone.
  List<MoveAnnotation> markTheoryBoundary(List<MoveAnnotation> annotations) {
    var last = -1;
    for (var i = 0; i < annotations.length; i++) {
      if ((annotations[i].gameCount ?? 0) > 0) last = i;
    }
    if (last < 0 || last == annotations.length - 1) return annotations;
    return [
      for (var i = 0; i < annotations.length; i++)
        i == last ? annotations[i].withLastBookMove() : annotations[i],
    ];
  }

  MoveAnnotation annotateOpponentMove(
    BuildTreeNode position,
    BuildTreeNode child,
  ) {
    final (likelihood, source) = _likelihoodOf(child);
    final mistake = _mistakeOf(position, child);
    return MoveAnnotation(
      likelihood: likelihood,
      likelihoodSource: source,
      gameCount: child.totalGames > 0 ? child.totalGames : null,
      practicalScore: _practicalScore(child),
      evalCp: child.hasEngineEval ? child.evalForUs(playAsWhite) : null,
      expectimaxValue: child.hasExpectimax ? child.expectimaxValue : null,
      mistakeCp: mistake?.lossCp,
      betterMoveSan: mistake?.better?.moveSan,
      // The ease of the position the opponent was choosing from is what says
      // whether this move was easy to find — not the ease of where it lands.
      opponentEase: position.ease,
      lastPlayedYear: child.lastPlayedYear > 0 ? child.lastPlayedYear : null,
    );
  }

  /// How much [child] gives away at [position], when that reaches
  /// [MoveAnnotation.kMistakeCp].  The bar is the position's own eval — the
  /// engine's best play for them — because a bad reply is often the only
  /// reply the tree stored, so the best *sibling* is frequently missing.  The
  /// better move is named only when a stored sibling actually holds the
  /// position (is within the mistake margin of the bar).
  ({int lossCp, BuildTreeNode? better})? _mistakeOf(
    BuildTreeNode position,
    BuildTreeNode child,
  ) {
    if (!child.hasEngineEval || !position.hasEngineEval) return null;
    final bar = position.evalForUs(playAsWhite);
    final loss = child.evalForUs(playAsWhite) - bar;
    if (loss < MoveAnnotation.kMistakeCp) return null;
    BuildTreeNode? better;
    for (final sibling in position.children) {
      if (identical(sibling, child) || !sibling.hasEngineEval) continue;
      if (better == null ||
          sibling.evalForUs(playAsWhite) < better.evalForUs(playAsWhite)) {
        better = sibling;
      }
    }
    if (better != null &&
        better.evalForUs(playAsWhite) - bar >= MoveAnnotation.kMistakeCp) {
      better = null;
    }
    return (lossCp: loss, better: better);
  }

  /// Move likelihood and where it came from.  Real game frequencies win over
  /// Maia's prediction; an engine-injected reply has no human number at all.
  (double?, MoveLikelihoodSource?) _likelihoodOf(BuildTreeNode child) {
    if (child.engineInjected) {
      return (child.moveProbability, MoveLikelihoodSource.engine);
    }
    if (child.totalGames > 0) {
      return (child.moveProbability, MoveLikelihoodSource.gameDatabase);
    }
    if (child.maiaFrequency >= 0) {
      return (child.maiaFrequency, MoveLikelihoodSource.maia);
    }
    return (child.moveProbability, MoveLikelihoodSource.maia);
  }

  double? _practicalScore(BuildTreeNode node) =>
      node.totalGames > 0 ? node.winRateFor(playAsWhite) : null;

  /// How far [selected]'s eval leads the best evaluated alternative, in
  /// centipawns.  No evaluated sibling means every alternative fell outside
  /// the build's eval-loss window, so the move leads by at least that much.
  int leadOverAlternatives(BuildTreeNode position, BuildTreeNode selected) {
    if (!selected.hasEngineEval) return 0;
    final ourEval = selected.evalForUs(playAsWhite);
    int? bestAlt;
    for (final sibling in position.children) {
      if (identical(sibling, selected) || !sibling.hasEngineEval) continue;
      final value = sibling.evalForUs(playAsWhite);
      if (bestAlt == null || value > bestAlt) bestAlt = value;
    }
    final lead = bestAlt == null ? maxEvalLossCp : ourEval - bestAlt;
    return lead < 0 ? 0 : lead;
  }
}
