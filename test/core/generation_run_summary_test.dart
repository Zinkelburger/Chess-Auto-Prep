// The wording of a finished run's one-sentence outcome.

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_run_summary.dart';
import 'package:chess_auto_prep/core/generation_session_types.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/course/chapter_titles.dart';
import 'package:chess_auto_prep/services/generation/course/course_composer.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

const _none = (refutations: 0, alternatives: 0, improvements: 0);

ChapterOutline _lines(String name, int entries) =>
    ChapterOutline(name: name, entryCount: entries, kind: ChapterKind.lines);

ChapterOutline _games(int entries) => ChapterOutline(
  name: 'Model games',
  entryCount: entries,
  kind: ChapterKind.modelGames,
);

void main() {
  group('courseNote', () {
    test('is silent for a flat export with nothing added', () {
      expect(courseNote(const [], _none), '');
      expect(courseNote([_lines('a', 3)], _none), '');
    });

    test('names chapters, model games and enrichment counts', () {
      expect(
        courseNote([_lines('a', 3), _lines('b', 2), _games(6)], _none),
        ' in 2 chapters plus 6 model games',
      );
      expect(
        courseNote([_lines('a', 3), _games(2)], _none),
        ' with 2 model games',
      );
      expect(
        courseNote(
          [_lines('a', 3)],
          (refutations: 2, alternatives: 1, improvements: 3),
        ),
        ', 2 punished replies, 1 refuted alternatives, '
        '3 improvements on master games',
      );
    });
  });

  group('bookSourceNote', () {
    test('is empty when ChessDB was never consulted', () {
      expect(bookSourceNote(BuildStats()), '');
    });

    test('reports the database share and dead ends', () {
      final stats = BuildStats()
        ..bookDbMoveHits = 3
        ..bookEngineFallbacks = 1
        ..bookDeadEnds = 2;
      expect(
        bookSourceNote(stats),
        'ChessDB named 3 positions and the engine 1 (75% ChessDB), '
        '2 lines ended with no move available.',
      );
    });
  });

  group('composeRunSummary', () {
    const config = TreeBuildConfig(
      startFen: kStandardStartFen,
      playAsWhite: true,
    );
    const line = ExtractedLine(
      movesSan: ['e4', 'e5'],
      movesUci: ['e2e4', 'e7e5'],
      probability: 0.5,
    );

    TreeAnalysis analysis(BuildTree tree) {
      final fenMap = FenMap()..populate(tree.root);
      return TreeAnalysis(
        fenMap: fenMap,
        ecaCalc: ExpectimaxCalculator(config: config, fenMap: fenMap),
        easeCount: 1,
        ecaCount: 1,
        selectedCount: 4,
      );
    }

    BuildTree tree({required bool complete}) => BuildTree(
      root: BuildTreeNode(
        fen: kStandardStartFen,
        moveSan: '',
        moveUci: '',
        ply: 0,
        isWhiteToMove: true,
        nodeId: 0,
      ),
      totalNodes: 12,
      buildComplete: complete,
    );

    test('a complete run states counts, pruning and duplicates', () {
      final built = tree(complete: true);
      final summary = composeRunSummary(
        tree: built,
        analysis: analysis(built),
        extracted: const ExtractedLines(
          lines: [line],
          rawCount: 3,
          trapsOnlyNote: '',
        ),
        config: config,
        elapsed: const Duration(seconds: 65),
        duplicatesSkipped: 1,
        courseOutline: const [],
        enrichment: _none,
        modelGameNote: '',
        bookStats: BuildStats(),
        finishedEarly: false,
      );
      expect(
        summary,
        'Complete in 1m 05s: 12 nodes, 4 repertoire moves, 1 lines '
        '(pruned from 3). 1 line already in the repertoire was not '
        'written again.',
      );
    });

    test('an early finish is called incomplete and skips verification', () {
      final built = tree(complete: false);
      final summary = composeRunSummary(
        tree: built,
        analysis: analysis(built),
        extracted: const ExtractedLines(
          lines: [line, line],
          rawCount: 2,
          trapsOnlyNote: ' Traps only: 2 of 2 lines run through a trap.',
        ),
        config: config.copyWith(
          verifyFinal: true,
          buildMode: BuildMode.dbExplorer,
        ),
        elapsed: const Duration(seconds: 5),
        duplicatesSkipped: 0,
        courseOutline: [_lines('a', 1), _lines('b', 1)],
        enrichment: _none,
        modelGameNote: ' No model games matched.',
        bookStats: BuildStats(),
        finishedEarly: true,
      );
      expect(summary, startsWith('Incomplete search in 5s: 12 nodes'));
      expect(summary, contains(' in 2 chapters.'));
      expect(summary, contains('Traps only: 2 of 2'));
      expect(summary, contains('No model games matched.'));
      expect(summary, endsWith('Verification skipped (finished early).'));
    });
  });
}
