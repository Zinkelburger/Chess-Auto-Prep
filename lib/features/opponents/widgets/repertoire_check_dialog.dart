/// The repertoire check's findings: which of the opponent's lines my book
/// does not answer, most-played first. Tapping one moves the analysis board
/// there, so the fix (an engine look, then "Add line to study") is one step
/// away.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../services/repertoire_check.dart';

class RepertoireCheckDialog extends StatelessWidget {
  const RepertoireCheckDialog({
    super.key,
    required this.report,
    required this.opponentName,
    required this.opponentIsWhite,
    required this.onGoTo,
  });

  final RepertoireCheckReport report;
  final String opponentName;
  final bool opponentIsWhite;
  final ValueChanged<String> onGoTo;

  @override
  Widget build(BuildContext context) {
    final myColour = opponentIsWhite ? 'Black' : 'White';
    final theirColour = opponentIsWhite ? 'White' : 'Black';
    return AlertDialog(
      title: Text('$opponentName as $theirColour vs my $myColour book'),
      content: SizedBox(
        width: 620,
        height: 460,
        child: report.hasBook
            ? _buildFindings(context)
            : _buildNoBook(myColour),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildNoBook(String myColour) {
    return Center(
      child: Text(
        'No $myColour repertoire is designated. Choose one under My books on '
        'the Tactics page and run this again.',
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.onSurfaceMuted),
      ),
    );
  }

  Widget _buildFindings(BuildContext context) {
    final header = [
      'Book: ${report.bookNames.join(', ')} '
          '(${report.bookChapters} chapter${report.bookChapters == 1 ? '' : 's'})',
      '${report.totalGames} of their games',
      '${report.gapGames} reach a gap',
    ].join(' · ');
    final unanswered = report.unanswered;
    final past = report.pastTheEnd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(header, style: AppTextStyles.caption),
        const SizedBox(height: 8),
        Expanded(
          child: report.gaps.isEmpty
              ? const Center(
                  child: Text(
                    'Every line they play is answered in the book.',
                    style: TextStyle(color: AppColors.onSurfaceMuted),
                  ),
                )
              : ListView(
                  children: [
                    if (unanswered.isNotEmpty) ...[
                      _SectionLabel(
                        'Unanswered — the book continues but not against this',
                        unanswered,
                      ),
                      for (final g in unanswered)
                        _GapRow(gap: g, onGoTo: onGoTo),
                    ],
                    if (past.isNotEmpty) ...[
                      _SectionLabel('Past the end of the book', past),
                      for (final g in past) _GapRow(gap: g, onGoTo: onGoTo),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, this.gaps);
  final String text;
  final List<RepertoireGap> gaps;

  @override
  Widget build(BuildContext context) {
    final games = gaps.fold(0, (n, g) => n + g.games);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Text(
        '$text · ${gaps.length} line${gaps.length == 1 ? '' : 's'}, '
        '$games game${games == 1 ? '' : 's'}',
        style: AppTextStyles.caption.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _GapRow extends StatelessWidget {
  const _GapRow({required this.gap, required this.onGoTo});
  final RepertoireGap gap;
  final ValueChanged<String> onGoTo;

  @override
  Widget build(BuildContext context) {
    final score = (gap.opponentScore * 100).round();
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        onGoTo(gap.fen);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                gap.line,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: AppTextStyles.monoFamily,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${gap.games} game${gap.games == 1 ? '' : 's'} · $score%',
              style: AppTextStyles.caption.copyWith(
                fontFeatures: AppTextStyles.tabularFigures,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
