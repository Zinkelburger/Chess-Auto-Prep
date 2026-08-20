import 'dart:convert';

import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// `TreeBuildConfig.toJson()` is a **persisted** format, not an internal
/// detail. It is written to `<repertoire>_tree.json`, to the partial-tree file
/// a paused build resumes from, and to user-saved generation presets — all of
/// which are read back by `fromJson` days or months later.
///
/// These tests exist so that restructuring the config (for example nesting its
/// ~70 flat fields into sub-config objects, which is a tempting readability
/// change) fails loudly here instead of silently breaking every preset and
/// every resumable build already on disk.

const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// Every key the persisted format is expected to carry. Removing or renaming
/// one is a breaking change to files already written; adding one is safe
/// because `fromJson` defaults every field.
const expectedKeys = <String>{
  // 'annotate_maia_only' was deliberately dropped: it chose between Maia and
  // the Lichess Explorer as the annotation source, and the Explorer path no
  // longer exists.  An older build reading a newer tree defaults it to true
  // (Maia only), which is what the pipeline now always does — so the removal
  // loses nothing.
  //
  // The remaining Lichess Explorer knobs went the same way for the same
  // reason: 'use_lichess_db', 'use_masters', 'rating_range', 'speeds',
  // 'min_games' and 'maia_only'.  Nothing in the generation pipeline read any
  // of them — they were carried through the config, serialized, and ignored.
  // An older build reading a newer tree defaults each to the value the
  // pipeline already behaved as if it had, so no resume or preset changes
  // meaning.
  'alternative_lines',
  'annotate_move_probabilities',
  'annotation_detail',
  'batch_eval_lookups',
  'best_first',
  'build_mode',
  'cdbdirect_path',
  'cdbdirect_read_ahead',
  'chessdb_api_concurrency',
  'chessdb_api_daily_quota',
  'cover_min_prob',
  'db_min_games',
  'db_min_prob',
  'download_master_games_if_missing',
  'enable_cdbdirect',
  'enable_chessdb_api',
  'enable_ext_eval_subtree_skip',
  'enable_local_chessdb',
  'engine_threads',
  'eval_depth',
  'fast_alt_gap_cp',
  'improvement_min_gain_cp',
  'leaf_confidence',
  'local_chessdb_path',
  'maia_elo',
  'maia_min_prob',
  'maia_prior_games',
  'master_depth_bonus_plies',
  'master_min_games',
  'master_priority_weight',
  'max_depth',
  'max_eval_cp',
  'max_eval_loss_cp',
  'max_lines_per_chapter',
  'max_nodes',
  'memorability_tolerance_cp',
  'min_acceptable_eval_depth',
  'min_elo',
  'min_eval_cp',
  'min_lines_per_chapter',
  'min_probability',
  'model_game_count',
  'model_game_min_elo',
  'off_book_opp_max_children',
  'novelty_weight',
  'opening_width_plies',
  'organize_into_chapters',
  'opp_mass_target',
  'opp_max_children',
  'opp_policy_temperature',
  'our_alt_discount',
  'our_multipv',
  'pgn_file_paths',
  'play_as_white',
  'rank_lines_by_importance',
  'refutation_lines',
  'relative_eval',
  'search_algorithm',
  'selection_mode',
  'engine_tail_depth',
  'engine_tail_plies',
  'line_coverage_target',
  'setup_moves',
  'skeleton_plan',
  'setup_tolerance_cp',
  'target_line_count',
  'time_budget_minutes',
  'traps_only',
  'use_master_games',
  'verify_depth',
  'verify_final',
};

TreeBuildConfig config({
  bool playAsWhite = true,
  SearchAlgorithm searchAlgorithm = SearchAlgorithm.fast,
  SelectionMode selectionMode = SelectionMode.expectimax,
  BuildMode buildMode = BuildMode.stockfishExpectimax,
}) => TreeBuildConfig(
  startFen: startFen,
  playAsWhite: playAsWhite,
  searchAlgorithm: searchAlgorithm,
  selectionMode: selectionMode,
  buildMode: buildMode,
);

