/// Your games against master practice, reviewable like a queue.
///
/// The master database used to open as a page of the corpus: two million
/// games, a filter bar, and no reason to look at any one of them. What a
/// player actually wants from it is the answer to two questions about their
/// *own* games — where did I leave theory, and what do the strong players do
/// there instead — so this is a list of those branch points, grouped so the
/// one you keep walking into is at the top, and a detail pane that puts the
/// position, the masters' moves and the games worth opening in one place.
///
/// Two ways out, both into the Games viewer: one of your games at the branch
/// (so you can see what happened next), or a master game at the same ply (so
/// you can see what should have happened next). The dialog pops itself before
/// either, because both navigate away from the home column.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_state.dart';
import '../../../services/master_games/master_games_db.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/number_format.dart';
import '../../../widgets/common/static_board_thumbnail.dart';
import '../../games/models/recent_game.dart';
import '../../games/services/recent_game_navigation.dart';
import '../controllers/master_practice_controller.dart';
import '../services/master_practice_review.dart';

/// Open the review over [games] on top of the current screen.
Future<void> showMasterPracticeReview(
  BuildContext context, {
  required AppState appState,
  required List<RecentGame> games,
  required String windowLabel,
  MasterPracticeController? controller,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => MasterPracticeDialog(
      appState: appState,
      games: games,
      windowLabel: windowLabel,
      controller: controller ?? MasterPracticeController(),
    ),
  );
}

class MasterPracticeDialog extends StatefulWidget {
  const MasterPracticeDialog({
    super.key,
    required this.appState,
    required this.games,
    required this.windowLabel,
    required this.controller,
  });

  final AppState appState;

  /// The games to check — the home column's window.
  final List<RecentGame> games;

  /// How that window reads ("last 20 games"), so the header names the same
  /// slice the list above it shows.
  final String windowLabel;

  final MasterPracticeController controller;

  @override
  State<MasterPracticeDialog> createState() => _MasterPracticeDialogState();
}

