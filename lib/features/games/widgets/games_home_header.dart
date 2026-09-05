import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/list_search_field.dart';
import '../controllers/recent_games_controller.dart';
import '../models/recent_game.dart';
import '../services/rating_trend.dart';

/// One line over the games list: whose games, what the rating is, which
/// window — and the search box that narrows the list.
///
/// It used to be four lines (name, ratings, counts, books) over a strip of
/// buttons, and then one run-on muted sentence. Now the name is the anchor,
/// each rating is a labelled figure ("Blitz **2120**"), and the window sits
/// beside the search box it qualifies. Everything is a fact with a label;
/// hierarchy comes from weight and size, not colour.
class GamesHomeHeader extends StatelessWidget {
  const GamesHomeHeader({
    super.key,
    required this.controller,
    required this.onSearchChanged,
  });

  final RecentGamesController controller;
  final ValueChanged<String> onSearchChanged;

  /// The name, one step above body: the one thing on the bar that is about
  /// a person rather than a number.
  static final TextStyle _nameStyle = AppTextStyles.title.copyWith(
    fontSize: 16,
  );

  @override
  Widget build(BuildContext context) {
    final games = controller.games;
    final name = games.isEmpty
        ? controller.usernames.join(' · ')
        : games.first.myUsername;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                if (name.isNotEmpty) ...[
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _nameStyle,
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                Flexible(
                  child: Text.rich(
                    ratingsSpan(games),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text(capitalise(controller.window.label), style: AppTextStyles.muted),
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

  /// "Blitz **2120**   Rapid **2142**": one entry per (platform, speed) the
  /// user actually played in this window, most-played first. The speed is a
  /// muted label and the rating is the figure; the platform is named only
  /// when the window spans two of them. No movement figure — the header
  /// answers "what am I rated", not "how is the fortnight going".
  static TextSpan ratingsSpan(List<RecentGame> games) {
    final trends = computeRatingTrends(games);
    final multiPlatform = trends.map((t) => t.platform).toSet().length > 1;
    final children = <InlineSpan>[];
    for (final trend in trends) {
      if (children.isNotEmpty) {
        children.add(const WidgetSpan(child: SizedBox(width: 14)));
      }
      children.add(
        TextSpan(text: '${trend.speedLabel} ', style: AppTextStyles.muted),
      );
      children.add(
        TextSpan(text: '${trend.latestElo}', style: AppTextStyles.bodyStrong),
      );
      if (multiPlatform) {
        children.add(
          TextSpan(text: ' ${trend.platformLabel}', style: AppTextStyles.muted),
        );
      }
    }
    return TextSpan(children: children);
  }

  /// The window label is written for the middle of a sentence ("your last 20
  /// games"); at the head of a bar it takes a capital.
  static String capitalise(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}
