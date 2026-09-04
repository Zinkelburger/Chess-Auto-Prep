/// Skeleton-plan editor: the repertoire-planning "front door" for the
/// generation form.
///
/// The player types the lines they already know they want (one per line, PGN
/// or bare SAN), and toggles a few structure preferences. This card turns that
/// into a [SkeletonPlan] the build reads — pins, transfer targets, and
/// structure vetoes (see `docs/REPERTOIRE_PLANNING.md`). It is deliberately the
/// simplest surface that makes the feature usable; the fuller board workbench
/// is a later phase.
///
/// A pure view over [SkeletonPlanController], which the form owns: the card
/// may be built only while its expander is open without losing what is typed.
library;

import 'package:flutter/material.dart';

import '../../services/generation/skeleton_plan.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'skeleton_plan_controller.dart';

class SkeletonPlanCard extends StatelessWidget {
  final SkeletonPlanController controller;

  /// Which side the repertoire is for — decides whose moves become pins.
  final bool playAsWhite;

  const SkeletonPlanCard({
    super.key,
    required this.controller,
    required this.playAsWhite,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _body(),
    );
  }

  Widget _body() {
    final plan = controller.currentPlan(playAsWhite: playAsWhite);
    final lineCount = _nonEmptyLines.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          playAsWhite
              ? 'Paste the lines you already know you want (White to move on '
                    'odd plies). One line per row — move numbers optional.'
              : 'Paste the lines you already know you want, from Black’s '
                    'side. One line per row — move numbers optional.',
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller.lines,
          minLines: 3,
          maxLines: 8,
          style: const TextStyle(
            fontFamily: AppTextStyles.monoFamily,
            fontSize: 13,
          ),
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
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
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < kStructureVetoes.length; i++)
              Tooltip(
                message: kStructureVetoes[i].tooltip,
                child: FilterChip(
                  label: Text(kStructureVetoes[i].label),
                  selected: controller.isVetoed(i),
                  onSelected: (on) => controller.setVeto(i, on: on),
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
        style: AppTextStyles.caption,
      );
    }
    final pins = plan.nodes.length;
    final partial = _partiallyParsedLines();
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

  List<String> get _nonEmptyLines => [
    for (final raw in controller.lines.text.split('\n'))
      if (raw.trim().isNotEmpty) raw.trim(),
  ];

  /// How many non-empty lines produced fewer pins than their move count would
  /// suggest — a cheap "this line stopped early" signal for the user.
  int _partiallyParsedLines() {
    var partial = 0;
    for (final line in _nonEmptyLines) {
      final single = SkeletonPlan.parseLines([line], playAsWhite: playAsWhite);
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
}
