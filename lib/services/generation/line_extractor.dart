/// Line extraction from a [BuildTree] after repertoire selection.
///
/// Walks the tree following `isRepertoireMove` flags at our-move nodes and all
/// children at opponent nodes to produce complete lines, gathering per-move
/// annotations on the way out.  Ports C's `extract_lines` from `repertoire.c`.
///
/// Extraction is a pure function of the valued tree — no engine, no network —
/// which is what lets the whole of Phase 3 be unit-tested on synthetic trees.
library;

import '../../models/build_tree_node.dart';
import 'export/move_annotation.dart';
import 'fen_map.dart';
import 'generation_config.dart';

// ── Coverage unit ────────────────────────────────────────────────────────

/// One our-move a line teaches, for [LinePruner]'s greedy set cover.
///
/// [key] is the *decision itself* — canonical FEN of the position faced, plus
/// the UCI we play in it. That is what a line actually teaches: "in this
/// position, play this move." Two lines share a key whenever they put the
/// user in front of the same choice, whether they got there by the same move
/// order or a different one.
///
/// It used to be the our-move projection prefix — the space-joined UCI of our
/// moves so far — which is order-*dependent*. That caught lines answering
/// different opponent deviations with the same replies, but not the far more
/// common case of two lines transposing into one another: same positions,
/// same answers, different move order, entirely different projection strings.
/// Both survived pruning and the user was shown two lines teaching one idea.
/// On a 7.6k-node Benko tree, 490 of 2099 extracted lines shared a decision
/// set with another and 701 were wholly contained in a single other line.
///
/// [value] is the reach probability of the position it was played in, scaled
/// up when the move is an only-move (large eval gap to the best non-selected
/// sibling).
class LineCoverageUnit {
  final String key;
  final double value;

  const LineCoverageUnit({required this.key, required this.value});
}

// ── Choice point ─────────────────────────────────────────────────────────

/// A position an exported line passes through, with everything needed to ask
/// "what if a human played something else here?".
///
/// The build tree cannot answer that on its own: our-move children are all
/// inside the eval-loss window (an engine-approved alternative is a different
/// move, not a refuted one), and a reply Maia ranks below the candidate floor
/// never becomes a child at all.  So the export records the *position* and
/// what the tree already knows about it, and the alternatives pass brings its
/// own move source — see `course/refutation_prober.dart`.
class LineChoice {
  /// Index in the line's `movesSan` of the move actually played here.
  final int moveIndex;

  /// The position the move was played from.  Doubles as the dedup key: two
  /// lines sharing a prefix share this choice, and everything on it is a
  /// property of the position rather than of the branch taken.
  final String fenBefore;

  final bool isOurMove;

  /// Best eval available to the side to move here, from *our* perspective and
  /// over the tree's children — the highest for us at an our-move node, the
  /// lowest at an opponent node.  Null when no child carries an eval, which
  /// is what makes "this alternative loses N centipawns" unanswerable.
  final int? bestEvalCpForUs;

  /// Moves the tree already holds at this position.  They are either exported
  /// elsewhere or known to be inside the eval window, so neither needs an
  /// engine probe to be explained.
  final List<String> knownUcis;

  const LineChoice({
    required this.moveIndex,
    required this.fenBefore,
    required this.isOurMove,
    required this.bestEvalCpForUs,
    required this.knownUcis,
  });
}

// ── Extracted line ───────────────────────────────────────────────────────

class ExtractedLine {
  final List<String> movesSan;
  final List<String> movesUci;
  final double probability;
  final PruneReason leafPruneReason;
  final int? leafPruneEvalCp;
  final String? openingName;
  final String? openingEco;
  final int? leafEvalCp;

  /// Position the line ends in.  Anything that wants to say more about a
  /// line's end than the tree recorded — an engine probe, a lookup — starts
  /// from here.
  final String? leafFen;

  final List<MoveAnnotation> moveAnnotations;
  final List<LineCoverageUnit> coverageUnits;

  /// Every position this line passes through, in move order.
  final List<LineChoice> choices;

  const ExtractedLine({
    required this.movesSan,
    required this.movesUci,
    required this.probability,
    this.leafPruneReason = PruneReason.none,
    this.leafPruneEvalCp,
    this.openingName,
    this.openingEco,
    this.leafEvalCp,
    this.leafFen,
    this.moveAnnotations = const [],
    this.coverageUnits = const [],
    this.choices = const [],
  });

  /// The set of decisions this line teaches — "this position, this move" for
  /// every point where it is our turn. Order-free on purpose: two lines that
  /// transpose into each other teach the same thing and compare equal here.
  Set<String> get taughtDecisions => {for (final u in coverageUnits) u.key};
}

