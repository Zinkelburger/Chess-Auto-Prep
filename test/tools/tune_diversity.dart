/// Sweep [LineDiversity] settings against a real built tree.
///
///   flutter test test/tools/tune_diversity.dart --dart-define=TREE="…/tree.json"
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

Set<String> decisionsOf(ExtractedLine line) => line.taughtDecisions;

double median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

void main() {
  test('diversity sweep', () async {
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
    stdout.writeln('raw extracted lines: ${raw.length}\n');

    const settings = <(String, LineDiversity)>[
      ('off', LineDiversity.off),
      ('overlap .7', LineDiversity(maxOverlap: 0.7)),
      ('overlap .6', LineDiversity(maxOverlap: 0.6)),
      ('overlap .5', LineDiversity(maxOverlap: 0.5)),
      ('share .15', LineDiversity(minNewShare: 0.15)),
      ('share .25', LineDiversity(minNewShare: 0.25)),
      ('share .40', LineDiversity(minNewShare: 0.40)),
      ('standard .25/.7', LineDiversity.standard),
      ('.15/.7', LineDiversity(minNewShare: 0.15, maxOverlap: 0.7)),
      ('.25/.5', LineDiversity(minNewShare: 0.25, maxOverlap: 0.5)),
      ('.40/.5', LineDiversity(minNewShare: 0.40, maxOverlap: 0.5)),
    ];

    stdout.writeln(
      'setting            kept  fold  drop  cover%  medJac  med%uniq  tailTwin%',
    );
    for (final (name, d) in settings) {
      final slice = LinePruner.rank(raw, diversity: d);
      final kept = slice.all;
      final sets = [for (final l in kept) decisionsOf(l)];
      final jac = <double>[];
      final uniq = <double>[];
      var tailTwin = 0;
      for (var i = 0; i < kept.length; i++) {
        var best = 0.0;
        var bestPrefix = 0;
        for (var j = 0; j < kept.length; j++) {
          if (i == j) continue;
          final inter = sets[i].where(sets[j].contains).length;
          final union = sets[i].length + sets[j].length - inter;
          if (union > 0 && inter / union > best) best = inter / union;
          var p = 0;
          final lim = kept[i].movesSan.length < kept[j].movesSan.length
              ? kept[i].movesSan.length
              : kept[j].movesSan.length;
          while (p < lim && kept[i].movesSan[p] == kept[j].movesSan[p]) {
            p++;
          }
          if (p > bestPrefix) bestPrefix = p;
        }
        jac.add(best);
        final others = <String>{};
        for (var j = 0; j < kept.length; j++) {
          if (i != j) others.addAll(sets[j]);
        }
        uniq.add(
          sets[i].isEmpty
              ? 0
              : sets[i].where((d) => !others.contains(d)).length /
                    sets[i].length,
        );
        if (bestPrefix >= kept[i].movesSan.length - 2) tailTwin++;
      }
      stdout.writeln(
        '${name.padRight(18)}'
        '${kept.length.toString().padLeft(4)}  '
        '${slice.foldedCount.toString().padLeft(4)}  '
        '${slice.droppedCount.toString().padLeft(4)}  '
        '${(100 * slice.coverageAt(slice.length)).toStringAsFixed(1).padLeft(6)}  '
        '${(100 * median(jac)).toStringAsFixed(0).padLeft(6)}  '
        '${(100 * median(uniq)).toStringAsFixed(0).padLeft(8)}  '
        '${(100 * tailTwin / (kept.isEmpty ? 1 : kept.length)).toStringAsFixed(0).padLeft(9)}',
      );
    }

    // What a fold actually looks like, for the standard setting.
    final slice = LinePruner.rank(raw, diversity: LineDiversity.standard);
    final folds = slice.foldsFor(slice.length);
    stdout.writeln('\nhosts carrying folds: ${folds.length}');
    final sizes = [for (final f in folds.values) f.length]..sort();
    if (sizes.isNotEmpty) {
      stdout.writeln(
        'folds per host: min ${sizes.first} median ${sizes[sizes.length ~/ 2]} '
        'max ${sizes.last}',
      );
    }
    var shown = 0;
    for (final entry in folds.entries) {
      if (shown++ >= 3) break;
      stdout.writeln('\nhost: ${entry.key}');
      for (final f in entry.value.take(3)) {
        stdout.writeln(
          '  @ply ${f.divergePly}: '
          '${f.line.movesSan.sublist(f.divergePly).join(' ')}'
          '  (${(100 * f.line.probability).toStringAsFixed(2)}%)',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