class _MasterPracticeDialogState extends State<MasterPracticeDialog> {
  MasterPracticeController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChanged);
    unawaited(_c.run(widget.games));
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    _c.cancel();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _openMyGame(RecentGame game, MasterPracticeReport report) {
    Navigator.pop(context);
    openRecentGame(widget.appState, game, ply: report.viewerPly);
  }

  Future<void> _openMasterGame(
    MasterPracticeEntry entry,
    MasterKeyGame key,
  ) async {
    final written = await _c.writeKeyGames(entry, focus: key.game);
    if (!mounted) return;
    Navigator.pop(context);
    widget.appState.switchToPgnViewer(
      path: written.path,
      gameIndex: written.index,
      ply: entry.report.matchedPlies + 1,
      historyLabel: 'Master game: ${key.players}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 780),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const Divider(height: 1),
            Expanded(child: _body()),
            const Divider(height: 1),
            _footer(),
          ],
        ),
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────

  Widget _header() {
    final review = _c.review;
    final String subtitle;
    if (_c.isLoading) {
      subtitle = 'Checking your ${widget.windowLabel} against master practice…';
    } else if (review == null) {
      subtitle = _c.error ?? '';
    } else {
      subtitle = review.headline(widget.windowLabel);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Your games vs. master practice',
                  style: AppTextStyles.title,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  key: const Key('master-practice-headline'),
                  style: AppTextStyles.muted,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  // ── Body ────────────────────────────────────────────────────────────────

  Widget _body() {
    final error = _c.error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error, style: AppTextStyles.body),
        ),
      );
    }
    final review = _c.review;
    if (review == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.games.isEmpty) {
      return _hint(
        'No games in your ${widget.windowLabel} to check. Download some on '
        'the home page first.',
      );
    }
    if (review.isEmpty) {
      return _hint(
        'None of your ${widget.windowLabel} could be checked: the app has to '
        'know which side you played, and these games name neither of your '
        'accounts.',
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _list(review)),
        const VerticalDivider(width: 1),
        SizedBox(width: 440, child: _detail()),
      ],
    );
  }

  Widget _hint(String message) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: AppTextStyles.body,
      ),
    ),
  );

  // ── List ────────────────────────────────────────────────────────────────

  Widget _list(MasterPracticeReview review) {
    final items = <Widget>[
      if (review.mine.isNotEmpty) ...[
        _section('You left master practice first', review.mine.length),
        for (final e in review.mine) _row(e),
      ],
      if (review.theirs.isNotEmpty) ...[
        _section('Your opponents left first', review.theirs.length),
        for (final e in review.theirs) _row(e),
      ],
      if (review.inBook.isNotEmpty) ...[
        _section('Stayed in master practice', review.inBook.length),
        for (final e in review.inBook) _row(e),
      ],
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: items,
    );
  }

  Widget _section(String label, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text('$label ($count)', style: AppTextStyles.eyebrow),
  );

  Widget _row(MasterPracticeEntry entry) {
    final report = entry.report;
    final selected = identical(_c.selected, entry);
    final count = entry.games.length;

    final String title;
    final String what;
    if (report.isDeviation) {
      title = report.playedDisplay!;
      final plays = entry.alternativeSans();
      what = plays.isEmpty
          ? 'No master move recorded here'
          : 'Masters play ${plays.join(', ')}';
    } else {
      title = report.lastBookMoveDisplay ?? '—';
      what = report.reachedBookDepth
          ? 'In theory as deep as the book goes'
          : report.playedSan == null
          ? 'Ended inside master practice'
          : 'No master game continues from here';
    }

    final who = count == 1
        ? 'vs ${entry.games.first.opponent ?? '?'} · '
              '${entry.games.first.dateDisplayShort}'
        : '$count games';
    final opening = entry.openingDisplay;
    final where = opening == null ? who : '$opening · $who';

    return InkWell(
      onTap: () => _c.select(entry),
      child: Container(
        color: selected ? AppColors.surfaceContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(
                title,
                style: AppTextStyles.mono.copyWith(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    where,
                    style: AppTextStyles.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    what,
                    style: AppTextStyles.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (count > 1) ...[
              const SizedBox(width: 8),
              Text('$count×', style: AppTextStyles.bodyStrong),
            ],
          ],
        ),
      ),
    );
  }

  // ── Detail ──────────────────────────────────────────────────────────────

  Widget _detail() {
    final entry = _c.selected;
    if (entry == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Select a branch point to see it here.',
            textAlign: TextAlign.center,
            style: AppTextStyles.muted,
          ),
        ),
      );
    }
    final report = entry.report;
    final meWhite = entry.games.first.meWhite ?? true;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_detailTitle(report), style: AppTextStyles.bodyStrong),
          const SizedBox(height: 2),
          Text(_detailSubtitle(report), style: AppTextStyles.muted),
          const SizedBox(height: 12),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: StaticBoardThumbnail(
                fen: report.fen,
                size: 280,
                flipped: !meWhite,
                arrows: _arrows(report),
              ),
            ),
          ),
          if (report.alternatives.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('Masters play here', style: AppTextStyles.eyebrow),
            const SizedBox(height: 4),
            for (final m in report.alternatives.take(5)) _moveRow(report, m),
          ],
          if (entry.keyGames.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('Games to open', style: AppTextStyles.eyebrow),
            const SizedBox(height: 4),
            for (final k in entry.keyGames) _keyGameRow(entry, k),
          ],
          const SizedBox(height: 14),
          Text(
            entry.games.length == 1 ? 'Your game' : 'Your games',
            style: AppTextStyles.eyebrow,
          ),
          const SizedBox(height: 4),
          for (final g in entry.games) _myGameRow(g, report),
        ],
      ),
    );
  }

  String _detailTitle(MasterPracticeReport report) {
    if (report.isDeviation) {
      final who = report.byMe == true ? 'You' : 'Your opponent';
      return '$who played ${report.playedDisplay}';
    }
    final last = report.lastBookMoveDisplay;
    return last == null
        ? 'Nothing to compare'
        : 'In master practice through $last';
  }

  String _detailSubtitle(MasterPracticeReport report) {
    final reached = formatThousands(report.positionGames);
    if (report.isDeviation) {
      return 'No master game has played it here. $reached master games '
          'reach this position.';
    }
    if (report.reachedBookDepth) {
      return 'The book covers the first ${kBookMaxPly ~/ 2} moves; this game '
          'stayed in theory all the way.';
    }
    if (report.playedSan == null) {
      return 'The game ended before leaving master practice.';
    }
    return 'No master game continued from this position, so there is '
        'nothing to compare ${report.playedDisplay} against.';
  }

  List<BoardArrow> _arrows(MasterPracticeReport report) => [
    for (final m in report.alternatives.take(3))
      BoardArrow(
        uci: report.alternativeUci(m),
        color: AppColors.success.withValues(alpha: 0.85),
      ),
    if (report.isDeviation && report.playedUci.isNotEmpty)
      BoardArrow(
        uci: report.playedUci,
        color:
            (report.byMe == true ? AppColors.danger : AppColors.onSurfaceMuted)
                .withValues(alpha: 0.9),
      ),
  ];

  Widget _moveRow(MasterPracticeReport report, BookMove move) {
    final mover = report.whiteToMove ? 'White' : 'Black';
    final pct = (report.scoreForMover(move) * 100).round();
    final games = formatThousands(move.games);
    return Tooltip(
      message:
          '$mover scores $pct% with ${report.alternativeSan(move)} over '
          '$games master games'
          '${move.lastYear > 0 ? ', last played ${move.lastYear}' : ''}',
      waitDuration: const Duration(milliseconds: 500),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(
                report.alternativeSan(move),
                style: AppTextStyles.mono.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: Text(
                '$games ${move.games == 1 ? 'game' : 'games'}',
                style: AppTextStyles.body,
              ),
            ),
            Text('$pct%', style: AppTextStyles.body),
          ],
        ),
      ),
    );
  }

  Widget _keyGameRow(MasterPracticeEntry entry, MasterKeyGame key) {
    final game = key.game;
    final elos = [
      if (game.whiteElo != null) '${game.whiteElo}',
      if (game.blackElo != null) '${game.blackElo}',
    ].join('/');
    final line = [
      key.reason,
      key.moveSan,
      key.where,
      if (elos.isNotEmpty) elos,
      game.result,
    ].join(' · ');
    return Tooltip(
      message:
          '${game.white} – ${game.black}, ${key.where}: ${key.reason} game '
          'with ${key.moveSan} here.\nClick to open it in Games at this move.',
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: () => unawaited(_openMasterGame(entry, key)),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                key.players,
                style: AppTextStyles.body,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                line,
                style: AppTextStyles.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _myGameRow(RecentGame game, MasterPracticeReport report) {
    final outcome = switch (game.myOutcome) {
      MyGameOutcome.win => 'won',
      MyGameOutcome.loss => 'lost',
      MyGameOutcome.draw => 'drew',
      MyGameOutcome.unknown => game.result,
    };
    return Tooltip(
      message: 'Open this game in Games at this move.',
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: () => _openMyGame(game, report),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'vs ${game.opponent ?? '?'} · $outcome · ${game.dateDisplay} · '
            '${game.timeControlDisplay}',
            style: AppTextStyles.body,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  // ── Footer ──────────────────────────────────────────────────────────────

  Widget _footer() {
    final review = _c.review;
    final stats = _c.stats;
    final parts = <String>[
      if (review != null && review.gamesSkipped > 0)
        '${review.gamesSkipped} ${review.gamesSkipped == 1 ? 'game' : 'games'} '
            'skipped (neither player is you)',
      if (stats != null && !stats.isEmpty)
        '${formatThousands(stats.games)} master games from TWIC',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Text(
        parts.join(' · '),
        style: AppTextStyles.muted,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
