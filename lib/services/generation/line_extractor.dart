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
import '../eval/eval_canonicalize.dart';
import 'export/move_annotation.dart';
import 'fen_map.dart';
import 'generation_config.dart';

// ── Coverage unit ────────────────────────────────────────────────────────

/// One our-move a line teaches, for [LinePruner]'s greedy set cover.
///
/// [key] is the our-move projection prefix (space-joined UCI of OUR moves
/// up to and including this one, opponent moves excluded) — two lines that
/// answer different opponent deviations with the same sequence of our moves
/// share every key and are training duplicates.  [value] is the reach
/// probability of the position it was played in, scaled up when the move is
/// an only-move (large eval gap to the best non-selected sibling).
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

  /// Our moves only, as UCI — the identity of what this line actually teaches.
  /// Two lines with the same projection are training duplicates however much
  /// their opponent moves differ.
  String get ourMoveProjection =>
      coverageUnits.isEmpty ? '' : coverageUnits.last.key;
}

// ── Extractor ────────────────────────────────────────────────────────────

class LineExtractor {
  final TreeBuildConfig config;
  final FenMap? fenMap;

  LineExtractor({required this.config, this.fenMap});

  /// Eval gaps beyond this add no extra only-move weight.
  static const int _sharpnessCapCp = 200;

  /// An our-move this far ahead of every alternative is effectively forced.
  static const int _onlyMoveGapCp = 100;

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
    // Without this, a transposition that loops back produces infinite lines.
    final key = canonicalizeFen4(resolved.fen);
    final isTransposed = !identical(resolved, node);
    final cycle = isTransposed && visited.contains(key);

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    var pushedAny = false;

    if (!cycle) {
      visited.add(key);
      if (isOurMove) {
        final selected = resolved.children
            .where((c) => c.isRepertoireMove)
            .firstOrNull;
        if (selected != null) {
          pushedAny = true;
          final gapCp = _leadOverAlternatives(resolved, selected);
          final projectionKey = coverageUnits.isEmpty
              ? selected.moveUci
              : '${coverageUnits.last.key} ${selected.moveUci}';
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
                key: projectionKey,
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
      visited.remove(key);
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
        moveAnnotations: moveAnnotations,
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

  MoveAnnotation _annotateOurMove(BuildTreeNode selected, int gapCp) =>
      MoveAnnotation(
        evalCp: selected.hasEngineEval
            ? selected.evalForUs(config.playAsWhite)
            : null,
        myEase: selected.myEase >= 0 ? selected.myEase : null,
        isOnlyMove: gapCp >= _onlyMoveGapCp,
        practicalScore: _practicalScore(selected),
        gameCount: selected.totalGames > 0 ? selected.totalGames : null,
        lastPlayedYear: selected.lastPlayedYear > 0
            ? selected.lastPlayedYear
            : null,
      );

  MoveAnnotation _annotateOpponentMove(
    BuildTreeNode position,
    BuildTreeNode child,
  ) {
    final (likelihood, source) = _likelihoodOf(child);
    return MoveAnnotation(
      likelihood: likelihood,
      likelihoodSource: source,
      gameCount: child.totalGames > 0 ? child.totalGames : null,
      practicalScore: _practicalScore(child),
      evalCp: child.hasEngineEval ? child.evalForUs(config.playAsWhite) : null,
      // The ease of the position the opponent was choosing from is what says
      // whether this move was easy to find — not the ease of where it lands.
      opponentEase: position.ease,
      lastPlayedYear: child.lastPlayedYear > 0 ? child.lastPlayedYear : null,
    );
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
