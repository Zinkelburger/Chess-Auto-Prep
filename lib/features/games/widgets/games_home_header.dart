import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/list_search_field.dart';
import '../controllers/recent_games_controller.dart';
import '../models/recent_game.dart';
import '../services/rating_trend.dart';

/// One line over the games list: whose games, what the rating did, which
/// window — and the search box that narrows the list.
///
/// It used to be four lines (name, ratings, counts, books) over a strip of
/// buttons. The counts moved onto the buttons that act on them, in the home
/// column; the books line moved next to the accounts it belongs with. What
/// is left is the caption a list of games needs and nothing it does not.
///
/// No encouragement, no coaching voice. Everything here is a fact with a
/// label.
class GamesHomeHeader extends StatelessWidget {
  const GamesHomeHeader({
    super.key,
    required this.controller,
    required this.onSearchChanged,
  });

  final RecentGamesController controller;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    final games = controller.games;
    final name = games.isEmpty
        ? controller.usernames.join(' · ')
        : games.first.myUsername;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (name.isNotEmpty)
                    TextSpan(text: name, style: AppTextStyles.bodyStrong),
                  if (name.isNotEmpty) const TextSpan(text: '   '),
                  TextSpan(
                    text: _summary(games, controller.window.label),
                    style: AppTextStyles.muted,
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 240,
            child: ListSearchField(
              hintText: 'Search games',
              onChanged: onSearchChanged,
            ),
          ),
        ],
      ),
    );
  }

  /// "Blitz 1850 +12 · last 20 games". One entry per (platform, speed) the
  /// user actually played in this window; the platform is named only when the
  /// window spans two of them. The sign is the direction — no green-up /
  /// red-down.
  static String _summary(List<RecentGame> games, String windowLabel) {
    final trends = computeRatingTrends(games);
    final multiPlatform = trends.map((t) => t.platform).toSet().length > 1;
    final parts = <String>[
      for (final trend in trends)
        [
          trend.speedLabel,
          '${trend.latestElo}',
          if (trend.hasTrend && trend.delta != 0)
            trend.delta > 0 ? '+${trend.delta}' : '${trend.delta}',
          if (multiPlatform) '(${trend.platformLabel})',
        ].join(' '),
      windowLabel,
    ];
    return parts.join(' · ');
  }
}
