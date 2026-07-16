import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/models/tactics_session_settings.dart';
import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';

/// Robustness coverage for the numeric-configuration surfaces on the pure
/// filter / config *models* (no filesystem, no network): out-of-range,
/// negative, zero, absurdly large, inverted (min > max), and malformed inputs
/// must clamp/validate/degrade gracefully rather than crash or corrupt state.
void main() {
  // ── SliceConfig: JSON round-trip + gap bounds ───────────────────────────
  group('SliceConfig.fromJsonString — malformed / out-of-range input', () {
    test('non-JSON garbage falls back to empty config (no throw)', () {
      final c = SliceConfig.fromJsonString('}{not json][');
      expect(c.isEmpty, isTrue, reason: 'garbage must degrade to empty slice');
      expect(c.sequenceGap, 4, reason: 'default gap survives a parse failure');
    });

    test('empty string falls back to empty config', () {
      expect(SliceConfig.fromJsonString('').isEmpty, isTrue);
      expect(SliceConfig.fromJsonString('   ').isEmpty, isTrue);
    });

    test(
      'a non-integer (double) sequenceGap degrades to empty, never throws',
      () {
        // `j['sequenceGap'] as int?` throws on a JSON double; the surrounding
        // try/catch must swallow it and return the empty default.
        final c = SliceConfig.fromJsonString('{"sequenceGap": 4.5}');
        expect(
          c.sequenceGap,
          4,
          reason: 'a double gap is rejected, falling back to the default of 4',
        );
      },
    );

    test('a string sequenceGap degrades to empty, never throws', () {
      final c = SliceConfig.fromJsonString('{"sequenceGap": "12"}');
      expect(c.sequenceGap, 4);
    });

    test(
      'negative sequenceGap round-trips verbatim (model does not clamp)',
      () {
        const cfg = SliceConfig(
          sequencePattern: 'e4 [gap] Nc6',
          sequenceGap: -7,
        );
        final restored = SliceConfig.fromJsonString(cfg.toJsonString());
        expect(
          restored.sequenceGap,
          -7,
          reason: 'gap sign is preserved; matching code must tolerate it',
        );
      },
    );

    test('absurdly large sequenceGap round-trips without overflow', () {
      const huge = 1 << 40;
      const cfg = SliceConfig(
        sequencePattern: 'e4 [gap] Nc6',
        sequenceGap: huge,
      );
      final restored = SliceConfig.fromJsonString(cfg.toJsonString());
      expect(restored.sequenceGap, huge);
    });

    test('default gap of 4 is omitted from JSON yet decodes back to 4', () {
      const cfg = SliceConfig(sequencePattern: 'e4');
      expect(cfg.toJsonString().contains('sequenceGap'), isFalse);
      expect(SliceConfig.fromJsonString(cfg.toJsonString()).sequenceGap, 4);
    });

    test('missing / null header filter list decodes to empty list', () {
      final c = SliceConfig.fromJsonString('{"headerFilters": null}');
      expect(c.headerFilters, isEmpty);
    });
  });

  group('SliceConfig.isEmpty / chipLabels — boundary strings', () {
    test('whitespace-only position + blank filters count as empty', () {
      const cfg = SliceConfig(
        positionInput: '   ',
        sequencePattern: '  ',
        headerFilters: [
          HeaderFilterConfig(
            field: 'White',
            mode: MatchMode.contains,
            value: '',
          ),
        ],
      );
      expect(cfg.isEmpty, isTrue);
    });

    test('over-long position/sequence inputs are truncated, not dropped', () {
      final long = 'a' * 500;
      final cfg = SliceConfig(positionInput: long, sequencePattern: long);
      for (final label in cfg.chipLabels) {
        expect(
          label.length,
          lessThan(60),
          reason: 'chip labels stay bounded for pathological input',
        );
      }
    });
  });

  // ── HeaderFilterConfig.fromJson — defaulting ────────────────────────────
  group('HeaderFilterConfig.fromJson — missing / unknown fields', () {
    test('unknown mode name falls back to contains', () {
      final f = HeaderFilterConfig.fromJson({
        'field': 'WhiteElo',
        'mode': 'totally-bogus-mode',
        'value': '2400',
      });
      expect(f.mode, MatchMode.contains);
    });

    test('missing keys default without throwing', () {
      final f = HeaderFilterConfig.fromJson(<String, dynamic>{});
      expect(f.field, 'Black');
      expect(f.mode, MatchMode.contains);
      expect(f.value, '');
    });
  });

  // ── AnalysisPlayerInfo: maxGames / monthsBack ───────────────────────────
  group('AnalysisPlayerInfo — count/recency numeric handling', () {
    test('rangeDescription pluralizes and tolerates 0 / 1 / negative', () {
      expect(
        const AnalysisPlayerInfo(
          platform: 'chesscom',
          username: 'a',
          maxGames: 1,
        ).rangeDescription,
        'last 1 game',
      );
      expect(
        const AnalysisPlayerInfo(
          platform: 'chesscom',
          username: 'a',
          maxGames: 0,
        ).rangeDescription,
        'last 0 games',
      );
      // A negative count is never produced by the UI (validated 1..500) but the
      // model must still render it rather than throw.
      expect(
        const AnalysisPlayerInfo(
          platform: 'chesscom',
          username: 'a',
          maxGames: -5,
        ).rangeDescription,
        'last -5 games',
      );
    });

    test('months-mode range description pluralizes at the 1 boundary', () {
      expect(
        const AnalysisPlayerInfo(
          platform: 'lichess',
          username: 'a',
          monthsBack: 1,
        ).rangeDescription,
        'last 1 month',
      );
      expect(
        const AnalysisPlayerInfo(
          platform: 'lichess',
          username: 'a',
          monthsBack: 120,
        ).rangeDescription,
        'last 120 months',
      );
    });

    test('isMonthsMode is driven solely by monthsBack being non-null', () {
      const games = AnalysisPlayerInfo(
        platform: 'chesscom',
        username: 'a',
        maxGames: 50,
      );
      const months = AnalysisPlayerInfo(
        platform: 'chesscom',
        username: 'a',
        monthsBack: 0,
      );
      expect(games.isMonthsMode, isFalse);
      // monthsBack == 0 is still "months mode" (non-null), even though 0 months
      // is a degenerate window — the caller/UI owns the >= 1 rule.
      expect(months.isMonthsMode, isTrue);
    });

    test('copyWith clamps nothing but preserves and clears correctly', () {
      const base = AnalysisPlayerInfo(
        platform: 'chesscom',
        username: 'a',
        maxGames: 100,
      );
      final neg = base.copyWith(maxGames: -1, monthsBack: -3);
      expect(neg.maxGames, -1, reason: 'copyWith stores values verbatim');
      expect(neg.monthsBack, -3);
      final cleared = neg.copyWith(clearMonthsBack: true);
      expect(cleared.monthsBack, isNull);
      expect(
        cleared.maxGames,
        -1,
        reason: 'clearing months leaves count alone',
      );
    });

    test('fromJson supplies defaults for missing numeric fields', () {
      final info = AnalysisPlayerInfo.fromJson({
        'platform': 'lichess',
        'username': 'x',
      });
      expect(info.maxGames, 100);
      expect(info.monthsBack, isNull);
      expect(info.gameCount, 0);
    });

    test('fromJson round-trips an integer maxGames', () {
      final json =
          jsonDecode(
                '{"platform":"lichess","username":"x",'
                '"maxGames":250,"gameCount":9}',
              )
              as Map<String, dynamic>;
      final info = AnalysisPlayerInfo.fromJson(json);
      expect(info.maxGames, 250);
      expect(info.gameCount, 9);
    });

    // REGRESSION GUARD (was a latent defect; now fixed): fromJson previously
    // cast numeric fields with `json['maxGames'] as int?`, which threw a
    // TypeError when the stored value decoded to a double (e.g. a hand-edited
    // or legacy metadata file holding `"maxGames": 100.5`). It now uses the
    // tolerant `(json[k] as num?)?.toInt()` idiom, matching every other config.
    test('fromJson tolerates a double maxGames (truncates to int)', () {
      final json =
          jsonDecode(
                '{"platform":"lichess","username":"x",'
                '"maxGames":100.5}',
              )
              as Map<String, dynamic>;
      late final AnalysisPlayerInfo info;
      expect(() => info = AnalysisPlayerInfo.fromJson(json), returnsNormally);
      expect(info.maxGames, 100);
    });
  });

  // ── TreeBuildConfig: the well-behaved JSON parser + derived getters ─────
  group('TreeBuildConfig.fromJson — tolerant numeric parsing', () {
    test('accepts both int and double JSON numbers for every numeric knob', () {
      final json = <String, dynamic>{
        'max_depth': 12.0, // double where an int is expected
        'max_nodes': 5000.0,
        'eval_depth': 18.0,
        'our_multipv': 3.0,
        'opp_max_children': 5.0,
        'min_eval_cp': -50.0,
        'max_eval_cp': 300.0,
        'min_probability': 0.001,
        'maia_elo': 1500.0,
      };
      final cfg = TreeBuildConfig.fromJson(json, startFen: 'startpos');
      expect(cfg.maxPly, 12);
      expect(cfg.maxNodes, 5000);
      expect(cfg.evalDepth, 18);
      expect(cfg.ourMultipv, 3);
      expect(cfg.oppMaxChildren, 5);
      expect(cfg.minEvalCp, -50);
      expect(cfg.maxEvalCp, 300);
      expect(cfg.maiaElo, 1500);
    });

    test('missing keys fall back to documented defaults', () {
      final cfg = TreeBuildConfig.fromJson(const {}, startFen: 'x');
      expect(cfg.maxPly, 20);
      expect(cfg.maxNodes, 0);
      expect(cfg.ourMultipv, 4);
      expect(cfg.oppMaxChildren, 4);
    });

    test(
      'round-trips an inverted eval window verbatim (no model validation)',
      () {
        // The model intentionally does not enforce minEvalCp <= maxEvalCp; the
        // pruning code owns that. Pin that copyWith/toJson preserve the inversion
        // so a future validator change is a visible diff here.
        const cfg = TreeBuildConfig(
          startFen: 'x',
          playAsWhite: true,
          minEvalCp: 400,
          maxEvalCp: -400,
        );
        final restored = TreeBuildConfig.fromJson(
          jsonDecode(jsonEncode(cfg.toJson())) as Map<String, dynamic>,
          startFen: 'x',
        );
        expect(restored.minEvalCp, 400);
        expect(restored.maxEvalCp, -400);
      },
    );
  });

  group('TreeBuildConfig — derived getters resist degenerate knobs', () {
    TreeBuildConfig cfg({
      int ourMultipv = 4,
      int oppMaxChildren = 4,
      int maxEvalLossCp = 50,
      int verifyDepth = 0,
      int evalDepth = 14,
      int engineThreads = 0,
      int fastAltGapCp = 30,
      SearchAlgorithm algo = SearchAlgorithm.fast,
      SelectionMode sel = SelectionMode.expectimax,
    }) => TreeBuildConfig(
      startFen: 'x',
      playAsWhite: true,
      ourMultipv: ourMultipv,
      oppMaxChildren: oppMaxChildren,
      maxEvalLossCp: maxEvalLossCp,
      verifyDepth: verifyDepth,
      evalDepth: evalDepth,
      engineThreads: engineThreads,
      fastAltGapCp: fastAltGapCp,
      searchAlgorithm: algo,
      selectionMode: sel,
    );

    test('effectiveMultipv never throws on a below-floor ourMultipv', () {
      // The clamp upper-bound guard (`ourMultipv < 2 ? 2 : ourMultipv`) exists
      // precisely so clamp(2, <2) can never throw ArgumentError. Exercise the
      // warm and cold zones for ourMultipv = 0 and a negative value.
      for (final mv in [0, 1, -5]) {
        final c = cfg(ourMultipv: mv);
        // cold zone (priority below fastColdPriority) → floored to 2
        expect(c.effectiveMultipv(0.0), 2, reason: 'cold floors to 2 (mv=$mv)');
        // warm zone (between cold and warm thresholds) → also floored to 2
        expect(
          c.effectiveMultipv(0.005),
          2,
          reason: 'warm floors to 2 (mv=$mv)',
        );
      }
    });

    test(
      'effectiveMultipv in the hot zone returns the raw configured width',
      () {
        expect(cfg(ourMultipv: 8).effectiveMultipv(0.5), 8);
        // Pure ignores zones entirely.
        expect(
          cfg(ourMultipv: 6, algo: SearchAlgorithm.pure).effectiveMultipv(0.0),
          6,
        );
      },
    );

    test(
      'effectiveOppMaxChildren substitutes a floor for <= 0 in cold zone',
      () {
        expect(cfg(oppMaxChildren: 0).effectiveOppMaxChildren(0.0), 3);
        expect(cfg(oppMaxChildren: -4).effectiveOppMaxChildren(0.0), 3);
      },
    );

    test('effectiveMaxEvalLossCp halves (rounded) in the cold zone', () {
      expect(cfg(maxEvalLossCp: 51).effectiveMaxEvalLossCp(0.0), 26);
      expect(cfg(maxEvalLossCp: 0).effectiveMaxEvalLossCp(0.0), 0);
    });

    test(
      'resolvedVerifyDepth applies the 0=auto rule and never underflows',
      () {
        expect(cfg(verifyDepth: 30).resolvedVerifyDepth, 30);
        // auto: max(evalDepth + 6, 20)
        expect(cfg(verifyDepth: 0, evalDepth: 5).resolvedVerifyDepth, 20);
        expect(cfg(verifyDepth: 0, evalDepth: 40).resolvedVerifyDepth, 46);
        // Negative evalDepth still yields the 20 floor, not a negative depth.
        expect(cfg(verifyDepth: 0, evalDepth: -100).resolvedVerifyDepth, 20);
      },
    );

    test(
      'resolvedEngineThreads clamps into [1, cores] and defaults sanely',
      () {
        expect(
          cfg(engineThreads: 0).resolvedEngineThreads,
          greaterThanOrEqualTo(1),
        );
        expect(
          cfg(engineThreads: -8).resolvedEngineThreads,
          greaterThanOrEqualTo(1),
        );
        expect(
          cfg(engineThreads: 1 << 20).resolvedEngineThreads,
          greaterThanOrEqualTo(1),
          reason: 'an absurd thread request is clamped to the core count',
        );
      },
    );

    test('rootMultipv floors a narrow fan-out at rootMultipvFloor', () {
      expect(cfg(ourMultipv: 1).rootMultipv, TreeBuildConfig.rootMultipvFloor);
      expect(cfg(ourMultipv: 25).rootMultipv, 25);
    });

    test('expandAlternative handles a non-positive gate and negative gaps', () {
      // fastAltGapCp <= 0 disables the gate entirely.
      expect(
        cfg(
          fastAltGapCp: 0,
        ).expandAlternative(gapCp: 999, altsAlreadyExpanded: 9),
        isTrue,
      );
      expect(
        cfg(
          fastAltGapCp: -10,
        ).expandAlternative(gapCp: 5, altsAlreadyExpanded: 0),
        isTrue,
      );
      // A negative gap is "closer than the incumbent" → within the window.
      expect(
        cfg(
          fastAltGapCp: 30,
        ).expandAlternative(gapCp: -5, altsAlreadyExpanded: 0),
        isTrue,
      );
    });
  });

  // ── TacticsSessionSettings: the recency (maxAgeDays) window ──────────────
  group('TacticsSessionSettings — recency window numeric edge cases', () {
    TacticsPosition posPlayedDaysAgo(int daysAgo, {String type = '??'}) {
      final d = DateTime.now().subtract(Duration(days: daysAgo));
      final date =
          '${d.year.toString().padLeft(4, '0')}.'
          '${d.month.toString().padLeft(2, '0')}.'
          '${d.day.toString().padLeft(2, '0')}';
      return TacticsPosition(
        fen: 'f',
        userMove: 'e4',
        correctLine: const ['e4'],
        mistakeType: type,
        mistakeAnalysis: '',
        positionContext: '',
        gameWhite: 'W',
        gameBlack: 'B',
        gameResult: '*',
        gameDate: date,
        gameId: 'g',
      );
    }

    test('null window (all-time) accepts arbitrarily old games', () {
      const s = TacticsSessionSettings(maxAgeDays: null);
      expect(s.accepts(posPlayedDaysAgo(100000)), isTrue);
    });

    test('a positive window keeps recent and drops stale games', () {
      const s = TacticsSessionSettings(maxAgeDays: 14);
      expect(s.accepts(posPlayedDaysAgo(0)), isTrue);
      expect(s.accepts(posPlayedDaysAgo(13)), isTrue);
      expect(s.accepts(posPlayedDaysAgo(30)), isFalse);
    });

    test('a large-but-safe window (centuries) accepts old games', () {
      // ~273 years; well inside the range where Duration(days:) is exact.
      const s = TacticsSessionSettings(maxAgeDays: 100000);
      expect(s.accepts(posPlayedDaysAgo(50000)), isTrue);
    });

    // REGRESSION GUARD (was a latent defect; now fixed): _withinAgeWindow
    // computed DateTime.now().subtract(Duration(days: maxAgeDays - 1)), and
    // Duration stores microseconds in a signed 64-bit int, so a maxAgeDays
    // beyond ~1.07e8 (≈292,000 years) overflowed and wrapped the cutoff into
    // the FUTURE, silently EXCLUDING everything. A window past a ~10,000-year
    // ceiling is now treated as "all time" (accept), which also stays clear of
    // the overflow threshold.
    test('an overflow-scale window is treated as "all time" (accept)', () {
      const s = TacticsSessionSettings(maxAgeDays: 1000000000);
      expect(
        s.accepts(posPlayedDaysAgo(1)),
        isTrue,
        reason: 'huge windows accept all history instead of overflowing',
      );
    });

    // maxAgeDays = 0 is a degenerate window: load() maps a stored 0 to null
    // ("all time"), but a direct copyWith(maxAgeDays: 0) keeps the literal 0,
    // whose cutoff (today minus (0-1) days = tomorrow) excludes even a game
    // played today. Pin this asymmetry so it stays intentional/visible.
    test("PINS: literal maxAgeDays == 0 excludes even today's games", () {
      const s = TacticsSessionSettings(maxAgeDays: 0);
      expect(
        s.accepts(posPlayedDaysAgo(0)),
        isFalse,
        reason: 'copyWith(0) != all-time; only stored-0 is remapped to null',
      );
    });

    test('a negative window degrades to "exclude all", never throws', () {
      const s = TacticsSessionSettings(maxAgeDays: -5);
      expect(s.accepts(posPlayedDaysAgo(0)), isFalse);
      expect(s.accepts(posPlayedDaysAgo(1000)), isFalse);
    });

    test('custom puzzles bypass the window regardless of its value', () {
      const s = TacticsSessionSettings(
        maxAgeDays: -5,
        mistakeTypes: {'custom'},
      );
      expect(
        s.accepts(posPlayedDaysAgo(100000, type: 'custom')),
        isTrue,
        reason: 'curation is not recency-driven for hand-made puzzles',
      );
    });

    test('a position with an unparseable date is never age-filtered', () {
      const p = TacticsPosition(
        fen: 'f',
        userMove: 'e4',
        correctLine: ['e4'],
        mistakeType: '??',
        mistakeAnalysis: '',
        positionContext: '',
        gameWhite: 'W',
        gameBlack: 'B',
        gameResult: '*',
        gameDate: '????.??.??',
        gameId: 'g',
      );
      const s = TacticsSessionSettings(maxAgeDays: 1);
      expect(s.accepts(p), isTrue);
    });

    test('copyWith(clearMaxAgeDays) wins over a supplied maxAgeDays', () {
      const s = TacticsSessionSettings(maxAgeDays: 14);
      final cleared = s.copyWith(maxAgeDays: 99, clearMaxAgeDays: true);
      expect(cleared.maxAgeDays, isNull);
    });
  });

  // ── TacticsPosition.gameDateTime: date parsing bounds ───────────────────
  group('TacticsPosition.gameDateTime — malformed date rejection', () {
    TacticsPosition withDate(String date) => TacticsPosition(
      fen: 'f',
      userMove: 'e4',
      correctLine: const ['e4'],
      mistakeType: '??',
      mistakeAnalysis: '',
      positionContext: '',
      gameWhite: 'W',
      gameBlack: 'B',
      gameResult: '*',
      gameDate: date,
      gameId: 'g',
    );

    test('rejects out-of-range month/day rather than rolling over', () {
      expect(withDate('2024.13.01').gameDateTime, isNull);
      expect(withDate('2024.00.10').gameDateTime, isNull);
      expect(withDate('2024.05.00').gameDateTime, isNull);
      expect(withDate('2024.05.32').gameDateTime, isNull);
    });

    test('rejects placeholder and non-numeric dates', () {
      expect(withDate('????.??.??').gameDateTime, isNull);
      expect(withDate('').gameDateTime, isNull);
      expect(withDate('2024-05-10').gameDateTime, isNull);
    });

    test('parses a well-formed date', () {
      expect(withDate('2024.05.10').gameDateTime, DateTime(2024, 5, 10));
    });
  });
}
