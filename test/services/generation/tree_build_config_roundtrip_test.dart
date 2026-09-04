import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/skeleton_plan.dart';

/// Drift guard for [TreeBuildConfig]'s five-place field contract.
///
/// The class carries ~60 knobs, and adding one means editing the field list,
/// the constructor, `fromJson`, `toJson` and `copyWith` — five places, with
/// nothing but discipline holding them together. A field forgotten in
/// `fromJson` silently reverts to its default every time a saved config is
/// reloaded; forgotten in `toJson` it never persists at all. Both failures are
/// invisible at the call site and survive every existing test.
///
/// Rather than enumerate the fields (a list that would drift in exactly the
/// same way), these tests drive the serialized map generically: take a real
/// config's JSON, change *every* value, round-trip it, and require the result
/// to have kept every change.
const String _startFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// Keys whose values are enum names — mutating these to arbitrary strings
/// would hit the parsers' `default:` fallback and look like a lost field, so
/// each maps to a *different but valid* member of its own enum.
const Map<String, String> _enumAlternatives = {
  'search_algorithm': 'pure',
  'build_mode': 'dbExplorer',
  'selection_mode': 'engineOnly',
  'annotation_detail': 'none',
};

/// Keys deliberately exempt from the round-trip identity check.
const Map<String, String> _knownLossy = {
  // toJson writes `resolvedEngineThreads` — the value clamped to *this*
  // machine's core count — rather than the raw field, so the 0 = "auto"
  // sentinel does not survive a save. That is intentional: a resumed build
  // reuses the thread count it was actually built with instead of silently
  // re-resolving to a different number on different hardware.
  'engine_threads': 'serialized as the resolved value, not the raw sentinel',
  // skeleton_plan is a JSON *string* blob (a nested object flattened to keep
  // the persisted config flat). The generic mutator appends '_x', which is not
  // valid JSON, so the decoder correctly falls back to an empty plan. A real
  // structured round-trip is asserted in the dedicated test below and in
  // skeleton_plan_test.dart.
  'skeleton_plan': 'JSON-string blob; mutated probe is not valid JSON',
};

/// Produce a value of the same type as [value] but guaranteed different.
Object? _mutate(String key, Object? value) {
  final enumAlt = _enumAlternatives[key];
  if (enumAlt != null) return enumAlt;
  if (value is bool) return !value;
  if (value is int) return value + 7;
  if (value is double) return value + 0.125;
  if (value is String) return '${value}_x';
  if (value is List) return [...value.cast<String>(), 'added.pgn'];
  return value;
}

