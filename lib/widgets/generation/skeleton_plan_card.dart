/// Skeleton-plan editor: the repertoire-planning "front door" for the
/// generation form.
///
/// The player types the lines they already know they want (one per line, PGN
/// or bare SAN), and toggles a few structure preferences. This card turns that
/// into a [SkeletonPlan] the build reads — pins, transfer targets, and
/// structure vetoes (see `docs/REPERTOIRE_PLANNING.md`). It is deliberately the
/// simplest surface that makes the feature usable; the fuller board workbench
/// is a later phase.
library;

import 'package:flutter/material.dart';

import '../../services/generation/skeleton_plan.dart';
import '../../theme/app_colors.dart';

/// One toggleable structure veto offered in the UI, with the feature it emits.
class _VetoOption {
  final String label;
  final String tooltip;
  final StructureFeature Function() build;
  const _VetoOption(this.label, this.tooltip, this.build);
}

const List<_VetoOption> _vetoPalette = [
  _VetoOption(
    'Avoid a pawn on d5',
    'Drops lines where we end up with a pawn on d5 — the symmetric, QGD-ish '
        'structures. Chosen for a fighting, asymmetric repertoire (e.g. Benko).',
    _pawnD5,
  ),
  _VetoOption(
    'Avoid a pawn on e5',
    'Drops lines where we commit a pawn to e5.',
    _pawnE5,
  ),
  _VetoOption(
    'Avoid an early queen trade',
    'Drops lines where the queens come off early (e.g. the dry 4.Qxd4 d5 '
        '5.cxd5 Qxd5 lines) — the trade leaves little to play for.',
    _earlyQueens,
  ),
];

StructureFeature _pawnD5() => const PawnOnSquare(square: 'd5');
StructureFeature _pawnE5() => const PawnOnSquare(square: 'e5');
StructureFeature _earlyQueens() => const EarlyQueenTrade();

class SkeletonPlanCard extends StatefulWidget {
  /// Which side the repertoire is for — decides whose moves become pins.
  final bool playAsWhite;

  const SkeletonPlanCard({super.key, required this.playAsWhite});

  @override
  State<SkeletonPlanCard> createState() => SkeletonPlanCardState();
}

class SkeletonPlanCardState extends State<SkeletonPlanCard> {
  final TextEditingController _linesCtrl = TextEditingController();
  final Set<int> _activeVetoes = {};

  @override
  void dispose() {
    _linesCtrl.dispose();
    super.dispose();
  }

  /// Load an existing plan back into the editor (resume / preset).
  void loadPlan(SkeletonPlan plan) {
    _linesCtrl.text = plan.sourceLines.join('\n');
    _activeVetoes
      ..clear()
      ..addAll(_matchVetoes(plan.features));
    if (mounted) setState(() {});
  }