// ── Extractor ────────────────────────────────────────────────────────────

class LineExtractor {
  final TreeBuildConfig config;
  final FenMap? fenMap;

  LineExtractor({required this.config, this.fenMap});

  /// Eval gaps beyond this add no extra only-move weight.
  static const int _sharpnessCapCp = 200;

  /// An our-move this far ahead of every alternative is effectively forced.
  ///
  /// Scaled to the build's eval-loss window: the expander never stores an
  /// alternative worse than [TreeBuildConfig.maxEvalLossCp], so with the
  /// default 50cp window a fixed 100cp bar could never be met.  A stored
  /// alternative that loses most of the window is what "forced" looks like
  /// in the tree.  A move with *no* stored sibling is not called forced:
  /// the fast search narrows or skips alternatives at cold nodes, so a sole
  /// child usually means unexplored rather than only.
  static const int _onlyMoveGapCp = 100;

  int get _onlyMoveThresholdCp {
    final scaled = config.maxEvalLossCp * 4 ~/ 5;
    return scaled < _onlyMoveGapCp ? scaled : _onlyMoveGapCp;
  }

  /// Extract complete repertoire lines from the tree.
  List<ExtractedLine> extract(BuildTree tree, {int maxLines = 10000}) {
    final lines = <ExtractedLine>[];
    _extractDfs(
      node: tree.root,
      movesSan: const [],
      movesUci: const [],
      moveAnnotations: const [],
      coverageUnits: const [],
      choices: const [],
      lines: lines,
      maxLines: maxLines,
      visited: <String>{},
    );
    return lines;
  }

  void _extractDfs({
    required BuildTreeNode node,
    required List<String> movesSan,
    required List<String> movesUci,
    required List<MoveAnnotation> moveAnnotations,
    required List<LineCoverageUnit> coverageUnits,
    required List<LineChoice> choices,
    required List<ExtractedLine> lines,
    required int maxLines,
    required Set<String> visited,
  }) {
    if (lines.length >= maxLines) return;

    final resolved = resolveTransposition(node, fenMap);

    // Cycle guard: if following a transposition link re-enters a position
    // already on the current path, stop expanding and emit the line so far.
    final cycle = isTranspositionCycle(node, resolved, visited);

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    var pushedAny = false;

    if (!cycle) {
      final key = enterFenPath(resolved, visited);
      if (isOurMove) {
        final selected = resolved.children
            .where((c) => c.isRepertoireMove)
            .firstOrNull;
        if (selected != null) {
          pushedAny = true;
          final gapCp = _leadOverAlternatives(resolved, selected);
          // Keyed by the position faced rather than the path taken to it, so
          // a transposition is recognised as the same decision.
          final decisionKey =
              '${canonicalizeFen(resolved.fen)}|${selected.moveUci}';
          _extractDfs(
            node: selected,
            movesSan: [...movesSan, selected.moveSan],
            movesUci: [...movesUci, selected.moveUci],
            moveAnnotations: [
              ...moveAnnotations,
              _annotateOurMove(selected, gapCp),
            ],
            choices: [
              ...choices,
              _choiceAt(resolved, movesSan.length, isOurMove: true),
            ],
            coverageUnits: [
              ...coverageUnits,
              LineCoverageUnit(
                key: decisionKey,
                value:
                    selected.cumulativeProbability *
                    (1.0 + gapCp.clamp(0, _sharpnessCapCp) / 100.0),
              ),
            ],
            lines: lines,
            maxLines: maxLines,
            visited: visited,
          );
        }
      } else {
        for (final child in resolved.children) {
          // Coverage-floored children sit below the reach-probability floor
          // but carry a guaranteed answer — export their lines too.
          final covered =
              config.coverMinProb > 0.0 &&
              child.moveProbability >= config.coverMinProb;
          if (!covered && child.cumulativeProbability < config.minProbability) {
            continue;
          }
          pushedAny = true;
          _extractDfs(
            node: child,
            movesSan: [...movesSan, child.moveSan],
            movesUci: [...movesUci, child.moveUci],
            moveAnnotations: [
              ...moveAnnotations,
              _annotateOpponentMove(resolved, child),
            ],
            choices: [
              ...choices,
              _choiceAt(resolved, movesSan.length, isOurMove: false),
            ],
            coverageUnits: coverageUnits,
            lines: lines,
            maxLines: maxLines,
            visited: visited,
          );
        }
      }
      leaveFenPath(key, visited);
    }

    if (pushedAny || movesSan.isEmpty) return;

    final (name: openingName, eco: openingEco) = _nearestOpening(node);

    lines.add(
      ExtractedLine(
        movesSan: movesSan,
        movesUci: movesUci,
        probability: node.cumulativeProbability,
        leafPruneReason: node.pruneReason,
        leafPruneEvalCp: node.pruneEvalCp,
        openingName: openingName,
        openingEco: openingEco,
        leafEvalCp: node.engineEvalCp,
        leafFen: node.fen,
        moveAnnotations: _markTheoryBoundary(moveAnnotations),
        coverageUnits: coverageUnits,
        choices: choices,
      ),
    );
  }