void main() {
  group('the persisted shape', () {
    test('is flat — no nested objects a resume could not read', () {
      final json = config().toJson();
      for (final entry in json.entries) {
        expect(
          entry.value,
          isNot(isA<Map>()),
          reason:
              'nesting "${entry.key}" changes the on-disk format; existing '
              'presets and partial builds would no longer load',
        );
      }
    });

    test('carries exactly the expected keys', () {
      expect(config().toJson().keys.toSet(), expectedKeys);
    });

    test('survives a real JSON encode/decode round trip', () {
      final decoded =
          jsonDecode(jsonEncode(config().toJson())) as Map<String, dynamic>;
      final restored = TreeBuildConfig.fromJson(decoded, startFen: startFen);
      expect(restored.maxPly, config().maxPly);
      expect(restored.playAsWhite, config().playAsWhite);
    });
  });

  group('round trip preserves the settings a resumed build depends on', () {
    test('scalar knobs survive', () {
      final original = config();
      final restored = TreeBuildConfig.fromJson(
        original.toJson(),
        startFen: startFen,
      );
      expect(restored.maxPly, original.maxPly);
      expect(restored.maxNodes, original.maxNodes);
      expect(restored.minProbability, original.minProbability);
      expect(restored.timeBudgetMinutes, original.timeBudgetMinutes);
      expect(restored.evalDepth, original.evalDepth);
      expect(restored.maxEvalLossCp, original.maxEvalLossCp);
      expect(restored.coverMinProb, original.coverMinProb);
      expect(restored.verifyFinal, original.verifyFinal);
      expect(restored.targetLineCount, original.targetLineCount);
      expect(restored.trapsOnly, original.trapsOnly);
    });

    test('every enum survives every value', () {
      for (final algorithm in SearchAlgorithm.values) {
        final restored = TreeBuildConfig.fromJson(
          config(searchAlgorithm: algorithm).toJson(),
          startFen: startFen,
        );
        expect(restored.searchAlgorithm, algorithm);
      }
      for (final mode in SelectionMode.values) {
        final restored = TreeBuildConfig.fromJson(
          config(selectionMode: mode).toJson(),
          startFen: startFen,
        );
        expect(restored.selectionMode, mode);
      }
      for (final mode in BuildMode.values) {
        final restored = TreeBuildConfig.fromJson(
          config(buildMode: mode).toJson(),
          startFen: startFen,
        );
        expect(restored.buildMode, mode);
      }
    });

    test('playing Black survives', () {
      final restored = TreeBuildConfig.fromJson(
        config(playAsWhite: false).toJson(),
        startFen: startFen,
      );
      expect(restored.playAsWhite, isFalse);
    });
  });

  group('forward and backward compatibility', () {
    test('an empty map loads as defaults rather than throwing', () {
      expect(
        () => TreeBuildConfig.fromJson(const {}, startFen: startFen),
        returnsNormally,
      );
    });

    test('an unknown key from a newer build is ignored', () {
      final json = config().toJson()..['some_future_knob'] = 42;
      final restored = TreeBuildConfig.fromJson(json, startFen: startFen);
      expect(restored.maxPly, config().maxPly);
    });

    test('a pre-enum config falls back to best_first', () {
      // Files written before search_algorithm existed carry only best_first.
      final legacyFast = TreeBuildConfig.fromJson(const {
        'best_first': true,
      }, startFen: startFen);
      expect(legacyFast.searchAlgorithm, SearchAlgorithm.fast);

      final legacyPure = TreeBuildConfig.fromJson(const {
        'best_first': false,
      }, startFen: startFen);
      expect(legacyPure.searchAlgorithm, SearchAlgorithm.pure);
    });

    test('best_first is still emitted for older builds reading new trees', () {
      expect(config().toJson().containsKey('best_first'), isTrue);
      expect(
        config(searchAlgorithm: SearchAlgorithm.pure).toJson()['best_first'],
        isFalse,
      );
      expect(
        config(searchAlgorithm: SearchAlgorithm.fast).toJson()['best_first'],
        isTrue,
      );
    });

    test('an unparsable enum value degrades to the default, not a throw', () {
      final restored = TreeBuildConfig.fromJson(const {
        'selection_mode': 'no_such_mode',
        'build_mode': 'no_such_mode',
        'search_algorithm': 'no_such_algorithm',
      }, startFen: startFen);
      expect(restored.selectionMode, SelectionMode.expectimax);
      expect(restored.buildMode, BuildMode.stockfishExpectimax);
      expect(restored.searchAlgorithm, SearchAlgorithm.fast);
    });
  });
}