  /// The plan the form should build with. Empty text and no vetoes → empty
  /// plan (the classic build).
  SkeletonPlan currentPlan() {
    final lines = _linesCtrl.text.split('\n');
    final features = [
      for (final i in _activeVetoes)
        if (i >= 0 && i < _vetoPalette.length) _vetoPalette[i].build(),
    ];
    return SkeletonPlan.fromLines(
      lines,
      playAsWhite: widget.playAsWhite,
      features: features,
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = currentPlan();
    final lineCount = _linesCtrl.text
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.playAsWhite
              ? 'Paste the lines you already know you want (White to move on '
                    'odd plies). One line per row — move numbers optional.'
              : 'Paste the lines you already know you want, from Black’s '
                    'side. One line per row — move numbers optional.',
          style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceSoft),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _linesCtrl,
          onChanged: (_) => setState(() {}),
          minLines: 3,
          maxLines: 8,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            hintText:
                '1.d4 Nf6 2.c4 c5 3.Nf3 cxd4 4.Nxd4 e5\n'
                '1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6',
            hintStyle: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ),
        const SizedBox(height: 6),
        _feedback(plan, lineCount),
        const SizedBox(height: 12),
        const Text(
          'Structures to avoid',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        const Text(
          'A veto drops lines that reach the structure when a sound '
          'alternative exists — it steers, it never leaves you unprepared.',
          style: TextStyle(fontSize: 12, color: AppColors.onSurfaceSoft),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _vetoPalette.length; i++)
              Tooltip(
                message: _vetoPalette[i].tooltip,
                child: FilterChip(
                  label: Text(_vetoPalette[i].label),
                  selected: _activeVetoes.contains(i),
                  onSelected: (on) => setState(() {
                    if (on) {
                      _activeVetoes.add(i);
                    } else {
                      _activeVetoes.remove(i);
                    }
                  }),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _feedback(SkeletonPlan plan, int lineCount) {
    if (lineCount == 0) {
      return const Text(
        'No lines yet — the build runs normally, with no steering.',
        style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
      );
    }
    final pins = plan.nodes.length;
    final partial = _partiallyParsedLines(lineCount, plan);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          partial > 0 ? Icons.warning_amber : Icons.check_circle_outline,
          size: 16,
          color: partial > 0 ? AppColors.warning : AppColors.success,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            partial > 0
                ? '$pins pinned move${pins == 1 ? '' : 's'} across $lineCount '
                      'line${lineCount == 1 ? '' : 's'}. '
                      '$partial line${partial == 1 ? '' : 's'} had a move that '
                      'is illegal in its position — everything before it was '
                      'still kept.'
                : '$pins pinned move${pins == 1 ? '' : 's'} across $lineCount '
                      'line${lineCount == 1 ? '' : 's'}. These are honoured '
                      'exactly; sound answers consistent with them fill the '
                      'rest.',
            style: TextStyle(
              fontSize: 12,
              color: partial > 0 ? AppColors.warning : AppColors.onSurfaceSoft,
            ),
          ),
        ),
      ],
    );
  }

  /// How many non-empty lines produced fewer pins than their move count would
  /// suggest — a cheap "this line stopped early" signal for the user.
  int _partiallyParsedLines(int lineCount, SkeletonPlan plan) {
    var partial = 0;
    for (final raw in _linesCtrl.text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final single = SkeletonPlan.parseLines([
        line,
      ], playAsWhite: widget.playAsWhite);
      // Count SAN tokens in the line (ignoring move numbers) and compare to how
      // deep parsing actually got. A fully-parsed line consumes all tokens.
      final tokens = line
          .split(RegExp(r'\s+'))
          .map((t) => t.replaceAll(RegExp(r'^\d+\.(\.\.)?'), '').trim())
          .where(
            (t) =>
                t.isNotEmpty &&
                t != '*' &&
                t != '1-0' &&
                t != '0-1' &&
                t != '1/2-1/2',
          )
          .length;
      // Every legal ply advances the position; our-move plies become pins.
      // If the last pin's path is shorter than tokens-1, parsing stopped early.
      if (single.isEmpty && tokens > 0) {
        partial++;
        continue;
      }
      if (single.isNotEmpty) {
        final deepestPath = single.last.pathLabel
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .length;
        // deepestPath counts moves before the last pin; +1 for the pin itself.
        // If far fewer than the tokens present, the line was truncated.
        if (deepestPath + 1 < tokens - 1) partial++;
      }
    }
    return partial;
  }

  Set<int> _matchVetoes(List<StructureFeature> features) {
    final out = <int>{};
    for (final f in features) {
      for (var i = 0; i < _vetoPalette.length; i++) {
        if (_sameFeature(_vetoPalette[i].build(), f)) out.add(i);
      }
    }
    return out;
  }

  bool _sameFeature(StructureFeature a, StructureFeature b) {
    if (a is PawnOnSquare && b is PawnOnSquare) {
      return a.square == b.square && a.ours == b.ours && a.avoid == b.avoid;
    }
    return a is EarlyQueenTrade && b is EarlyQueenTrade;
  }
}