  /// The choice point at [position], where the move at [moveIndex] was played.
  LineChoice _choiceAt(
    BuildTreeNode position,
    int moveIndex, {
    required bool isOurMove,
  }) {
    int? best;
    for (final child in position.children) {
      if (!child.hasEngineEval) continue;
      final value = child.evalForUs(config.playAsWhite);
      if (best == null) {
        best = value;
      } else if (isOurMove ? value > best : value < best) {
        // Our node: the best we can do.  Opponent node: the best they can do,
        // which is the worst for us — the bar an alternative has to fall below
        // before it counts as a mistake by them.
        best = value;
      }
    }
    return LineChoice(
      moveIndex: moveIndex,
      fenBefore: position.fen,
      isOurMove: isOurMove,
      bestEvalCpForUs: best,
      knownUcis: [for (final child in position.children) child.moveUci],
    );
  }

  // ── Annotation ────────────────────────────────────────────────────────

  MoveAnnotation _annotateOurMove(BuildTreeNode selected, int gapCp) {
    final isOnlyMove =
        _hasEvaluatedSibling(selected) && gapCp >= _onlyMoveThresholdCp;
    final natural = _naturalAlternative(selected);
    return MoveAnnotation(
      evalCp: selected.hasEngineEval
          ? selected.evalForUs(config.playAsWhite)
          : null,
      myEase: selected.myEase >= 0 ? selected.myEase : null,
      isOnlyMove: isOnlyMove,
      onlyMoveLeadCp: isOnlyMove ? gapCp : null,
      humanFrequency: selected.maiaFrequency >= 0
          ? selected.maiaFrequency
          : null,
      naturalAlternativeSan: natural?.moveSan,
      naturalAlternativeLossCp: natural != null && natural.hasEngineEval
          ? selected.evalForUs(config.playAsWhite) -
                natural.evalForUs(config.playAsWhite)
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
  List<MoveAnnotation> _markTheoryBoundary(List<MoveAnnotation> annotations) {
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

  MoveAnnotation _annotateOpponentMove(
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
      evalCp: child.hasEngineEval ? child.evalForUs(config.playAsWhite) : null,
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
    final bar = position.evalForUs(config.playAsWhite);
    final loss = child.evalForUs(config.playAsWhite) - bar;
    if (loss < MoveAnnotation.kMistakeCp) return null;
    BuildTreeNode? better;
    for (final sibling in position.children) {
      if (identical(sibling, child) || !sibling.hasEngineEval) continue;
      if (better == null ||
          sibling.evalForUs(config.playAsWhite) <
              better.evalForUs(config.playAsWhite)) {
        better = sibling;
      }
    }
    if (better != null &&
        better.evalForUs(config.playAsWhite) - bar >=
            MoveAnnotation.kMistakeCp) {
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
      node.totalGames > 0 ? node.winRateFor(config.playAsWhite) : null;

  /// How far [selected]'s eval leads the best evaluated alternative, in
  /// centipawns.  No evaluated sibling means every alternative fell outside
  /// the build's eval-loss window, so the move leads by at least that much.
  int _leadOverAlternatives(BuildTreeNode position, BuildTreeNode selected) {
    if (!selected.hasEngineEval) return 0;
    final ourEval = selected.evalForUs(config.playAsWhite);
    int? bestAlt;
    for (final sibling in position.children) {
      if (identical(sibling, selected) || !sibling.hasEngineEval) continue;
      final value = sibling.evalForUs(config.playAsWhite);
      if (bestAlt == null || value > bestAlt) bestAlt = value;
    }
    final lead = bestAlt == null ? config.maxEvalLossCp : ourEval - bestAlt;
    return lead < 0 ? 0 : lead;
  }

  /// Nearest named opening at or above [node], walking toward the root.
  ({String? name, String? eco}) _nearestOpening(BuildTreeNode node) {
    for (BuildTreeNode? cur = node; cur != null; cur = cur.parent) {
      if (cur.openingName != null) {
        return (name: cur.openingName, eco: cur.openingEco);
      }
    }
    return (name: null, eco: null);
  }
}
