/// The rows of a planning question: one per candidate move.
///
/// Tapping anywhere on a row selects it (and shows it on the board). At our
/// own move exactly one row is selected — the user plays one move; at the
/// opponent's move any number can be. The numbers sit right after the move,
/// where the eye lands: Maia's share here, the cumulative chance of reaching
/// the position from the walk's root, the eval, and the user's own share.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../models/plan_models.dart';

class PlanCandidateTable extends StatelessWidget {
  const PlanCandidateTable({
    super.key,
    required this.candidates,
    required this.selected,
    required this.onSelect,
    required this.isWhiteToMove,
    required this.reachProb,
    this.singleSelect = false,
    this.ownLabel = 'You',
    this.evaluating = const {},
    this.onEvaluate,
    this.evalSourceLabel = 'ChessDB',
  });

  final List<PlanCandidate> candidates;
  final Set<String> selected;

  /// SANs whose engine run is in flight; those cells show a spinner.
  final Set<String> evaluating;

  /// Tapping an empty EVAL cell runs the engine for that move.
  final ValueChanged<String>? onEvaluate;

  /// Where evals come from, for the header tooltip ("ChessDB (local)").
  final String evalSourceLabel;

  /// Row tapped: the host decides how selection changes (single vs multi).
  final ValueChanged<String> onSelect;
  final bool isWhiteToMove;

  /// Probability of reaching this position from the walk's root; each row
  /// shows `reachProb × share` as its cumulative chance.
  final double reachProb;
  final bool singleSelect;
  final String ownLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeaderRow(ownLabel: ownLabel, evalHeaderTip: evalSourceLabel),
        const Divider(height: 1),
        for (var i = 0; i < candidates.length; i++)
          _CandidateRow(
            index: i,
            candidate: candidates[i],
            selected: selected.contains(candidates[i].san),
            single: singleSelect,
            onTap: () => onSelect(candidates[i].san),
            isWhiteToMove: isWhiteToMove,
            reachProb: reachProb,
            evaluating: evaluating.contains(candidates[i].san),
            onEvaluate: onEvaluate == null
                ? null
                : () => onEvaluate!(candidates[i].san),
          ),
      ],
    );
  }
}

const _numW = 58.0;

class _HeaderRow extends StatelessWidget {
  final String ownLabel;
  final String evalHeaderTip;
  const _HeaderRow({required this.ownLabel, required this.evalHeaderTip});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 12,
      letterSpacing: 0.6,
      fontWeight: FontWeight.w700,
      color: AppColors.onSurfaceMuted,
    );
    Widget col(String t, String tip, {double width = _numW}) => SizedBox(
      width: width,
      child: Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 300),
        child: Text(t, style: style, textAlign: TextAlign.right),
      ),
    );
    final ownTip = ownLabel.toLowerCase().startsWith('vs')
        ? 'Your games: opponents played this · games here'
        : 'Your games: you played this · games here';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          const SizedBox(width: 30),
          const SizedBox(width: 74, child: Text('MOVE', style: style)),
          col('MAIA', 'Maia: chance a player like you plays this here'),
          col(
            'CUM. PROB',
            'Chance of reaching this from your start',
            width: 68,
          ),
          col('EVAL', evalHeaderTip),
          col(ownLabel.toUpperCase(), ownTip),
          const SizedBox(width: 12),
          const Expanded(child: Text('NAME', style: style)),
        ],
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  final int index;
  final PlanCandidate candidate;
  final bool selected;
  final bool single;
  final VoidCallback onTap;
  final bool isWhiteToMove;
  final double reachProb;
  final bool evaluating;
  final VoidCallback? onEvaluate;

  const _CandidateRow({
    required this.index,
    required this.candidate,
    required this.selected,
    required this.single,
    required this.onTap,
    required this.isWhiteToMove,
    required this.reachProb,
    this.evaluating = false,
    this.onEvaluate,
  });

  @override
  Widget build(BuildContext context) {
    final c = candidate;
    final share = c.share;
    final markColor = selected ? AppColors.accent : AppColors.onSurfaceDim;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? AppColors.accent.withValues(alpha: 0.16) : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Icon(
                single
                    ? (selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off)
                    : (selected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank),
                size: 18,
                color: markColor,
              ),
            ),
            SizedBox(
              width: 74,
              child: Text(
                isWhiteToMove ? c.san : '…${c.san}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFamily: AppTextStyles.monoFamily,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            _num(share == null ? null : _pct(share), strong: true),
            _num(share == null ? null : _pct(share * reachProb), width: 68),
            _evalCell(c),
            _num(
              c.ownShare == null
                  ? null
                  : '${_pct(c.ownShare!)} · ${c.ownGames}',
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                [
                  if (c.name != null) c.name!,
                  if (c.eco != null) c.eco!,
                  if (c.inChapters) 'in your chapters',
                ].join(' · '),
                style: TextStyle(
                  fontSize: 12,
                  color: c.inChapters
                      ? AppColors.success
                      : AppColors.onSurfaceMuted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The EVAL cell: the number with its provenance on hover; a spinner while
  /// the engine runs; a "run" affordance when there is nothing yet.
  Widget _evalCell(PlanCandidate c) {
    if (evaluating) {
      return const SizedBox(
        width: _numW,
        child: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
    }
    if (c.evalCp == null) {
      return SizedBox(
        width: _numW,
        child: Align(
          alignment: Alignment.centerRight,
          child: Tooltip(
            message: onEvaluate == null ? 'No eval' : 'Run Stockfish',
            waitDuration: const Duration(milliseconds: 300),
            child: InkWell(
              onTap: onEvaluate,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Icon(
                  Icons.play_circle_outline,
                  size: 14,
                  color: onEvaluate == null
                      ? AppColors.onSurfaceDim
                      : AppColors.onSurfaceMuted,
                ),
              ),
            ),
          ),
        ),
      );
    }
    final tip = [
      c.evalSource ?? 'Eval',
      if (c.evalDepth != null) 'depth ${c.evalDepth}',
    ].join(' · ');
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 300),
      child: _num(
        _eval(c.evalCp!),
        color: AppColors.cpEval(isWhiteToMove ? c.evalCp! : -c.evalCp!),
      ),
    );
  }

  static String _pct(double v) {
    final p = v * 100;
    return p >= 10
        ? '${p.round()}%'
        : p >= 1
        ? '${p.toStringAsFixed(1)}%'
        : '${p.toStringAsFixed(2)}%';
  }

  static String _eval(int cp) {
    final v = cp / 100;
    return (v >= 0 ? '+' : '') + v.toStringAsFixed(1);
  }

  Widget _num(
    String? text, {
    bool strong = false,
    Color? color,
    double width = _numW,
  }) => SizedBox(
    width: width,
    child: Text(
      text ?? '–',
      textAlign: TextAlign.right,
      style: TextStyle(
        fontSize: 13,
        fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: text == null ? AppColors.onSurfaceDim : (color ?? AppColors.ink),
      ),
    ),
  );
}