void main() {
  group('TreeBuildConfig serialization contract', () {
    test('every serialized field survives a toJson → fromJson round-trip', () {
      const original = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
      final baseline = original.toJson();

      // Change every single value, so a field dropped from either direction
      // shows up as a value that reverted to the original.
      final mutated = <String, dynamic>{
        for (final entry in baseline.entries)
          entry.key: _mutate(entry.key, entry.value),
      };

      final restored = TreeBuildConfig.fromJson(
        mutated,
        startFen: _startFen,
      ).toJson();

      final lost = <String>[];
      for (final key in mutated.keys) {
        if (_knownLossy.containsKey(key)) continue;
        // Lists compare by identity in Dart, so compare their contents.
        final before = mutated[key], after = restored[key];
        final same = before is List && after is List
            ? before.length == after.length &&
                  List.generate(
                    before.length,
                    (i) => before[i] == after[i],
                  ).every((e) => e)
            : before == after;
        if (!same) lost.add(key);
      }

      expect(
        lost,
        isEmpty,
        reason:
            'These keys did not survive the round-trip. Each is either missing '
            'from fromJson (so it reset to its default) or written by toJson '
            'under a different key than fromJson reads:\n'
            '${lost.map((k) => '  $k: wrote ${mutated[k]}, read back ${restored[k]}').join('\n')}',
      );
    });

    test('annotation_detail accepts every one of its own names', () {
      // The enum alternative above is only meaningful if the parser really
      // round-trips names; a silent fallback would hide a lost field.
      for (final detail in MoveAnnotationDetail.values) {
        final json = const TreeBuildConfig(
          startFen: _startFen,
          playAsWhite: true,
        ).toJson()..['annotation_detail'] = detail.name;
        final parsed = TreeBuildConfig.fromJson(json, startFen: _startFen);
        expect(parsed.annotationDetail, detail);
      }
    });

    test('startFen is supplied out of band, not through the map', () {
      const config = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
      expect(
        config.toJson().containsKey('start_fen'),
        isFalse,
        reason:
            'startFen is a required fromJson argument; serializing it too '
            'would create a second source of truth for the build root.',
      );
    });

    test('skeleton_plan survives a real structured round-trip', () {
      final plan = SkeletonPlan(
        nodes: SkeletonPlan.parseLines(const [
          '1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6',
        ], playAsWhite: false),
        features: const [
          PawnOnSquare(square: 'd5'),
          EarlyQueenTrade(),
        ],
      );
      final config = const TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: false,
      ).copyWith(skeletonPlan: plan);
      final restored = TreeBuildConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
        startFen: _startFen,
      );
      expect(restored.skeletonPlan.nodes.length, plan.nodes.length);
      expect(restored.skeletonPlan.features.length, 2);
    });
  });

  group('TreeBuildConfig copyWith contract', () {
    test('copyWith with no arguments is an exact copy', () {
      const original = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
      expect(
        jsonEncode(original.copyWith().toJson()),
        jsonEncode(original.toJson()),
      );
    });

    test('copyWith can change every serialized field', () {
      // Mirrors the round-trip test for the other mutation path: build a fully
      // mutated config through fromJson, then confirm copyWith() preserves it
      // rather than resetting fields it forgot to carry over.
      const original = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
      final mutated = <String, dynamic>{
        for (final entry in original.toJson().entries)
          entry.key: _mutate(entry.key, entry.value),
      };
      final loaded = TreeBuildConfig.fromJson(mutated, startFen: _startFen);

      // Compare through jsonEncode so list values compare structurally.
      expect(
        jsonEncode(loaded.copyWith().toJson()),
        jsonEncode(loaded.toJson()),
        reason:
            'copyWith() dropped a field: it is missing from the parameter list '
            'or from the constructor call in its body.',
      );
    });
  });

  group('the serialized key set', () {
    test('is exactly this list', () {
      // The round-trip test above drives the *serialized map*, so it can only
      // see fields toJson already writes. A field added to the class, the
      // constructor, fromJson and copyWith but forgotten in toJson has no key
      // to mutate, so it slips through every check above and simply never
      // persists — the build runs with it, the saved config does not have it,
      // and the next resume silently reverts to its default.
      //
      // Dart has no reflection to close that by construction, so this pins
      // the key set instead. Adding a knob means adding it here, which is the
      // moment to notice whether toJson writes it.
      const keys = <String>{
        'alternative_lines',
        'annotate_move_probabilities',
        'annotation_detail',
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
        'enable_lichess_evals',
        'lichess_evals_path',
        'engine_tail_depth',
        'engine_tail_plies',
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
        'master_min_move_games',
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
        'chapters_by_eco',
        'min_probability',
        'model_game_count',
        'model_game_min_elo',
        'novelty_weight',
        'off_book_opp_max_children',
        'book_tail_max_ply',
        'book_engine_fallback',
        'book_tie_break_window_cp',
        'reply_window_cp',
        'opening_width_plies',
        'opp_mass_target',
        'opp_max_children',
        'opp_policy_temperature',
        'organize_into_chapters',
        'our_alt_discount',
        'our_multipv',
        'pgn_file_paths',
        'play_as_white',
        'rank_lines_by_importance',
        'refutation_lines',
        'relative_eval',
        'search_algorithm',
        'selection_mode',
        'setup_moves',
        'setup_tolerance_cp',
        'skeleton_plan',
        'time_budget_minutes',
        'traps_only',
        'use_master_games',
        'verify_depth',
        'verify_final',
      };

      const config = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
      final actual = config.toJson().keys.toSet();

      expect(
        actual.difference(keys),
        isEmpty,
        reason:
            'New key(s) in toJson. Add them to this list, and check the same '
            'field is read by fromJson and carried by copyWith.',
      );
      expect(
        keys.difference(actual),
        isEmpty,
        reason:
            'Key(s) vanished from toJson. Renaming a persisted key without a '
            'migration silently resets that field for every saved config.',
      );
    });

    test('root_reply_exclude is written only when it has something to say', () {
      // The one conditionally-written key, which is why it is absent from the
      // set pinned above: an empty exclusion list is the overwhelmingly
      // common case and writing `[]` into every saved config is noise.
      // fromJson defaults a missing key to const [], so the two agree.
      final empty = const TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
      ).toJson();
      expect(empty.containsKey('root_reply_exclude'), isFalse);

      final populated = const TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        rootReplyExclude: ['e5', 'c5'],
      ).toJson();
      expect(populated['root_reply_exclude'], ['e5', 'c5']);

      // And it survives, so a paused plan build resumes with its own
      // exclusions rather than a widened root.
      expect(
        TreeBuildConfig.fromJson(
          populated,
          startFen: _startFen,
        ).rootReplyExclude,
        ['e5', 'c5'],
      );
      expect(
        TreeBuildConfig.fromJson(empty, startFen: _startFen).rootReplyExclude,
        isEmpty,
      );
    });
  });
}
