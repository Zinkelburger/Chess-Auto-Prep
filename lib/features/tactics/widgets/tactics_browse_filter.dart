/// What the browse list is showing: the chips, the sort, and the search box,
/// as one value.
///
/// The filter bar used to take each of these as its own constructor argument
/// with its own change callback — six values and four callbacks, which had to
/// be kept in step by hand with the predicate that actually did the
/// filtering. Here the value and the predicate are the same object, so a new
/// filter is one `copyWith` and the bar has one `onChanged`.
library;

import 'package:flutter/foundation.dart';

import '../models/tactics_position.dart';
import '../../../widgets/common/list_search_field.dart' show matchesSearch;

/// How positions are sorted in the browse list.
enum TacticsBrowseSort {
  newest('Newest first'),
  oldest('Oldest first'),
  worstSuccess('Worst success'),
  leastReviewed('Least reviewed');

  const TacticsBrowseSort(this.label);
  final String label;
}

/// Review-status filter for the browse list.
enum TacticsStatusFilter {
  all('All'),
  newOnly('New'),
  struggling('Struggling');

  const TacticsStatusFilter(this.label);
  final String label;
}

@immutable
class TacticsBrowseFilter {
  const TacticsBrowseFilter({
    this.types = defaultTypes,
    this.status = TacticsStatusFilter.all,
    this.sort = TacticsBrowseSort.newest,
    this.minRating = 0,
    this.tags = const {},
    this.search = '',
  });

  /// Every mistake type, which is what an unfiltered list shows.
  static const Set<String> defaultTypes = {'??', '?', '?!', 'custom'};

  /// Mistake types to include.
  final Set<String> types;

  final TacticsStatusFilter status;
  final TacticsBrowseSort sort;

  /// Minimum star rating; 0 shows every rating, including unrated.
  final int minRating;

  /// Flaw tags a tactic must carry — *all* of them (empty = no tag filter).
  final Set<String> tags;

  /// Free-text match over players, date and the move played.
  final String search;

  TacticsBrowseFilter copyWith({
    Set<String>? types,
    TacticsStatusFilter? status,
    TacticsBrowseSort? sort,
    int? minRating,
    Set<String>? tags,
    String? search,
  }) => TacticsBrowseFilter(
    types: types ?? this.types,
    status: status ?? this.status,
    sort: sort ?? this.sort,
    minRating: minRating ?? this.minRating,
    tags: tags ?? this.tags,
    search: search ?? this.search,
  );

  /// [types] with [type] flipped in or out.
  TacticsBrowseFilter toggleType(String type) => copyWith(
    types: types.contains(type)
        ? (types.toSet()..remove(type))
        : (types.toSet()..add(type)),
  );

  /// [tags] with [tag] flipped in or out; an empty [tag] clears them all.
  TacticsBrowseFilter toggleTag(String tag) {
    if (tag.isEmpty) return copyWith(tags: const {});
    final next = tags.toSet();
    if (!next.remove(tag)) next.add(tag);
    return copyWith(tags: next);
  }

  bool accepts(TacticsPosition pos) {
    if (!types.contains(pos.mistakeType)) return false;
    if (minRating > 0 && pos.rating < minRating) return false;
    if (tags.isNotEmpty && !tags.every(pos.flawTags.contains)) return false;
    // Only build the haystack when there is a needle — the concat per
    // position per pass showed up as pure garbage-churn with no search.
    if (search.isNotEmpty &&
        !matchesSearch(
          search,
          '${pos.gameWhite} ${pos.gameBlack} ${pos.gameDate} ${pos.userMove}',
        )) {
      return false;
    }
    return switch (status) {
      TacticsStatusFilter.all => true,
      TacticsStatusFilter.newOnly => pos.reviewCount == 0,
      TacticsStatusFilter.struggling =>
        pos.reviewCount > 0 && pos.successRate < 0.5,
    };
  }

  /// Indices into [positions] that pass, in display order.
  List<int> apply(List<TacticsPosition> positions) {
    final indices = <int>[
      for (int i = 0; i < positions.length; i++)
        if (accepts(positions[i])) i,
    ];
    switch (sort) {
      case TacticsBrowseSort.newest:
        // File order is newest-last; reverse for newest-first display.
        return indices.reversed.toList();
      case TacticsBrowseSort.oldest:
        // File order is already oldest-first; keep as-is.
        return indices;
      case TacticsBrowseSort.worstSuccess:
        return indices..sort(
          (a, b) =>
              positions[a].successRate.compareTo(positions[b].successRate),
        );
      case TacticsBrowseSort.leastReviewed:
        return indices..sort(
          (a, b) =>
              positions[a].reviewCount.compareTo(positions[b].reviewCount),
        );
    }
  }
}
