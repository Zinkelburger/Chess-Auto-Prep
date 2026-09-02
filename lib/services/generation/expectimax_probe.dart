/// On-demand expectimax: the pieces that turn one small build rooted at a
/// board position into an entry in the repertoire's expectimax database.
///
/// The database is the forest of built trees for a repertoire — the tree a
/// full Generate wrote, plus every probe the user asked for from a position
/// that tree never reached. A probe that lands on a position an existing tree
/// already holds is grafted into it ([graftProbe]); one that lands elsewhere
/// becomes a tree of its own ([ExpectimaxProbeStore] persists those).
///
/// Everything here is a pure function over trees. The engine work happens in
/// the ordinary build pipeline; this file only merges and re-scores.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../models/build_tree_node.dart';
import 'build_run.dart' show findMaxNodeId;
import 'eca_calculator.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import 'tree_ease.dart';
import 'tree_my_ease.dart';
import 'tree_serialization.dart';

/// The tree among [trees] whose root is an ancestor of [node], or null when
/// [node] belongs to none of them.
BuildTree? treeOwning(BuildTreeNode node, Iterable<BuildTree> trees) {
  var top = node;
  while (top.parent != null) {
    top = top.parent!;
  }
  for (final tree in trees) {
    if (identical(tree.root, top)) return tree;
  }
  return null;
}

/// Merge [probe] into [host] under [at], whose position is the probe's root.
///
/// Children the host already has are kept and completed rather than
/// replaced: a missing eval is filled in, an unexplored node the probe
/// expanded becomes explored, and the walk continues below it. Children the
/// host lacks are cloned in with `ply`, `cumulativeProbability` and `nodeId`
/// rebased to their new place (the same bookkeeping as
/// `extractRebasedSubtree`, in the other direction). Returns how many nodes
/// were added.
///
/// [host]'s metadata is refreshed on the way out; the caller rebuilds any
/// FenMap over it, since the map is frozen once published.
int graftProbe({
  required BuildTree host,
  required BuildTreeNode at,
  required BuildTree probe,
  required bool playAsWhite,
}) {
  if (canonicalizeFen(at.fen) != canonicalizeFen(probe.root.fen)) {
    throw ArgumentError(
      'graftProbe: probe root ${probe.root.fen} is not the position at '
      '${at.fen}',
    );
  }
  var nextNodeId = findMaxNodeId(host.root) + 1;
  var added = 0;

  BuildTreeNode clone(BuildTreeNode old, BuildTreeNode parent) {
    final moveWasOpponents = old.isWhiteToMove == playAsWhite;
    final cumP = moveWasOpponents
        ? parent.cumulativeProbability * old.moveProbability
        : parent.cumulativeProbability;
    final node = BuildTreeNode(
      fen: old.fen,
      moveSan: old.moveSan,
      moveUci: old.moveUci,
      ply: parent.ply + 1,
      isWhiteToMove: old.isWhiteToMove,
      nodeId: nextNodeId++,
      parent: parent,
      moveProbability: old.moveProbability,
      cumulativeProbability: cumP,
    );
    _copyScalars(node, old);
    added++;
    for (final child in old.children) {
      node.children.add(clone(child, node));
    }
    return node;
  }

  void merge(BuildTreeNode into, BuildTreeNode from) {
    _completeFrom(into, from);
    for (final child in from.children) {
      BuildTreeNode? existing;
      for (final c in into.children) {
        if (c.moveUci == child.moveUci ||
            (c.moveUci.isEmpty && c.moveSan == child.moveSan)) {
          existing = c;
          break;
        }
      }
      if (existing == null) {
        into.children.add(clone(child, into));
      } else {
        merge(existing, child);
      }
    }
  }

  merge(at, probe.root);

  host.computeMetadata();
  host.totalNodes = host.root.subtreeSize;
  host.maxPlyReached = math.max(
    host.maxPlyReached,
    at.ply + probe.maxPlyReached,
  );
  return added;
}

/// Fill what [into] lacks from [from], never overwriting a value the host
/// already had — the host's numbers were computed in their own context.
void _completeFrom(BuildTreeNode into, BuildTreeNode from) {
  if (!into.hasEngineEval && from.hasEngineEval) {
    into.engineEvalCp = from.engineEvalCp;
    into.extEvalMode = from.extEvalMode;
  }
  if (from.explored && !into.explored) {
    into.explored = true;
    // The probe looked past whatever reason the host had for stopping here.
    into.pruneReason = from.pruneReason;
    into.pruneEvalCp = from.pruneEvalCp;
  }
  if (into.maiaFrequency < 0 && from.maiaFrequency >= 0) {
    into.maiaFrequency = from.maiaFrequency;
  }
  if (into.totalGames == 0 && from.totalGames > 0) {
    into.setLichessStats(from.whiteWins, from.blackWins, from.draws);
  }
  into.openingName ??= from.openingName;
  into.openingEco ??= from.openingEco;
  into.pvContinuationMove ??= from.pvContinuationMove;
}

void _copyScalars(BuildTreeNode node, BuildTreeNode old) {
  node
    ..engineEvalCp = old.engineEvalCp
    ..explored = old.explored
    ..pruneReason = old.pruneReason
    ..pruneEvalCp = old.pruneEvalCp
    ..openingName = old.openingName
    ..openingEco = old.openingEco
    ..maiaFrequency = old.maiaFrequency
    ..pvContinuationMove = old.pvContinuationMove
    ..engineInjected = old.engineInjected
    ..extEvalMode = old.extEvalMode
    ..ease = old.ease
    ..localCpl = old.localCpl
    ..expectimaxValue = old.expectimaxValue
    ..cplValue = old.cplValue
    ..hasExpectimax = old.hasExpectimax
    ..opponentEase = old.opponentEase
    ..trapScore = old.trapScore
    ..myEase = old.myEase;
  node.setLichessStats(old.whiteWins, old.blackWins, old.draws);
}

/// Re-run the phase-2 scoring a full build does — ease, expectimax, trap
/// scores, CPL, our ease — over [tree], so values above a graft point
/// reflect what was added below it.
///
/// Repertoire selection is deliberately *not* re-run: the ★ marks are what
/// the last Generate chose and exported, and a probe adds knowledge, not a
/// new decision. [fenMap] should span the whole database so transposition
/// leaves resolve across trees.
void rescoreTree(BuildTree tree, TreeBuildConfig config, FenMap fenMap) {
  calculateTreeEase(tree);
  final eca = ExpectimaxCalculator(config: config, fenMap: fenMap);
  eca.calculate(tree);
  eca.computeTrapScores(tree.root);
  eca.calculateCplValues(tree.root);
  calculateMyEase(tree, playAsWhite: config.playAsWhite);
}

/// Persistence for the probe trees of one repertoire:
/// `<repertoire>_expectimax.json` beside `<repertoire>_tree.json`.
class ExpectimaxProbeStore {
  static const int version = 1;

  static String pathFor(String repertoireFilePath) =>
      '${p.withoutExtension(repertoireFilePath)}_expectimax.json';

  /// Every tree serialized on its own, so each one round-trips through the
  /// same v4 format as the main tree file.
  static String encode(List<BuildTree> trees) => jsonEncode({
    'version': version,
    'trees': [for (final t in trees) serializeTree(t, indent: false)],
  });

  static List<BuildTree> decode(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final trees = data['trees'] as List<dynamic>? ?? const [];
    return [
      for (final entry in trees)
        if (entry is String) deserializeTree(entry),
    ];
  }
}
