/// Measurement harness for line-set quality: how much of what the extractor
/// produces is genuinely distinct, and how much is the same decisions dressed
/// up in a different move order.
///
/// Loads a built `*_tree.json`, runs the real post-build pipeline, and then
/// reports on the extracted lines rather than writing any. Deliberately has
/// no `_test` suffix so a bare `flutter test` never picks it up.
///
///   flutter test test/tools/analyze_lines.dart \
///     --dart-define=TREE="…/Main_tree.json"
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

/// The decisions a line teaches: (position you face, move you play).
/// Order-free on purpose — that is what makes two transposing lines compare
/// equal here when they compare different by our-move projection.
Set<String> decisionsOf(ExtractedLine line) {
  final out = <String>{};
  for (final c in line.choices) {
    if (!c.isOurMove) continue;
    if (c.moveIndex >= line.movesUci.length) continue;
    out.add('${canonicalizeFen(c.fenBefore)}|${line.movesUci[c.moveIndex]}');
  }
  return out;
}

void main() {
  test('line-set quality', () async {
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

    final lines = LineExtractor(config: config, fenMap: fenMap).extract(tree);
    final mass = lines.fold<double>(0, (a, l) => a + l.probability);

    stdout.writeln(
      'raw extracted lines: ${lines.length}   '
      'total reach ${(100 * mass).toStringAsFixed(3)}%',
    );

    // ── How much is genuinely distinct? ──
    final allDecisions = <String>{};
    for (final l in lines) {
      allDecisions.addAll(decisionsOf(l));
    }
    final byProjection = <String, int>{};
    final bySet = <String, List<int>>{};
    for (var i = 0; i < lines.length; i++) {
      final proj = (lines[i].taughtDecisions.toList()..sort()).join(' ');
      byProjection[proj] = (byProjection[proj] ?? 0) + 1;
      final key = (decisionsOf(lines[i]).toList()..sort()).join('\n');
      (bySet[key] ??= []).add(i);
    }
    stdout.writeln(
      'distinct decisions in the whole set: ${allDecisions.length}',
    );
    stdout.writeln(
      'distinct coverage-unit sets (the pruner key): '
      '${byProjection.length}',
    );
    stdout.writeln('distinct decision SETS (order-free): ${bySet.length}');
    final twins = bySet.values.where((g) => g.length > 1).toList();
    final twinLines = twins.fold<int>(0, (a, g) => a + g.length);
    stdout.writeln(
      'lines sharing a decision set with another line: '
      '$twinLines in ${twins.length} groups',
    );

    // A line is *contained* when every decision it teaches is also taught by
    // some other single line: it can be dropped with nothing lost.
    var contained = 0;
    final sets = [for (final l in lines) decisionsOf(l)];
    for (var i = 0; i < lines.length; i++) {
      for (var j = 0; j < lines.length; j++) {
        if (i == j || sets[j].length < sets[i].length) continue;
        if (sets[i].every(sets[j].contains)) {
          contained++;
          break;
        }
      }
    }
    stdout.writeln('lines fully contained in another single line: $contained');

    // ── Coverage curve: lines needed for a share of the reach mass ──
    stdout.writeln('\ncoverage by the pruner:');
    _curve(lines, mass, (target) => LinePruner.rank(lines).take(target));

    // ── What the user is actually shown ──
    for (final target in const [300, 100000]) {
      final kept = LinePruner.rank(lines).take(target);
      final ks = [for (final l in kept) decisionsOf(l)];
      var containedKept = 0;
      for (var i = 0; i < kept.length; i++) {
        for (var j = 0; j < kept.length; j++) {
          if (i == j || ks[j].length < ks[i].length) continue;
          if (ks[i].every(ks[j].contains)) {
            containedKept++;
            break;
          }
        }
      }
      final freq = <String, int>{};
      for (final set in ks) {
        for (final d in set) {
          freq[d] = (freq[d] ?? 0) + 1;
        }
      }
      final unique = [
        for (final set in ks) set.where((d) => freq[d] == 1).length,
      ]..sort();
      stdout.writeln(
        '\nkept set at target $target -> ${kept.length} lines:'
        '\n  lines contained in another kept line : $containedKept'
        '\n  lines teaching nothing uniquely      : '
        '${unique.where((u) => u == 0).length}'
        '\n  unique decisions per line  min ${unique.first} '
        'median ${unique[unique.length ~/ 2]} max ${unique.last}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

void _curve(
  List<ExtractedLine> lines,
  double totalMass,
  List<ExtractedLine> Function(int) prune,
) {
  final sets = {for (final l in lines) l: decisionsOf(l)};
  stdout.writeln('  lines   kept   mass covered   share');
  for (final target in const [25, 50, 100, 150, 200, 250, 300, 400, 500, 800]) {
    final kept = prune(target);
    final taught = <String>{};
    for (final l in kept) {
      taught.addAll(sets[l]!);
    }
    // A line is covered when every decision in it is taught by the kept set.
    var covered = 0.0;
    for (final l in lines) {
      if (sets[l]!.every(taught.contains)) covered += l.probability;
    }
    stdout.writeln(
      '  ${target.toString().padLeft(5)}  '
      '${kept.length.toString().padLeft(5)}   '
      '${(100 * covered).toStringAsFixed(3).padLeft(9)}%   '
      '${(100 * covered / totalMass).toStringAsFixed(1).padLeft(5)}%',
    );
    if (kept.length < target) break;
  }
}
