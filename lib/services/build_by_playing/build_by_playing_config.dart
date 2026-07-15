/// Configuration for a Build-by-Playing session.
///
/// Branching knobs deliberately mirror [TreeBuildConfig] semantics
/// (coverMinProb / oppMassTarget / oppMaxChildren) so users who know the
/// generation settings recognise them here.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../explorer_cache_service.dart';

class BuildByPlayingConfig {
  const BuildByPlayingConfig({
    this.useMasters = false,
    this.speeds = 'blitz,rapid,classical',
    this.ratings = '2000,2200,2500',
    this.coverMinProb = 0.05,
    this.oppMassTarget = 0.80,
    this.oppMaxChildren = 4,
    this.maxPly = 20,
    this.minCumulativeProbability = 0.001,
    this.minGames = 10,
    this.startFromCurrentPosition = false,
  });

  // ── Database source ──
  final bool useMasters;
  final String speeds;
  final String ratings;

  // ── Opponent branching (TreeBuildConfig semantics) ──
  /// Any opponent reply played at least this fraction of the time gets a
  /// branch, regardless of the mass target.
  final double coverMinProb;

  /// Stop adding opponent replies once this share of games is covered.
  final double oppMassTarget;

  /// Hard cap on opponent replies branched per position.
  final int oppMaxChildren;

  // ── Line-end cutoffs ──
  /// Maximum line depth in half-moves, measured from the session root.
  final int maxPly;

  /// End a line once the product of opponent move probabilities drops
  /// below this.
  final double minCumulativeProbability;

  /// End a line when the database has fewer games than this at a position.
  final int minGames;

  // ── Session ──
  final bool startFromCurrentPosition;

  ExplorerSourceConfig get source => ExplorerSourceConfig(
        useMasters: useMasters,
        speeds: speeds,
        ratings: ratings,
      );

  BuildByPlayingConfig copyWith({
    bool? useMasters,
    String? speeds,
    String? ratings,
    double? coverMinProb,
    double? oppMassTarget,
    int? oppMaxChildren,
    int? maxPly,
    double? minCumulativeProbability,
    int? minGames,
    bool? startFromCurrentPosition,
  }) {
    return BuildByPlayingConfig(
      useMasters: useMasters ?? this.useMasters,
      speeds: speeds ?? this.speeds,
      ratings: ratings ?? this.ratings,
      coverMinProb: coverMinProb ?? this.coverMinProb,
      oppMassTarget: oppMassTarget ?? this.oppMassTarget,
      oppMaxChildren: oppMaxChildren ?? this.oppMaxChildren,
      maxPly: maxPly ?? this.maxPly,
      minCumulativeProbability:
          minCumulativeProbability ?? this.minCumulativeProbability,
      minGames: minGames ?? this.minGames,
      startFromCurrentPosition:
          startFromCurrentPosition ?? this.startFromCurrentPosition,
    );
  }
}

/// Persisted defaults for the Build-by-Playing start form.
class BuildByPlayingSettings extends ChangeNotifier {
  static const String _prefix = 'build_by_playing.';

  /// Application-wide shared instance.
  static final BuildByPlayingSettings instance =
      BuildByPlayingSettings._internal();

  /// Create an independent instance (unit tests only).
  @visibleForTesting
  BuildByPlayingSettings.fresh() : this._internal();

  BuildByPlayingSettings._internal();

  BuildByPlayingConfig _config = const BuildByPlayingConfig();
  BuildByPlayingConfig get config => _config;

  Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const def = BuildByPlayingConfig();
      _config = BuildByPlayingConfig(
        useMasters:
            prefs.getBool('${_prefix}use_masters') ?? def.useMasters,
        speeds: prefs.getString('${_prefix}speeds') ?? def.speeds,
        ratings: prefs.getString('${_prefix}ratings') ?? def.ratings,
        coverMinProb: (prefs.getDouble('${_prefix}cover_min_prob') ??
                def.coverMinProb)
            .clamp(0.0, 1.0),
        oppMassTarget: (prefs.getDouble('${_prefix}opp_mass_target') ??
                def.oppMassTarget)
            .clamp(0.0, 1.0),
        oppMaxChildren: (prefs.getInt('${_prefix}opp_max_children') ??
                def.oppMaxChildren)
            .clamp(1, 20),
        maxPly: (prefs.getInt('${_prefix}max_ply') ?? def.maxPly)
            .clamp(2, 100),
        minCumulativeProbability:
            (prefs.getDouble('${_prefix}min_cum_prob') ??
                    def.minCumulativeProbability)
                .clamp(0.0, 1.0),
        minGames:
            (prefs.getInt('${_prefix}min_games') ?? def.minGames).clamp(1, 100000),
        // startFromCurrentPosition is per-session, not persisted.
      );
      notifyListeners();
    } catch (e) {
      debugPrint('[BuildByPlayingSettings] Failed to load prefs: $e');
    }
  }

  Future<void> applyFrom(BuildByPlayingConfig config) async {
    _config = config;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('${_prefix}use_masters', config.useMasters);
      await prefs.setString('${_prefix}speeds', config.speeds);
      await prefs.setString('${_prefix}ratings', config.ratings);
      await prefs.setDouble('${_prefix}cover_min_prob', config.coverMinProb);
      await prefs.setDouble('${_prefix}opp_mass_target', config.oppMassTarget);
      await prefs.setInt('${_prefix}opp_max_children', config.oppMaxChildren);
      await prefs.setInt('${_prefix}max_ply', config.maxPly);
      await prefs.setDouble(
          '${_prefix}min_cum_prob', config.minCumulativeProbability);
      await prefs.setInt('${_prefix}min_games', config.minGames);
    } catch (e) {
      debugPrint('[BuildByPlayingSettings] Failed to save prefs: $e');
    }
  }
}
