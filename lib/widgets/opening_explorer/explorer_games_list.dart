/// The games an explorer source lists for a position — lila's "top games"
/// table under the moves.
///
/// One row per game: the players with their ratings, the result, when, and
/// the move the game played here.  Clicking a row opens it, which is the
/// whole point of listing it: an explorer that can only say "2,431 games"
/// leaves you to imagine them.
library;

import 'package:flutter/material.dart';

import '../../models/explorer_response.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'explorer_move_row.dart';

class ExplorerGamesList extends StatelessWidget {
  const ExplorerGamesList({
    super.key,
    required this.games,
    required this.onOpen,
    this.heading = 'Games',
    this.busyId,
  });

  final List<ExplorerGame> games;

  /// Open the game in the viewer.
  final ValueChanged<ExplorerGame> onOpen;

  final String heading;

  /// The id of a game whose PGN is on its way, so its row can say so.
  final String? busyId;

  @override
  Widget build(BuildContext context) {
    if (games.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: ExplorerColumns.rowHeight,
          padding: ExplorerColumns.padding,
          alignment: Alignment.centerLeft,
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.divider)),
          ),
          child: Text(heading, style: AppTextStyles.eyebrow),
        ),
        for (final game in games)
          _GameRow(
            key: ValueKey('${game.source.name}:${game.id}'),
            game: game,
            busy: game.id == busyId,
            onOpen: () => onOpen(game),
          ),
      ],
    );
  }
}

class _GameRow extends StatelessWidget {
  const _GameRow({
    super.key,
    required this.game,
    required this.busy,
    required this.onOpen,
  });

  final ExplorerGame game;
  final bool busy;
  final VoidCallback onOpen;

  static String _name(String pgnName) {
    final comma = pgnName.indexOf(',');
    if (comma <= 0) return pgnName;
    final surname = pgnName.substring(0, comma).trim();
    final rest = pgnName.substring(comma + 1).trim();
    return rest.isEmpty ? surname : '$surname ${rest[0]}.';
  }

  @override
  Widget build(BuildContext context) {
    final white = _name(game.white);
    final black = _name(game.black);
    final elos = [
      if (game.whiteElo != null) '${game.whiteElo}',
      if (game.blackElo != null) '${game.blackElo}',
    ].join('/');
    final detail = [
      if (game.san.isNotEmpty) game.san,
      if (elos.isNotEmpty) elos,
      if (game.when.isNotEmpty) game.when,
      if (game.event.isNotEmpty) game.event,
    ].join(' · ');
    return Tooltip(
      message:
          '${game.white} – ${game.black}'
          '${game.event.isEmpty ? '' : ', ${game.event}'}'
          '${game.when.isEmpty ? '' : ' (${game.when})'}'
          '${game.san.isEmpty ? '' : ' — played ${game.san} here'}.\n'
          'Click to open it at this position.',
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: busy ? null : onOpen,
        child: Container(
          height: ExplorerColumns.rowHeight + 10,
          padding: ExplorerColumns.padding,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$white – $black',
                      style: AppTextStyles.body.copyWith(fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      detail,
                      style: AppTextStyles.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              else
                SizedBox(
                  width: 44,
                  child: Text(
                    game.result,
                    textAlign: TextAlign.right,
                    style: AppTextStyles.mono.copyWith(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
