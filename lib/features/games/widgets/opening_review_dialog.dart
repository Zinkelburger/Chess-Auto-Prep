import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../models/recent_game.dart';
import '../services/opening_review.dart';
import 'opening_review_detail_dialog.dart';

/// All opening mistakes from the recent-games window in one place — the
/// aggregate complement of the per-game "Left book" chip, so leaks can be
/// reviewed like a tactics queue instead of by opening every game.
///
/// Each entry deep-links into the repertoire builder at the deviation point;
/// the game links open the individual games. The dialog pops itself before
/// invoking any callback (they all navigate away from the Tactics home).
class OpeningReviewDialog extends StatelessWidget {
  const OpeningReviewDialog({
    super.key,
    required this.data,
    required this.sinceDays,
    required this.onOpenLine,
    required this.onOpenGame,
    required this.onOpenSettings,
  });

  final OpeningReviewData data;
  final int sinceDays;
  final ValueChanged<OpeningReviewEntry> onOpenLine;
  final ValueChanged<RecentGame> onOpenGame;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Opening review'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: _buildBody(context)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (!data.anyBookDesignated) {
      return _buildHint(
        context,
        icon: Icons.menu_book,
        message:
            'No repertoire is designated for your games yet, so there is '
            'nothing to compare them against.\n\nPick your repertoire folders '
            'in Settings → My repertoires and this review will show every '
            'game where you left book.',
        buttonLabel: 'Open Settings',
        onPressed: () {
          Navigator.of(context).pop();
          onOpenSettings();
        },
      );
    }
    if (data.isEmpty) {
      return _buildHint(
        context,
        icon: Icons.verified_outlined,
        message:
            'You stayed in book in every game '
            '${sinceDays > 0 ? 'of the last $sinceDays days' : 'shown'} — '
            'your prep held up. Nothing to review here.',
      );
    }
    final windowLabel = sinceDays > 0 ? 'the last $sinceDays days' : 'the list';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Everywhere your games left your book in $windowLabel, '
          'most repeated first. Click an entry to review it — the game and '
          'your book line side by side.',
          style: AppTextStyles.body.copyWith(
            fontSize: 12,
            color: AppColors.onSurfaceSoft,
          ),
        ),
        if (data.mistakes.isNotEmpty) ...[
          _sectionHeader(
            'Your mistakes (${data.mistakes.length})',
            AppColors.warning,
          ),
          for (final entry in data.mistakes)
            _EntryTile(
              entry: entry,
              onOpenLine: onOpenLine,
              onOpenGame: onOpenGame,
            ),
        ],
        if (data.bookEnds.isNotEmpty) ...[
          _sectionHeader(
            'Your prep ran out (${data.bookEnds.length})',
            AppColors.onSurfaceSoft,
          ),
          for (final entry in data.bookEnds)
            _EntryTile(
              entry: entry,
              bookEnd: true,
              onOpenLine: onOpenLine,
              onOpenGame: onOpenGame,
            ),
        ],
      ],
    );
  }

  Widget _sectionHeader(String label, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        label,
        style: AppTextStyles.body.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _buildHint(
    BuildContext context, {
    required IconData icon,
    required String message,
    String? buttonLabel,
    VoidCallback? onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Icon(icon, size: 36, color: AppColors.onSurfaceMuted),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: AppTextStyles.body.copyWith(
            fontSize: 13,
            color: AppColors.onSurfaceSoft,
          ),
        ),
        if (buttonLabel != null) ...[
          const SizedBox(height: 16),
          FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
        ],
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.onOpenLine,
    required this.onOpenGame,
    this.bookEnd = false,
  });

  final OpeningReviewEntry entry;
  final bool bookEnd;
  final ValueChanged<OpeningReviewEntry> onOpenLine;
  final ValueChanged<RecentGame> onOpenGame;

  @override
  Widget build(BuildContext context) {
    final count = entry.games.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        // The detail dialog stacks on top of this list, so closing it drops
        // the user back into the review queue. Its navigation callbacks pop
        // both dialogs (detail first, then this list) before switching.
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => OpeningReviewDetailDialog(
            entry: entry,
            bookEnd: bookEnd,
            onEditInBuilder: () {
              Navigator.of(context)
                ..pop()
                ..pop();
              onOpenLine(entry);
            },
            onOpenGame: (game) {
              Navigator.of(context)
                ..pop()
                ..pop();
              onOpenGame(game);
            },
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${entry.chapterName} · move ${entry.moveNumber}',
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '$count ${count == 1 ? 'game' : 'games'}',
                    style: AppTextStyles.body.copyWith(
                      fontSize: 12,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                entry.lineDisplay,
                style: AppTextStyles.body.copyWith(
                  fontSize: 12,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
              const SizedBox(height: 4),
              bookEnd ? _buildBookEndLine() : _buildMistakeLine(),
              const SizedBox(height: 6),
              _GameLinks(entry: entry, onOpenGame: onOpenGame),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMistakeLine() {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'You played ',
            style: AppTextStyles.body.copyWith(fontSize: 13),
          ),
          TextSpan(
            text: entry.playedDisplay,
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.warning,
            ),
          ),
          TextSpan(
            text: ' — book plays ',
            style: AppTextStyles.body.copyWith(fontSize: 13),
          ),
          TextSpan(
            text: entry.expectedDisplay,
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.success,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookEndLine() {
    return Text(
      'Your book has no moves past this point — open the chapter to '
      'extend it.',
      style: AppTextStyles.body.copyWith(
        fontSize: 13,
        color: AppColors.onSurfaceSoft,
      ),
    );
  }
}

/// "vs opponent (Jul 12)" links, one per game, capped so a 10-game leak
/// doesn't flood the tile.
class _GameLinks extends StatelessWidget {
  const _GameLinks({required this.entry, required this.onOpenGame});

  static const _maxLinks = 4;

  final OpeningReviewEntry entry;
  final ValueChanged<RecentGame> onOpenGame;

  @override
  Widget build(BuildContext context) {
    final shown = entry.games.take(_maxLinks).toList();
    final more = entry.games.length - shown.length;
    return Wrap(
      spacing: 12,
      runSpacing: 2,
      children: [
        for (final game in shown)
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () {
              Navigator.of(context).pop();
              onOpenGame(game);
            },
            child: Text(
              'vs ${game.meWhite == true ? game.black : game.white} '
              '(${game.dateDisplayShort})',
              style: AppTextStyles.body.copyWith(
                fontSize: 12,
                color: AppColors.info,
                decoration: TextDecoration.underline,
                decorationColor: AppColors.onSurfaceDim,
              ),
            ),
          ),
        if (more > 0)
          Text(
            '+$more more',
            style: AppTextStyles.body.copyWith(
              fontSize: 12,
              color: AppColors.onSurfaceMuted,
            ),
          ),
      ],
    );
  }
}
