/// Value types of the generation session: the few derived facts they carry.
library;

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_session_types.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/line_pruner.dart';
import 'package:flutter_test/flutter_test.dart';

const _line = ExtractedLine(
  movesSan: ['e4', 'e5'],
  movesUci: ['e2e4', 'e7e5'],
  probability: 0.5,
);

void main() {
  group('GenerationRequest', () {
    test('lineKey is the space-joined SAN sequence', () {
      expect(GenerationRequest.lineKey(['e4', 'e5', 'Nf3']), 'e4 e5 Nf3');
      expect(GenerationRequest.lineKey(const []), '');
      // The key distinguishes move orders: that is its whole job.
      expect(
        GenerationRequest.lineKey(['e4', 'e5']),
        isNot(GenerationRequest.lineKey(['e5', 'e4'])),
      );
    });

    test('a fresh build has no tree, no known lines, and exports', () {
      const request = GenerationRequest(
        jobLabel: 'Test generation',
        config: TreeBuildConfig(startFen: 'x', playAsWhite: true),
        repertoireFilePath: '/r.pgn',
        buildRootFen: 'x',
        lineMovePrefix: [],
        repertoireStartFen: 'x',
        onPublished: _ignore,
      );
      expect(request.existingTree, isNull);
      expect(request.existingLineKeys, isEmpty);
      expect(request.expectimaxOnly, isFalse);
    });
  });

  group('ExtractedLines', () {
    test('wasPruned compares against the pre-pruning count', () {
      const kept = ExtractedLines(
        lines: [_line, _line],
        rawCount: 2,
        trapsOnlyNote: '',
      );
      const pruned = ExtractedLines(
        lines: [_line],
        rawCount: 2,
        trapsOnlyNote: '',
      );
      expect(kept.wasPruned, isFalse);
      expect(pruned.wasPruned, isTrue);
      expect(kept.folds, isEmpty);
    });

    test('foldedCount sums sidelines over every host', () {
      const fold = FoldedLine(line: _line, divergePly: 1, hostRank: 0);
      const lines = ExtractedLines(
        lines: [_line],
        rawCount: 4,
        trapsOnlyNote: '',
        folds: {
          'e4 e5': [fold, fold],
          'd4 d5': [fold],
        },
      );
      expect(lines.foldedCount, 3);
      expect(
        const ExtractedLines(
          lines: [],
          rawCount: 0,
          trapsOnlyNote: '',
        ).foldedCount,
        0,
      );
    });
  });

  group('GenerationRequest.resolveLinePrefix', () {
    const afterE4 =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

    BuildTree partial(String rootFen, {String startMoves = ''}) => BuildTree(
      root: BuildTreeNode(
        fen: rootFen,
        moveSan: '',
        moveUci: '',
        ply: 0,
        isWhiteToMove: true,
        nodeId: 0,
      ),
      startMoves: startMoves,
    );

    GenerationRequest resuming(BuildTree tree) => GenerationRequest(
      jobLabel: 'Test generation',
      config: const TreeBuildConfig(startFen: afterE4, playAsWhite: true),
      repertoireFilePath: '/r.pgn',
      buildRootFen: afterE4,
      lineMovePrefix: const ['e4'],
      repertoireStartFen: kStandardStartFen,
      onPublished: _ignore,
      existingTree: tree,
    );

    test('a fresh build uses the caller\'s prefix', () {
      const request = GenerationRequest(
        jobLabel: 'Test generation',
        config: TreeBuildConfig(startFen: 'x', playAsWhite: true),
        repertoireFilePath: '/r.pgn',
        buildRootFen: 'x',
        lineMovePrefix: ['e4', 'c5'],
        repertoireStartFen: 'x',
        onPublished: _ignore,
      );
      expect(request.resolveLinePrefix(), ['e4', 'c5']);
    });

    test('a resumed build trusts the prefix recorded on the tree', () {
      final request = resuming(partial(afterE4, startMoves: 'd4  d5'));
      expect(request.resolveLinePrefix(), ['d4', 'd5']);
    });

    test('a legacy tree resumes only from its own position', () {
      expect(resuming(partial(afterE4)).resolveLinePrefix(), ['e4']);
      expect(
        () => resuming(partial(kStandardStartFen)).resolveLinePrefix(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot resume'),
          ),
        ),
      );
    });
  });

  group('ExpectimaxProbeTarget', () {
    const target = ExpectimaxProbeTarget(
      repertoireFilePath: '/r.pgn',
      repertoireStartFen: 'x',
      movesFromStart: ['e4'],
      plies: 4,
      playAsWhite: true,
    );

    test('keeps its optional move and threads', () {
      expect(target.moveSan, isNull);
      expect(target.engineThreads, isNull);
      expect(target.moves, ['e4']);
    });

    test('moves include the move to play first', () {
      const withMove = ExpectimaxProbeTarget(
        repertoireFilePath: '/r.pgn',
        repertoireStartFen: 'x',
        movesFromStart: ['e4'],
        moveSan: 'c5',
        plies: 4,
        playAsWhite: false,
      );
      expect(withMove.moves, ['e4', 'c5']);
    });

    test('probeConfig keeps only what scores the position', () {
      const base = TreeBuildConfig(
        startFen: 'base',
        playAsWhite: false,
        verifyFinal: true,
        trapsOnly: true,
        downloadMasterGamesIfMissing: true,
        timeBudgetMinutes: 30,
      );
      const withCores = ExpectimaxProbeTarget(
        repertoireFilePath: '/r.pgn',
        repertoireStartFen: 'x',
        movesFromStart: ['e4'],
        plies: 3,
        playAsWhite: true,
        engineThreads: 1,
        engineMoves: 40,
        maiaCoverage: 2,
      );

      final config = withCores.probeConfig(
        base: base,
        fen: kStandardStartFen,
        enableChessDbApi: false,
      );

      expect(config.startFen, kStandardStartFen);
      expect(config.playAsWhite, isTrue);
      expect(config.maxPly, 3);
      expect(config.boundedDatabase, isTrue);
      expect(config.ourMultipv, 20, reason: 'clamped');
      expect(config.oppMassTarget, 1, reason: 'clamped');
      expect(config.searchAlgorithm, SearchAlgorithm.pure);
      expect(config.coverMinProb, 0);
      expect(config.masterDepthBonusPlies, 0);
      expect(config.resolvedEngineThreads, 1);
      expect(config.timeBudgetMinutes, 0);
      expect(config.buildMode, BuildMode.stockfishExpectimax);
      expect(config.verifyFinal, isFalse);
      expect(config.trapsOnly, isFalse);
      expect(config.downloadMasterGamesIfMissing, isFalse);
      expect(config.enableChessDbApi, isFalse);
    });

    test('movePvConfig is the form defaults without verification', () {
      final config = target.movePvConfig(kStandardStartFen);
      expect(config.startFen, kStandardStartFen);
      expect(config.verifyFinal, isFalse);
    });

    test('an expectimax probe request exports nothing', () {
      final request = GenerationRequest.expectimaxProbe(
        config: target.movePvConfig(kStandardStartFen),
        target: target,
        buildRootFen: kStandardStartFen,
        lineMovePrefix: target.moves,
      );
      expect(request.expectimaxOnly, isTrue);
      expect(request.repertoireFilePath, '/r.pgn');
      expect(request.repertoireStartFen, 'x');
      expect(request.existingTree, isNull);
      expect(request.existingLineKeys, isEmpty);
    });
  });
}

void _ignore(PgnSnapshot _) {}
