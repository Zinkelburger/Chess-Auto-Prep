/// End-to-end: does a real build's PGN actually carry the folded sidelines?
///
/// Runs the whole post-build pipeline on a saved tree — selection, extraction,
/// ranking with the config's diversity bar, and course composition — then
/// prints what the reader would see.
///
///   flutter test test/tools/verify_folded_export.dart \
///     --dart-define=TREE="…/tree.json"
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/services/generation/course/chapter_titles.dart';
import 'package:chess_auto_prep/services/generation/course/course_composer.dart';
import 'package:chess_auto_prep/services/generation/course/opening_namer.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/line_pruner.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/tree_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_my_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:flutter_test/flutter_test.dart';

const _treePath = String.fromEnvironment('TREE');

void main() {
  test('folded lines reach the composed PGN', () async {
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
    final slice = LinePruner.rank(
      raw,
      diversity: LineDiversity.fromConfig(config),
    );
    final lines = slice.all;
    final folds = slice.foldsFor(slice.length);

    stdout.writeln(
      'config bar: minNewShare=${config.lineMinNewShare} '
      'maxOverlap=${config.lineMaxOverlap} '
      'maxFoldPlies=${config.lineMaxFoldPlies}',
    );
    stdout.writeln(
      'raw ${raw.length} -> ${lines.length} entries, '
      '${slice.foldedCount} folded, ${slice.droppedCount} dropped',
    );
    stdout.writeln(
      'coverage ${(100 * slice.coverageAt(slice.length)).toStringAsFixed(1)}% '
      'drilled / '
      '${(100 * slice.answeredCoverageAt(slice.length)).toStringAsFixed(1)}% '
      'answered',
    );

    final rootFen = tree.root.fen;
    final course = CourseComposer(
      config: config,
      namer: CourseNamer(
        namer: OpeningNamer.unavailable(startFen: rootFen),
        rootWhiteToMove: isWhiteToMove(rootFen),
        startMoveNumber: fullMoveNumber(rootFen),
        repertoirePrefix: const [],
        playAsWhite: config.playAsWhite,
      ),
      repertoireStartFen: rootFen,
      repertoirePrefix: const [],
      repertoireName: 'Verification',
    ).compose(lines: lines, folds: folds);

    // Every fold must be findable in the document it was attached to.
    final byKey = {
      for (final e in course.entries) LinePruner.lineKey(e.movesSan): e,
    };
    var found = 0;
    var missing = 0;
    for (final entry in folds.entries) {
      final game = byKey[entry.key];
      if (game == null) {
        missing += entry.value.length;
        continue;
      }
      for (final fold in entry.value) {
        final firstMove = fold.line.movesSan[fold.divergePly];
        if (game.pgn.contains('($firstMove ') ||
            game.pgn.contains(' $firstMove ') ||
            game.pgn.contains('$firstMove ')) {
          found++;
        } else {
          missing++;
          stdout.writeln('MISSING: $firstMove in ${entry.key}');
        }
      }
    }
    stdout.writeln(
      'folds present in their host game: $found, missing $missing',
    );
    expect(missing, 0);

    // The one with the most folds, in full, so the shape can be eyeballed.
    final busiest = folds.entries.reduce(
      (a, b) => a.value.length >= b.value.length ? a : b,
    );
    stdout.writeln('\n── busiest host (${busiest.value.length} folds) ──');
    stdout.writeln(byKey[busiest.key]!.pgn);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
