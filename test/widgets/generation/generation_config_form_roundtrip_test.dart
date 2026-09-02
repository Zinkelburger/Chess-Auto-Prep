/// Drift guard for the **form half** of [TreeBuildConfig]'s field contract.
///
/// `tree_build_config_roundtrip_test.dart` pins the four sites inside the
/// config class (field list, constructor, `fromJson`, `toJson`, `copyWith`).
/// But a knob does not reach a build through JSON — it reaches it through the
/// form, which adds three more hand-kept sites:
///
///   1. a control (a `TextEditingController` or a `bool`) in the state base,
///   2. a line in `_applyInitialConfig` that seeds it from a config,
///   3. a line in `toConfig` that reads it back out.
///
/// Nothing used to guard those three. `toConfig` built a **fresh**
/// `TreeBuildConfig`, so a field missing from step 3 silently reverted to its
/// constructor default on every build started from the form — and a field
/// missing from step 2 reverted the moment the form was reopened on a saved
/// config, a preset, or `GenerationSessionController.lastConfig`. Fourteen
/// fields were in that state when this test was written: six with no mention
/// in the form at all, and eight published by the eval-sources section
/// through getters that had no matching setter.
///
/// `toConfig` now builds on the seed config with `copyWith`, so a field with
/// no control is *carried* rather than reset. These tests pin that, and pin
/// the deliberate exceptions in [_knownLossy] so a new one has to be argued
/// for in writing rather than appearing by omission.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/eval_database_settings.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/skeleton_plan.dart';
import 'package:chess_auto_prep/widgets/generation/generation_config_form.dart';

const String _startFen = kStandardStartFen;

/// Enum-valued keys, each mapped to a *different but valid* member.
///
/// Deliberately avoiding `trappy` for `selection_mode`: trappy mode widens
/// the eval window inside `toConfig` (a floor on `max_eval_loss_cp`, another
/// on `min_eval_cp`), which is a real transform rather than a lost field and
/// would mask the thing this test is looking for. It gets its own test below.
/// `db_explorer` for `build_mode` is chosen for the opposite reason: PGN file
/// paths are only carried in that mode, so any other choice would report
/// `pgn_file_paths` as lost when it is being cleared on purpose.
const Map<String, String> _enumAlternatives = {
  'search_algorithm': 'pure',
  'build_mode': 'dbExplorer',
  'selection_mode': 'playable',
  'annotation_detail': 'none',
};

/// Keys whose naive `+7` / `+0.125` mutation would land outside a clamp that
/// `toConfig` legitimately applies, mapped to a valid in-range alternative.
/// Being clamped is correct behaviour, not a lost field, so the probe value
/// has to respect the range or the test reports a false failure.
const Map<String, Object> _inRangeAlternatives = {
  // Clamped to 0.05..1.0, and stored in the form as an integer percent, so
  // the probe must be a whole number of percent.
  'line_coverage_target': 0.85,
};

/// Fields that deliberately do **not** survive the form, each with the reason.
///
/// Every entry here was confirmed against the code rather than assumed: a
/// field is only listed once its loss is a design decision the form makes on
/// purpose, not an omission.
const Map<String, String> _knownLossy = {
  // Novelties and the natural-move bias pull in opposite directions, so the
  // form zeroes this whenever novelties are on — which the probe turns on.
  // (opening_width_plies and novelty_weight are checkbox-backed but keep a
  // seed's own positive value; pinned by 'the checkbox-backed knobs' below.)
  'memorability_tolerance_cp': 'forced to 0 while novelties are on',

  // ── Owned by global settings, not by the config ──────────────────────
  // These three are read from EvalDatabaseSettings.instance at build time,
  // not from the form, and are gated behind a runtime probe for a cdb-direct
  // install that no test machine has. A config cannot dictate them.
  'enable_cdbdirect': 'read from EvalDatabaseSettings, gated on availability',
  'cdbdirect_path': 'read from EvalDatabaseSettings, gated on availability',
  'cdbdirect_read_ahead':
      'read from EvalDatabaseSettings, gated on availability',
  'batch_eval_lookups': 'gated on cdb-direct availability, which is probed',

  // ── Resolved against the host machine ────────────────────────────────
  // Same reason tree_build_config_roundtrip_test exempts it: the value is
  // clamped to this machine's core count on the way out.
  'engine_threads': 'clamped to the host core count',

  // ── Derived, not stored ──────────────────────────────────────────────
  // A getter over search_algorithm, serialized for readability. It follows
  // its source and has no independent value to lose.
  'best_first': 'derived from search_algorithm',

  // ── Not a form knob at all ───────────────────────────────────────────
  // Set per build point by PlanRunner and only ever read at ply 0, so it
  // describes one specific build root. Carrying a plan point's exclusions
  // into a hand-started build on a different root would silently narrow it.
  // Cleared explicitly by toConfig; pinned by its own test below.
  'root_reply_exclude': 'per-request, scoped to one build root',

  // ── Structured blob the generic mutator cannot express ───────────────
  // skeleton_plan is a JSON *string*; '_x' is not valid JSON so the decoder
  // correctly falls back to an empty plan. Covered structurally below.
  'skeleton_plan': 'JSON-string blob; the mutated probe is not valid JSON',
};

