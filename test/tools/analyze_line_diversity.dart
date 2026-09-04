/// How *different* are the lines the pruner keeps?
///
/// `analyze_lines.dart` answers "does each kept line teach something no other
/// kept line teaches" (yes, by construction). This asks the harder question:
/// once you have the book, how much of any given line is a re-tread of a line
/// already in it — shared prefix, shared decisions, and where the divergence
/// actually falls.
///
///   flutter test test/tools/analyze_line_diversity.dart \
///     --dart-define=TREE="…/tree.json"
library;

import 'dart:convert';
import 'dart:io';

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

Set<String> decisionsOf(ExtractedLine line) {
  final out = <String>{};
  for (final c in line.choices) {
    if (!c.isOurMove) continue;
    if (c.moveIndex >= line.movesUci.length) continue;
    out.add('${canonicalizeFen(c.fenBefore)}|${line.movesUci[c.moveIndex]}');
  }
  return out;
}

int commonPrefix(List<String> a, List<String> b) {
  final n = a.length < b.length ? a.length : b.length;
  var i = 0;
  while (i < n && a[i] == b[i]) {
    i++;
  }
  return i;
}

String pct(num v) => (100 * v).toStringAsFixed(1);

List<double> quantiles(List<double> xs) {
  final s = [...xs]..sort();
  if (s.isEmpty) return const [0, 0, 0, 0, 0];
  double q(double p) => s[(p * (s.length - 1)).round()];
  return [s.first, q(0.25), q(0.5), q(0.75), s.last];
}

void report(String label, List<double> xs, {bool asPct = false}) {
  final q = quantiles(xs);
  String f(double v) => asPct ? pct(v) : v.toStringAsFixed(2);
  stdout.writeln(
    '  $label  min ${f(q[0])}  p25 ${f(q[1])}  median ${f(q[2])}  '
    'p75 ${f(q[3])}  max ${f(q[4])}',
  );
}

void main() {
  test('line diversity', () async {
    final treeJson = await File(_treePath).readAsString();
    final data = jsonDecode(treeJson) as Map<String, dynamic>;
    final tree = deserializeTree(treeJson);
    final config = TreeBuildConfig.fromJson(
      Map<String, dynamic>.from(data['config'] as Map<String, dynamic>),
      startFen: tree.root.fen,
    ).anchoredToRoot(tree.root);

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

    final raw = LineExtractor(config: config, fenMap: fenMap).extract(tree);
    final slice = LinePruner.rank(raw);

    for (final target in const [25, 50, 100, 300, 100000]) {
      final kept = slice.take(target);
      final sets = [for (final l in kept) decisionsOf(l)];
      stdout.writeln('\n── target $target → ${kept.length} kept lines ──');

      final jac = <double>[];
      final prefixPlies = <double>[];
      final prefixShare = <double>[];
      final newShare = <double>[];
      final divergePly = <double>[];
      for (var i = 0; i < kept.length; i++) {
        var bestJ = 0.0;
        var bestPrefix = 0;
        for (var j = 0; j < kept.length; j++) {
          if (i == j) continue;
          final inter = sets[i].where(sets[j].contains).length;
          final union = sets[i].length + sets[j].length - inter;
          if (union > 0) {
            final v = inter / union;
            if (v > bestJ) bestJ = v;
          }
          final p = commonPrefix(kept[i].movesSan, kept[j].movesSan);
          if (p > bestPrefix) bestPrefix = p;
        }
        jac.add(bestJ);
        prefixPlies.add(bestPrefix.toDouble());
        final len = kept[i].movesSan.length;
        prefixShare.add(len == 0 ? 0 : bestPrefix / len);
        // Decisions in this line taught by no other kept line, and how deep
        // the first such divergence sits.
        final others = <String>{};
        for (var j = 0; j < kept.length; j++) {
          if (i != j) others.addAll(sets[j]);
        }
        final uniq = sets[i].where((d) => !others.contains(d)).length;
        newShare.add(sets[i].isEmpty ? 0 : uniq / sets[i].length);
        divergePly.add(bestPrefix.toDouble());
      }
      report('nearest-neighbour decision Jaccard  ', jac, asPct: true);
      report('longest shared move prefix (plies)  ', prefixPlies);
      report('…as a share of the line             ', prefixShare, asPct: true);
      report('decisions unique to this line (%)   ', newShare, asPct: true);

      // Where does the book actually fan out?
      for (final depth in const [4, 6, 8, 10, 12, 16]) {
        final buckets = <String, int>{};
        for (final l in kept) {
          final k = l.movesSan.take(depth).join(' ');
          buckets[k] = (buckets[k] ?? 0) + 1;
        }
        final biggest = buckets.values.fold<int>(0, (a, b) => a > b ? a : b);
        stdout.writeln(
          '  distinct first-$depth-ply move orders: ${buckets.length}'
          '  (largest bucket $biggest lines)',
        );
      }
      // How many kept lines diverge from their nearest twin only in the tail?
      var lateOnly = 0;
      for (var i = 0; i < kept.length; i++) {
        final len = kept[i].movesSan.length;
        if (len > 0 && prefixPlies[i] >= len - 2) lateOnly++;
      }
      stdout.writeln(
        '  lines whose nearest twin matches to within 2 plies of the end: '
        '$lateOnly of ${kept.length} (${pct(lateOnly / kept.length)}%)',
      );
      final lens = [for (final l in kept) l.movesSan.length.toDouble()];
      report('line length (plies)                 ', lens);
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
