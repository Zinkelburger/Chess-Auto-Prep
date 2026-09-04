/// Transposition census for a built tree: how many positions the build
/// merged, how much of extraction is re-walks of already-extracted subtrees,
/// and whether the extraction cap is ever in play.
///
///   flutter test test/tools/analyze_transpositions.dart \
///     --dart-define=TREE="…/tree.json"
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/line_pruner.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/tree_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_my_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:flutter_test/flutter_test.dart';

const _treePath = String.fromEnvironment('TREE');

void main() {
  test('transposition census', () async {
    final sw = Stopwatch()..start();
    final treeJson = await File(_treePath).readAsString();
    final data = jsonDecode(treeJson) as Map<String, dynamic>;
    final tree = deserializeTree(treeJson);
    final config = TreeBuildConfig.fromJson(
      Map<String, dynamic>.from(data['config'] as Map<String, dynamic>),
      startFen: tree.root.fen,
    ).anchoredToRoot(tree.root);

    // Census of the raw tree.
    var nodes = 0, leaves = 0;
    final byFen = <String, List<BuildTreeNode>>{};
    void walk(BuildTreeNode n) {
      nodes++;
      if (n.children.isEmpty) leaves++;
      (byFen[canonicalizeFen(n.fen)] ??= []).add(n);
      n.children.forEach(walk);
    }

    walk(tree.root);
    final multi = byFen.values.where((l) => l.length > 1).toList();
    final expandedTwins = multi
        .where((l) => l.where((n) => n.children.isNotEmpty).length > 1)
        .toList();
    stdout.writeln(
      'nodes $nodes  leaves $leaves  distinct positions ${byFen.length}',
    );
    stdout.writeln(
      'positions reached by >1 node: ${multi.length} '
      '(${multi.fold<int>(0, (a, l) => a + l.length - 1)} duplicate nodes)',
    );
    stdout.writeln(
      'positions with >1 EXPANDED copy (double expansion): '
      '${expandedTwins.length}',
    );
    var dupExpandedNodes = 0;
    for (final l in expandedTwins) {
      final sizes =
          l.where((n) => n.children.isNotEmpty).map(_subtreeSize).toList()
            ..sort();
      dupExpandedNodes += sizes.take(sizes.length - 1).fold(0, (a, b) => a + b);
    }
    stdout.writeln(
      '  nodes inside the redundant expanded copies: $dupExpandedNodes',
    );

    calculateTreeEase(tree);
    final fenMap = FenMap()..populate(tree.root);
    final eca = ExpectimaxCalculator(config: config, fenMap: fenMap);
    eca.calculate(tree);
    eca.computeTrapScores(tree.root);
    calculateMyEase(tree, playAsWhite: config.playAsWhite);
    RepertoireSelector(
      config: config,
      ecaCalc: eca,
      fenMap: fenMap,
    ).select(tree);
    tree.sortAllChildren();
    tree.computeMetadata();

    final extractor = LineExtractor(config: config, fenMap: fenMap);
    final t0 = sw.elapsedMilliseconds;
    final lines = extractor.extract(tree);
    final tExtract = sw.elapsedMilliseconds - t0;
    final capped = extractor.extract(tree, maxLines: 1 << 30).length;
    stdout.writeln(
      '\nextracted lines: ${lines.length} in ${tExtract}ms '
      '(uncapped: $capped; default cap 10000 ${capped > 10000 ? "HIT" : "not hit"})',
    );

    // How many lines pass through a transposition leaf (a childless node
    // whose canonical lives elsewhere)?  Re-derive from the line's choices:
    // a choice whose fenBefore belongs to a node that is not the canonical.
    var viaTransposition = 0;
    for (final l in lines) {
      var through = false;
      for (final c in l.choices) {
        final canon = fenMap.getCanonical(c.fenBefore);
        final twins = byFen[canonicalizeFen(c.fenBefore)]!;
        if (canon != null && twins.length > 1 && canon.children.isNotEmpty) {
          // Could be the canonical's own path; we can't tell from the choice
          // alone, so count distinct full-line duplicates below instead.
          through = true;
        }
      }
      if (through) viaTransposition++;
    }
    stdout.writeln(
      'lines passing through a merged position: $viaTransposition',
    );

    // Exact duplicate *suffix* structure: group lines by (leaf FEN).  Lines
    // ending in the same leaf position via different move orders are the
    // re-walks.
    final byLeaf = <String, int>{};
    for (final l in lines) {
      final k = canonicalizeFen(l.leafFen ?? '');
      byLeaf[k] = (byLeaf[k] ?? 0) + 1;
    }
    final distinctLeaves = byLeaf.length;
    stdout.writeln(
      'distinct leaf positions: $distinctLeaves  '
      '=> ${lines.length - distinctLeaves} lines are re-walks to an already '
      'reached leaf',
    );

    final t1 = sw.elapsedMilliseconds;
    final slice = LinePruner.rank(lines);
    final pruned = slice.all;
    stdout.writeln(
      'ranker: ${lines.length} -> ${pruned.length} lines that teach something '
      '(${(slice.coverageAt(slice.length) * 100).toStringAsFixed(1)}% coverage) '
      'in ${sw.elapsedMilliseconds - t1}ms',
    );
    final prunedLeaves = {
      for (final l in pruned) canonicalizeFen(l.leafFen ?? ''),
    };
    stdout.writeln(
      'kept lines sharing a leaf position with another kept line: '
      '${pruned.length - prunedLeaves.length}',
    );
  }, timeout: const Timeout(Duration(minutes: 20)));
}

int _subtreeSize(BuildTreeNode n) =>
    1 + n.children.fold(0, (a, c) => a + _subtreeSize(c));
