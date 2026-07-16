import 'package:shared_preferences/shared_preferences.dart';

import 'tactics_position.dart';

/// How positions are ordered within a session.
enum TacticsSessionOrder {
  newestFirst,
  leastReviewed,
  worstSuccessRate,
  random;

  static TacticsSessionOrder fromStorage(String? value) {
    return TacticsSessionOrder.values.firstWhere(
      (o) => o.name == value,
      orElse: () => TacticsSessionOrder.newestFirst,
    );
  }
}

/// Filtering and ordering configuration for a tactics training session.
class TacticsSessionSettings {
  const TacticsSessionSettings({
    this.order = TacticsSessionOrder.newestFirst,
    this.groupByGame = true,
    this.includeOneStar = false,
    this.skipReviewed = false,
    this.mistakeTypes = const {'??', '?', customMistakeType},
    this.maxAgeDays = defaultMaxAgeDays,
  });

  /// Default recency window: positions from games older than this are
  /// filtered out ("auto-expired") unless the user widens the window.
  static const int defaultMaxAgeDays = 14;

  /// Marker mistake-type for manually created puzzles (they have no
  /// engine-graded blunder classification).
  static const String customMistakeType = 'custom';

  final TacticsSessionOrder order;

  /// When true, positions from the same game stay together and are presented
  /// in the order they occurred in that game (by move number). [order] then
  /// only decides the order *between* games. When false, positions are
  /// interleaved purely by [order].
  final bool groupByGame;

  /// Whether to include positions the user rated 1 star (excluded by default).
  final bool includeOneStar;

  /// When true, positions with `reviewCount > 0` are excluded so only
  /// unreviewed positions appear in the session.
  final bool skipReviewed;

  /// Which mistake types to include. Subset of `{'??', '?', '?!'}`.
  final Set<String> mistakeTypes;

  /// Only include positions from games played within the last [maxAgeDays]
  /// days. `null` means all time. Custom puzzles and positions without a
  /// parseable game date are never age-filtered (curation isn't
  /// recency-driven, and an unknown date shouldn't hide a puzzle).
  final int? maxAgeDays;

  /// Returns `true` when [pos] should be included in a session with these
  /// settings.
  bool accepts(TacticsPosition pos) {
    if (!includeOneStar && pos.rating == 1) return false;
    if (skipReviewed && pos.reviewCount > 0) return false;
    if (!mistakeTypes.contains(pos.mistakeType)) return false;
    if (!_withinAgeWindow(pos)) return false;
    return true;
  }

  bool _withinAgeWindow(TacticsPosition pos) {
    final days = maxAgeDays;
    if (days == null) return true;
    if (pos.mistakeType == customMistakeType) return true;
    final played = pos.gameDateTime;
    if (played == null) return true;
    // A window larger than any realistic game history means "all time". This
    // also guards Duration's signed-64-bit microsecond field from overflowing
    // (~1.07e8 days) and wrapping the cutoff into the future.
    if (days >= 3650000) return true; // ~10,000 years
    final now = DateTime.now();
    final cutoff = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: days - 1));
    return !played.isBefore(cutoff);
  }

  /// Count how many positions in [all] pass the filter.
  int countMatching(List<TacticsPosition> all) => all.where(accepts).length;

  TacticsSessionSettings copyWith({
    TacticsSessionOrder? order,
    bool? groupByGame,
    bool? includeOneStar,
    bool? skipReviewed,
    Set<String>? mistakeTypes,
    int? maxAgeDays,
    bool clearMaxAgeDays = false,
  }) {
    return TacticsSessionSettings(
      order: order ?? this.order,
      groupByGame: groupByGame ?? this.groupByGame,
      includeOneStar: includeOneStar ?? this.includeOneStar,
      skipReviewed: skipReviewed ?? this.skipReviewed,
      mistakeTypes: mistakeTypes ?? this.mistakeTypes,
      maxAgeDays: clearMaxAgeDays ? null : (maxAgeDays ?? this.maxAgeDays),
    );
  }

  static const _keyOrder = 'tactics_session.order';
  static const _keyGroupByGame = 'tactics_session.group_by_game';
  static const _keyIncludeOneStar = 'tactics_session.include_one_star';
  static const _keySkipReviewed = 'tactics_session.skip_reviewed';
  static const _keyMistakeTypes = 'tactics_session.mistake_types';
  static const _keyCustomTypeMigrated = 'tactics_session.custom_type_migrated';

  /// Stored value for [maxAgeDays]; 0 encodes "all time" (null).
  static const _keyMaxAgeDays = 'tactics_session.max_age_days';

  /// Load saved session settings, falling back to defaults for any missing key.
  static Future<TacticsSessionSettings> load() async {
    const defaults = TacticsSessionSettings();
    final prefs = await SharedPreferences.getInstance();
    var storedTypes = prefs.getStringList(_keyMistakeTypes);

    // One-time migration: type lists saved before the "custom" type existed
    // would silently hide manually created puzzles; opt them in once (the
    // user can still disable the chip afterwards).
    if (storedTypes != null &&
        !(prefs.getBool(_keyCustomTypeMigrated) ?? false)) {
      if (!storedTypes.contains(customMistakeType)) {
        storedTypes = [...storedTypes, customMistakeType];
        await prefs.setStringList(_keyMistakeTypes, storedTypes);
      }
      await prefs.setBool(_keyCustomTypeMigrated, true);
    }

    final storedMaxAge = prefs.getInt(_keyMaxAgeDays);
    return TacticsSessionSettings(
      order: TacticsSessionOrder.fromStorage(prefs.getString(_keyOrder)),
      groupByGame: prefs.getBool(_keyGroupByGame) ?? defaults.groupByGame,
      includeOneStar:
          prefs.getBool(_keyIncludeOneStar) ?? defaults.includeOneStar,
      skipReviewed: prefs.getBool(_keySkipReviewed) ?? defaults.skipReviewed,
      mistakeTypes: storedTypes != null
          ? storedTypes.toSet()
          : defaults.mistakeTypes,
      maxAgeDays: storedMaxAge == null
          ? defaults.maxAgeDays
          : (storedMaxAge <= 0 ? null : storedMaxAge),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyOrder, order.name);
    await prefs.setBool(_keyGroupByGame, groupByGame);
    await prefs.setBool(_keyIncludeOneStar, includeOneStar);
    await prefs.setBool(_keySkipReviewed, skipReviewed);
    await prefs.setStringList(_keyMistakeTypes, mistakeTypes.toList());
    await prefs.setInt(_keyMaxAgeDays, maxAgeDays ?? 0);
  }
}
