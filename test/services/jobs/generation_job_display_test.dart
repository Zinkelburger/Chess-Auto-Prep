import 'package:chess_auto_prep/services/jobs/generation_job_display.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  group('buildGenerationStatParts (buildingTree)', () {
    test('FIFO shows depth-layer stats and a depth ETA', () {
      final parts = buildGenerationStatParts(
        phase: GenerationPhase.buildingTree,
        nodes: 1200,
        currentDepth: 9,
        maxPlyConfig: 20,
        unexploredAtDepth: 160,
        totalAtDepth: 500,
        nodesPerMinute: 300,
        etaDepthSec: 120,
        linesExtracted: 0,
      );
      expect(parts, contains('Depth 9/20'));
      expect(parts, contains('340/500 explored'));
      expect(parts, contains('depth ETA ~2m'));
      expect(parts.join(), isNot(contains('queued')));
    });

    test('best-first shows deepest ply, frontier, and whole-run ETA', () {
      final parts = buildGenerationStatParts(
        phase: GenerationPhase.buildingTree,
        nodes: 1200,
        currentDepth: 14,
        maxPlyConfig: 20,
        unexploredAtDepth: 160,
        totalAtDepth: 500,
        nodesPerMinute: 300,
        etaDepthSec: 120,
        linesExtracted: 0,
        bestFirst: true,
        frontierSize: 85,
        etaRunSec: 600,
      );
      expect(parts, contains('deepest ply 14/20'));
      expect(parts, contains('85 positions queued'));
      expect(parts, contains('ETA ~10m'));
      // Depth-layer stats are meaningless in best-first order.
      expect(parts.join(), isNot(contains('explored')));
      expect(parts.join(), isNot(contains('depth ETA')));
    });
  });

  group('generationProgressFraction', () {
    test('best-first uses the priority descent', () {
      final f = generationProgressFraction(
        phase: GenerationPhase.buildingTree,
        currentDepth: 14,
        maxPlyConfig: 20,
        unexploredAtDepth: 100,
        totalAtDepth: 500,
        bestFirst: true,
        priorityProgress: 0.62,
      );
      expect(f, 0.62);
    });

    test('best-first with no priority yet is indeterminate', () {
      final f = generationProgressFraction(
        phase: GenerationPhase.buildingTree,
        currentDepth: 0,
        maxPlyConfig: 20,
        unexploredAtDepth: 0,
        totalAtDepth: 0,
        bestFirst: true,
        priorityProgress: null,
      );
      expect(f, isNull);
    });

    test('FIFO keeps the depth-layer blend', () {
      final f = generationProgressFraction(
        phase: GenerationPhase.buildingTree,
        currentDepth: 10,
        maxPlyConfig: 20,
        unexploredAtDepth: 250,
        totalAtDepth: 500,
      );
      expect(f, closeTo((10 / 20) * 0.85 + 0.5 * 0.15, 1e-9));
    });

    test('non-build phases have no fraction', () {
      final f = generationProgressFraction(
        phase: GenerationPhase.enrichingEvals,
        currentDepth: 10,
        maxPlyConfig: 20,
        unexploredAtDepth: 0,
        totalAtDepth: 0,
        bestFirst: true,
        priorityProgress: 0.5,
      );
      expect(f, isNull);
    });
  });

  group('generationResourceLabel', () {
    test('shows the real process split and aggregate hash', () {
      const config = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        engineThreads: 10,
      );

      expect(
        generationResourceLabel(config, workers: 4),
        '4 workers × 2 threads · 8/10 CPU · '
        '512 MB hash + engine memory',
      );
    });

    test('uses singular labels for a one-core build', () {
      const config = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        engineThreads: 1,
      );

      expect(
        generationResourceLabel(config, workers: 8),
        '1 worker × 1 thread · 1/1 CPU · '
        '128 MB hash + engine memory',
      );
    });
  });
}
