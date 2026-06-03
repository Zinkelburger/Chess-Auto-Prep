import 'tactics_position.dart';

/// How positions are ordered within a session.
enum TacticsSessionOrder {
  newestFirst,
  leastReviewed,
  worstSuccessRate,
  random,
}

/// Filtering and ordering configuration for a tactics training session.
class TacticsSessionSettings {
  const TacticsSessionSettings({
    this.order = TacticsSessionOrder.newestFirst,
    this.includeOneStar = false,
    this.skipReviewed = false,
    this.mistakeTypes = const {'??', '?'},
  });

  final TacticsSessionOrder order;

  /// Whether to include positions the user rated 1 star (excluded by default).
  final bool includeOneStar;

  /// When true, positions with `reviewCount > 0` are excluded so only
  /// unreviewed positions appear in the session.
  final bool skipReviewed;

  /// Which mistake types to include. Subset of `{'??', '?', '?!'}`.
  final Set<String> mistakeTypes;

  /// Returns `true` when [pos] should be included in a session with these
  /// settings.
  bool accepts(TacticsPosition pos) {
    if (!includeOneStar && pos.rating == 1) return false;
    if (skipReviewed && pos.reviewCount > 0) return false;
    if (!mistakeTypes.contains(pos.mistakeType)) return false;
    return true;
  }

  /// Count how many positions in [all] pass the filter.
  int countMatching(List<TacticsPosition> all) =>
      all.where(accepts).length;

  TacticsSessionSettings copyWith({
    TacticsSessionOrder? order,
    bool? includeOneStar,
    bool? skipReviewed,
    Set<String>? mistakeTypes,
  }) {
    return TacticsSessionSettings(
      order: order ?? this.order,
      includeOneStar: includeOneStar ?? this.includeOneStar,
      skipReviewed: skipReviewed ?? this.skipReviewed,
      mistakeTypes: mistakeTypes ?? this.mistakeTypes,
    );
  }
}