/// Produce a value of the same type as [value] but guaranteed different, and
/// guaranteed to survive the form's own clamping.
Object? _mutate(String key, Object? value) {
  final inRange = _inRangeAlternatives[key];
  if (inRange != null) return inRange;
  final enumAlt = _enumAlternatives[key];
  if (enumAlt != null) return enumAlt;
  if (value is bool) return !value;
  if (value is int) return value + 7;
  if (value is double) return value + 0.125;
  if (value is String) return '${value}_x';
  if (value is List) return [...value.cast<String>(), 'added.pgn'];
  return value;
}

/// A config with every serialized field moved off its default.
TreeBuildConfig _fullyMutatedConfig() {
  const original = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
  final mutated = <String, dynamic>{
    for (final entry in original.toJson().entries)
      entry.key: _mutate(entry.key, entry.value),
  };
  return TreeBuildConfig.fromJson(mutated, startFen: _startFen);
}

/// Mounts the form on [config] and returns what it reads back out.
///
/// The sub-editors (skeleton plan, eval sources, PGN sources) are seeded
/// straight from `_applyInitialConfig` into controllers the form owns, so
/// their values are readable whether or not their widgets ever mount.
Future<TreeBuildConfig> _throughForm(
  WidgetTester tester,
  TreeBuildConfig config, {
  bool playAsWhite = true,
}) async {
  final formKey = GlobalKey<GenerationConfigFormState>();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<EvalDatabaseSettings>.value(
          value: EvalDatabaseSettings.instance,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GenerationConfigForm(
              key: formKey,
              initialConfig: config,
              isGenerating: false,
              playAsWhite: playAsWhite,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return formKey.currentState!.toConfig(
    startFen: _startFen,
    playAsWhite: playAsWhite,
  );
}

/// Compares two serialized configs, ignoring [_knownLossy], and returns the
/// keys that changed.
List<String> _lostKeys(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
) {
  final lost = <String>[];
  for (final key in before.keys) {
    if (_knownLossy.containsKey(key)) continue;
    final a = before[key], b = after[key];
    final same = a is List && b is List
        ? a.length == b.length &&
              List.generate(a.length, (i) => a[i] == b[i]).every((e) => e)
        : a == b;
    if (!same) lost.add(key);
  }
  return lost;
}

void main() {
  group('config survives a trip through the form', () {
    testWidgets('every field the form does not deliberately transform', (
      tester,
    ) async {
      final seeded = _fullyMutatedConfig();
      // playAsWhite, like startFen, is a toConfig *argument* rather than a
      // form control, so the caller's value is authoritative. Drive the form
      // with the seed's own side or the mutation reads back as a lost field.
      final result = await _throughForm(
        tester,
        seeded,
        playAsWhite: seeded.playAsWhite,
      );

      final before = seeded.toJson();
      final after = result.toJson();
      final lost = _lostKeys(before, after);

      expect(
        lost,
        isEmpty,
        reason:
            'These fields did not survive the form. Each is either missing a '
            'line in _applyInitialConfig (so reopening the form reset it), '
            'missing a line in toConfig (so starting a build reset it), or a '
            'deliberate transform that belongs in _knownLossy with a reason:\n'
            '${lost.map((k) => '  $k: seeded ${before[k]}, read back ${after[k]}').join('\n')}',
      );
    });

    testWidgets('a field with no control at all is carried, not reset', (
      tester,
    ) async {
      // The six fields that had no mention anywhere in widgets/generation
      // when this test was written. They are wired into the build but have
      // no widget, so before the seed-based toConfig every one of them
      // reverted to its constructor default on the next build.
      const seed = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        maxNodes: 250000,
        maiaMinProb: 0.11,
        masterMinGames: 17,
        engineTailDepth: 22,
        improvementMinGainCp: 85,
      );

      final result = await _throughForm(tester, seed);

      expect(result.maxNodes, 250000);
      expect(result.maiaMinProb, 0.11);
      expect(result.masterMinGames, 17);
      expect(result.engineTailDepth, 22);
      expect(result.improvementMinGainCp, 85);
    });

    testWidgets('eval-source settings survive being reopened', (tester) async {
      // EvalSourcesSection published these eight through getters and had no
      // way to be told what they were, so every one reset on reopen.
      const seed = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        enableLocalChessDb: true,
        localChessDbPath: '/tmp/chessdb.db',
        enableChessDbApi: false,
        chessDbApiDailyQuota: 1234,
        chessDbApiConcurrency: 7,
        enableExtEvalSubtreeSkip: false,
        minAcceptableEvalDepth: 18,
      );

      final result = await _throughForm(tester, seed);

      expect(result.enableLocalChessDb, isTrue);
      expect(result.localChessDbPath, '/tmp/chessdb.db');
      expect(result.enableChessDbApi, isFalse);
      expect(result.chessDbApiDailyQuota, 1234);
      expect(result.chessDbApiConcurrency, 7);
      expect(result.enableExtEvalSubtreeSkip, isFalse);
      expect(result.minAcceptableEvalDepth, 18);
    });

    testWidgets('an eval depth floor of 0 stays 0 rather than becoming a cap', (
      tester,
    ) async {
      // 0 means "no floor" and is shown as an empty field, so it is the one
      // value whose display is not its number. Round-tripping it through the
      // empty string must not turn it into the eval depth.
      const seed = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        minAcceptableEvalDepth: 0,
        evalDepth: 26,
      );

      final result = await _throughForm(tester, seed);

      expect(result.minAcceptableEvalDepth, 0);
      expect(result.evalDepth, 26);
    });
  });

  group('the deliberate transforms', () {
    testWidgets('the checkbox-backed knobs keep a seed\'s own value', (
      tester,
    ) async {
      // Any positive width means "wide opening on"; the checkbox says
      // whether to widen, not by how much, so a planner or preset value
      // survives the trip. Same shape for the novelty weight.
      const wide = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        openingWidthPlies: 10,
        noveltyWeight: 25,
      );
      final wideResult = await _throughForm(tester, wide);
      expect(wideResult.openingWidthPlies, 10);
      expect(wideResult.noveltyWeight, 25);

      const narrow = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        openingWidthPlies: 0,
        noveltyWeight: 0,
      );
      final narrowResult = await _throughForm(tester, narrow);
      expect(narrowResult.openingWidthPlies, 0);
      expect(narrowResult.noveltyWeight, 0);
    });

    testWidgets('an unseeded form writes the checkbox defaults', (
      tester,
    ) async {
      final formKey = GlobalKey<GenerationConfigFormState>();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<EvalDatabaseSettings>.value(
              value: EvalDatabaseSettings.instance,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: GenerationConfigForm(
                  isGenerating: false,
                  playAsWhite: false,
                  key: formKey,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final config = formKey.currentState!.toConfig(
        startFen: _startFen,
        playAsWhite: false,
      );
      // Wide opening on, novelties off — the form's own defaults.
      expect(config.openingWidthPlies, 3);
      expect(config.noveltyWeight, 0);
      // Same eval window as for White: the numbers are root offsets.
      expect(config.minEvalCp, -100);
      expect(config.maxEvalCp, 200);
    });

    testWidgets('novelties zero the memorability tolerance, and only then', (
      tester,
    ) async {
      const withNovelties = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        noveltyWeight: 60,
        memorabilityToleranceCp: 40,
      );
      expect(
        (await _throughForm(tester, withNovelties)).memorabilityToleranceCp,
        0,
      );

      const without = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        noveltyWeight: 0,
        memorabilityToleranceCp: 40,
      );
      expect(
        (await _throughForm(tester, without)).memorabilityToleranceCp,
        40,
        reason: 'the tolerance is only ignored while novelties are on',
      );
    });

    testWidgets('trappy mode widens the eval window rather than losing it', (
      tester,
    ) async {
      const seed = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        selectionMode: SelectionMode.trappy,
        maxEvalLossCp: 30,
        minEvalCp: 0,
      );

      final result = await _throughForm(tester, seed);

      expect(result.selectionMode, SelectionMode.trappy);
      expect(
        result.maxEvalLossCp,
        100,
        reason: 'trappy lines cost material; a 30cp guard rejects all of them',
      );
      expect(result.minEvalCp, -100);
    });

    testWidgets('a user-set window wider than the trappy floor is kept', (
      tester,
    ) async {
      const seed = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        selectionMode: SelectionMode.trappy,
        maxEvalLossCp: 250,
        minEvalCp: -400,
      );

      final result = await _throughForm(tester, seed);

      expect(result.maxEvalLossCp, 250);
      expect(result.minEvalCp, -400);
    });

    testWidgets('PGN paths are kept in db-explorer mode and cleared outside', (
      tester,
    ) async {
      const inMode = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        buildMode: BuildMode.dbExplorer,
        pgnFilePaths: ['/tmp/a.pgn', '/tmp/b.pgn'],
      );
      expect((await _throughForm(tester, inMode)).pgnFilePaths, [
        '/tmp/a.pgn',
        '/tmp/b.pgn',
      ]);

      const outOfMode = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        buildMode: BuildMode.stockfishExpectimax,
        pgnFilePaths: ['/tmp/a.pgn'],
      );
      expect(
        (await _throughForm(tester, outOfMode)).pgnFilePaths,
        isEmpty,
        reason: 'only db-explorer builds may consume the sources panel files',
      );
    });

    testWidgets('a retired build mode falls back instead of crashing', (
      tester,
    ) async {
      // Old snapshots may carry trapFinder, which the dropdown no longer
      // offers; an unlisted value would trip the dropdown's assert.
      const seed = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        buildMode: BuildMode.trapFinder,
      );

      final result = await _throughForm(tester, seed);

      expect(result.buildMode, BuildMode.stockfishExpectimax);
    });

    testWidgets('a plan point\'s reply exclusions do not leak into the form', (
      tester,
    ) async {
      // PlanRunner sets this per build point, and node_expander only reads it
      // at ply 0. Carrying it out of the form would silently narrow a
      // hand-started build on a completely different root.
      const seed = TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: true,
        rootReplyExclude: ['e5', 'c5'],
      );

      final result = await _throughForm(tester, seed);

      expect(result.rootReplyExclude, isEmpty);
    });

    testWidgets('a skeleton plan survives structurally', (tester) async {
      // Built through fromLines because that is the shape the card holds:
      // it edits the source text and re-parses, so a plan with no source
      // lines has nothing to load back.
      final plan = SkeletonPlan.fromLines(
        const ['1.d4 Nf6 2.c4 c5 3.d5 b5'],
        playAsWhite: false,
        features: const [PawnOnSquare(square: 'd5')],
      );
      final seed = const TreeBuildConfig(
        startFen: _startFen,
        playAsWhite: false,
      ).copyWith(skeletonPlan: plan);

      final result = await _throughForm(tester, seed, playAsWhite: false);

      expect(result.skeletonPlan.nodes.length, plan.nodes.length);
      expect(result.skeletonPlan.features.length, 1);
    });
  });

  group('an unseeded form', () {
    testWidgets('reads back its own declared defaults', (tester) async {
      final formKey = GlobalKey<GenerationConfigFormState>();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<EvalDatabaseSettings>.value(
              value: EvalDatabaseSettings.instance,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: GenerationConfigForm(
                  isGenerating: false,
                  playAsWhite: true,
                  key: formKey,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final config = formKey.currentState!.toConfig(
        startFen: _startFen,
        playAsWhite: true,
      );

      // The form's declared defaults, which differ from the constructor's in
      // exactly the places TreeBuildConfig.formDefaults documents.
      expect(config.maxEvalLossCp, 30);
      // The same as TreeBuildConfig.formDefaults for both colours: the
      // window is an offset from the root eval, and a White floor of 0 used
      // to prune every position a centipawn below the start.
      expect(config.minEvalCp, -100);
      expect(config.maxEvalCp, 200);
      expect(config.maxPly, 20);
      // ...and the fields with no control fall back to the constructor's.
      expect(config.maxNodes, 0);
      expect(config.masterMinGames, 3);
    });
  });
}
