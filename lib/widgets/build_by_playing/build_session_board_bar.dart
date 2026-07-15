/// Fixed-height strip under the board during a Build-by-Playing session:
/// phase status, the ephemeral scratch trail as clickable SAN chips, and a
/// "Back to decision point" button. All slots are always present (disabled
/// when inapplicable) so the layout never shifts between phases.
library;

import 'package:flutter/material.dart';

import '../../services/build_by_playing/build_by_playing_controller.dart';
import '../../theme/app_colors.dart';

class BuildSessionBoardBar extends StatelessWidget {
  const BuildSessionBoardBar({super.key, required this.session});

  final BuildByPlayingController session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final theme = Theme.of(context);
        final exploring = session.phase == BuildByPlayingPhase.exploring;
        final trail = session.scratchTrail;

        return Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: exploring
                ? AppColors.warningSurface.withValues(alpha: 0.25)
                : theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
            border: Border(top: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              Icon(
                exploring ? Icons.science_outlined : Icons.sports_esports,
                size: 14,
                color: exploring ? AppColors.warning : theme.hintColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: exploring && trail.isNotEmpty
                    ? _ScratchTrail(session: session, trail: trail)
                    : Text(
                        session.statusText ?? '',
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                onPressed: exploring ? session.backToDecisionPoint : null,
                icon: const Icon(Icons.undo, size: 14),
                label: const Text('Back to decision point',
                    style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The scratch line as clickable chips; tapping a chip jumps the scratch
/// cursor to that ply.
class _ScratchTrail extends StatelessWidget {
  const _ScratchTrail({required this.session, required this.trail});

  final BuildByPlayingController session;
  final List<String> trail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true, // keep the newest move in view
      child: Row(
        children: [
          Text('Exploring: ',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor)),
          for (var i = 0; i < trail.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: InkWell(
                onTap: () => session.scratchJumpTo(i),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: i == trail.length - 1
                        ? theme.colorScheme.surfaceContainerHighest
                        : null,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    trail[i],
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: i == trail.length - 1
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
