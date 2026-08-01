import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../controllers/recent_games_controller.dart';
import '../models/recent_game.dart';
import '../services/my_repertoire_settings.dart';
import '../services/rating_trend.dart';
import 'my_repertoires_panel.dart';

/// The top of the recent-games home: who you are, what your rating did, what
/// is left to look at, and which books your games are being checked against.
///
/// No encouragement, no coaching voice, no exclamation marks. This screen is
/// opened to train, and a greeting that congratulates you on your rating is
/// noise between you and the list. Everything here is a fact with a label.
class GamesHomeHeader extends StatelessWidget {
  const GamesHomeHeader({super.key, required this.controller});

  final RecentGamesController controller;

  @override
  Widget build(BuildContext context) {
    final games = controller.games;
    // Whose games these are, always on screen — including before the first one
    // arrives, when the list has no game to read the name off.
    final name = games.isEmpty
        ? controller.usernames.join(' · ')
        : games.first.myUsername;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (name.isNotEmpty)
            Text(
              name,
              style: AppTextStyles.body.copyWith(
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
          const SizedBox(height: 4),
          _RatingRow(games: games),
          const SizedBox(height: 4),
          Text(
            _countsLine(games),
            style: AppTextStyles.body.copyWith(
              fontSize: 13.5,
              color: AppColors.onSurfaceSoft,
            ),
          ),
          const SizedBox(height: 6),
          const MyBooksRow(),
        ],
      ),
    );
  }

  /// What the window contains, in facts. How much is left to *review* is not
  /// here — that is the review strip's job, next to the button that does it.
  static String _countsLine(List<RecentGame> games) {
    final leftBook = games
        .where(
          (g) =>
              g.deviation != null &&
              !g.deviation!.inBook &&
              !g.deviation!.bookEnded &&
              g.deviation!.byMe == true,
        )
        .length;
    return [
      '${games.length} ${games.length == 1 ? 'game' : 'games'}',
      if (leftBook > 0) '$leftBook left book',
    ].join(' · ');
  }
}

/// One entry per (platform, speed) the user actually played in this window.
///
/// Nothing is assumed about which time control that is: a bullet-only player
/// sees one bullet line, a bullet-and-rapid player sees both, and nobody sees
/// a Rapid row they never earned. The rating is labeled "Elo" because a bare
/// number next to a signed delta is ambiguous.
class _RatingRow extends StatelessWidget {
  const _RatingRow({required this.games});

  final List<RecentGame> games;

  @override
  Widget build(BuildContext context) {
    final trends = computeRatingTrends(games);
    if (trends.isEmpty) {
      return Text(
        'No rated games in this window',
        style: AppTextStyles.body.copyWith(
          fontSize: 14.5,
          color: AppColors.onSurfaceSoft,
        ),
      );
    }
    // The platform only earns a mention when the window actually spans two of
    // them; for the single-account case it is the same word on every row.
    final multiPlatform = trends.map((t) => t.platform).toSet().length > 1;
    return Wrap(
      spacing: 16,
      runSpacing: 2,
      children: [
        for (final trend in trends)
          _TrendEntry(trend: trend, showPlatform: multiPlatform),
      ],
    );
  }
}

class _TrendEntry extends StatelessWidget {
  const _TrendEntry({required this.trend, required this.showPlatform});

  final RatingTrendEntry trend;
  final bool showPlatform;

  @override
  Widget build(BuildContext context) {
    final delta = trend.delta;
    final deltaColor = !trend.hasTrend || delta == 0
        ? AppColors.onSurfaceSoft
        : (delta > 0 ? AppColors.success : AppColors.danger);
    final suffix = [
      '${trend.gameCount} ${trend.gameCount == 1 ? 'game' : 'games'}',
      if (showPlatform) trend.platformLabel,
    ].join(', ');
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '${trend.speedLabel} Elo ${trend.latestElo}',
            style: AppTextStyles.body.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (trend.hasTrend)
            TextSpan(
              text: '  ${delta >= 0 ? '+$delta' : '$delta'}',
              style: AppTextStyles.body.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: deltaColor,
              ),
            ),
          TextSpan(
            text: '  ($suffix)',
            style: AppTextStyles.body.copyWith(
              fontSize: 13.5,
              color: AppColors.onSurfaceSoft,
            ),
          ),
        ],
      ),
    );
  }
}

/// Which repertoires the deviation column is comparing against, and the way to
/// change them. On screen next to the column it explains, rather than two
/// screens away in Settings.
class MyBooksRow extends StatefulWidget {
  const MyBooksRow({super.key});

  @override
  State<MyBooksRow> createState() => _MyBooksRowState();
}

class _MyBooksRowState extends State<MyBooksRow> {
  final _settings = MyRepertoireSettings.instance;

  @override
  void initState() {
    super.initState();
    _settings.ensureLoaded();
  }

  static String _summary(List<String> paths) {
    if (paths.isEmpty) return 'not set';
    final names = [for (final p in paths) p.split(RegExp(r'[/\\]')).last];
    if (names.length <= 2) return names.join(', ');
    return '${names.take(2).join(', ')} +${names.length - 2}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final white = _settings.whitePaths;
        final black = _settings.blackPaths;
        // Change… sits immediately after the text it changes. Pushed to the far
        // right by an Expanded it read as an unrelated toolbar button — the eye
        // never connected it to the books on the left.
        return Row(
          children: [
            const Icon(
              Icons.fork_right,
              size: 16,
              color: AppColors.onSurfaceSoft,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'My books — White: ${_summary(white)} · '
                'Black: ${_summary(black)}',
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(
                  fontSize: 13.5,
                  color: white.isEmpty && black.isEmpty
                      ? AppColors.warning
                      : AppColors.onSurfaceSoft,
                ),
              ),
            ),
            TextButton(
              onPressed: () => showMyRepertoiresDialog(context),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Change…'),
            ),
            const Spacer(),
          ],
        );
      },
    );
  }
}
