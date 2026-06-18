import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/tree_ease.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  group('Phase 2+3 integration: select then extract', () {
    test('white repertoire produces lines > 0', () {
      final t = StandardTree();
      final tree = t.toTree();
      // Wide eval window: in production the tree builder adjusts these
      // relative to root eval; for synthetic tests use permissive bounds.
      final config = const TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        selectionMode: SelectionMode.expectimax,
        minProbability: 0.01,
        minEvalCp: -9999,
        maxEvalCp: 9999,
      );

      // Phase 2
      calculateTreeEase(tree);

      final fenMap = t.toFenMap();
      final ecaCalc = ExpectimaxCalculator(config: config, fenMap: fenMap);
      ecaCalc.calculate(tree);

      final selector = RepertoireSelector(
        config: config,
        ecaCalc: ecaCalc,
        fenMap: fenMap,
      );
      final selectedCount = selector.select(tree);
      expect(selectedCount, greaterThan(0),
          reason: 'Selector should mark at least one repertoire move');

      tree.sortAllChildren();
      tree.computeMetadata();

      // Phase 3
      final extractor = LineExtractor(config: config, fenMap: fenMap);
      final lines = extractor.extract(tree);

      expect(lines, isNotEmpty,
          reason: 'Full pipeline should produce at least one line');

      for (final line in lines) {
        expect(line.movesSan, isNotEmpty);
        expect(line.probability, greaterThan(0.0));
        for (final san in line.movesSan) {
          expect(san, isNotEmpty, reason: 'No empty SAN moves');
        }
      }
    });

    test('black repertoire produces lines > 0', () {
      final t = BlackRepertoireTree();
      final tree = t.toTree();
      final config = const TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: false,
        selectionMode: SelectionMode.expectimax,
        minProbability: 0.01,
        minEvalCp: -9999,
        maxEvalCp: 9999,
      );

      calculateTreeEase(tree);

      final fenMap = t.toFenMap();
      final ecaCalc = ExpectimaxCalculator(config: config, fenMap: fenMap);
      ecaCalc.calculate(tree);

      final selector = RepertoireSelector(
        config: config,
        ecaCalc: ecaCalc,
        fenMap: fenMap,
      );
      final selectedCount = selector.select(tree);
      expect(selectedCount, greaterThan(0));

      tree.sortAllChildren();
      tree.computeMetadata();

      final extractor = LineExtractor(config: config, fenMap: fenMap);
      final lines = extractor.extract(tree);

      expect(lines, isNotEmpty,
          reason: 'Black repertoire should also produce lines');

      for (final line in lines) {
        expect(line.movesSan, isNotEmpty);
        expect(line.probability, greaterThan(0.0));
      }
    });

    test('engineOnly selection also produces extractable lines', () {
      final t = StandardTree();
      final tree = t.toTree();
      final config = const TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        selectionMode: SelectionMode.engineOnly,
        minProbability: 0.01,
        minEvalCp: -9999,
        maxEvalCp: 9999,
      );

      calculateTreeEase(tree);

      final ecaCalc = ExpectimaxCalculator(config: config);
      ecaCalc.calculate(tree);

      final selector = RepertoireSelector(config: config, ecaCalc: ecaCalc);
      selector.select(tree);

      final extractor = LineExtractor(config: config);
      final lines = extractor.extract(tree);

      expect(lines, isNotEmpty);
    });

    test('dbWinRateOnly selection with DB data produces lines', () {
      final t = StandardTree();
      t.e4.setLichessStats(500, 400, 100);
      t.d4.setLichessStats(450, 350, 200);
      t.e4e5nf3.setLichessStats(300, 250, 50);
      t.e4c5nf3.setLichessStats(200, 300, 100);

      final tree = t.toTree();
      final config = const TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        selectionMode: SelectionMode.dbWinRateOnly,
        minProbability: 0.01,
        minEvalCp: -9999,
        maxEvalCp: 9999,
      );

      calculateTreeEase(tree);

      final ecaCalc = ExpectimaxCalculator(config: config);
      ecaCalc.calculate(tree);

      final selector = RepertoireSelector(config: config, ecaCalc: ecaCalc);
      selector.select(tree);

      final extractor = LineExtractor(config: config);
      final lines = extractor.extract(tree);

      expect(lines, isNotEmpty);
    });

    test('playable selection mode produces lines', () {
      final t = StandardTree();
      t.e4.myEase = 0.8;
      t.d4.myEase = 0.6;
      t.e4e5nf3.myEase = 0.7;
      t.e4c5nf3.myEase = 0.5;
      t.d4d5c4.myEase = 0.6;
      t.d4nf6c4.myEase = 0.7;

      final tree = t.toTree();
      final config = const TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        selectionMode: SelectionMode.playable,
        minProbability: 0.01,
        minEvalCp: -9999,
        maxEvalCp: 9999,
      );

      calculateTreeEase(tree);

      final ecaCalc = ExpectimaxCalculator(config: config);
      ecaCalc.calculate(tree);

      final selector = RepertoireSelector(config: config, ecaCalc: ecaCalc);
      selector.select(tree);

      final extractor = LineExtractor(config: config);
      final lines = extractor.extract(tree);

      expect(lines, isNotEmpty);
    });
  });
}
