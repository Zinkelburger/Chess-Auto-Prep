/// "Which side does this file train?"
///
/// Only third-party files ever need this. A repertoire the app wrote carries a
/// `// Color:` header and is never in doubt; a Chessable/ChessBase export
/// carries nothing, so the trainer reads the side off the move tree — a guess
/// that is usually right and occasionally not. When it is wrong, every line
/// asks for the opponent's move, so the correction has to be one click from
/// the line list.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// What the user picked. [TrainingSideChoice.fromFile] clears a previous
/// override and hands the question back to the file.
enum TrainingSideChoice { white, black, fromFile }

/// Returns the chosen side, or null if the dialog was dismissed.
///
/// [currentIsWhite] is the side in force right now; [overridden] is whether
/// that came from a previous hand-set answer rather than from the file, which
/// is what decides whether "use what the file says" is worth offering.
Future<TrainingSideChoice?> showTrainingSideDialog(
  BuildContext context, {
  required bool currentIsWhite,
  required bool overridden,
}) {
  return showDialog<TrainingSideChoice>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: const Text('Which side does this file train?'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                overridden
                    ? 'You set this by hand. The trainer will keep asking you '
                          'for ${currentIsWhite ? "White's" : "Black's"} moves '
                          'in this file until you change it.'
                    : 'Course exports do not record which colour they are for, '
                          'so the trainer worked it out from the moves: it is '
                          'asking you for '
                          '${currentIsWhite ? "White's" : "Black's"} moves. If '
                          'the board keeps asking for your opponent\'s move, '
                          'this is the setting that is wrong.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              _SideTile(
                icon: Icons.circle_outlined,
                label: 'I play White',
                subtitle: 'Quiz me on White\'s moves.',
                selected: currentIsWhite,
                onTap: () =>
                    Navigator.of(context).pop(TrainingSideChoice.white),
              ),
              const SizedBox(height: 8),
              _SideTile(
                icon: Icons.circle,
                label: 'I play Black',
                subtitle: 'Quiz me on Black\'s moves.',
                selected: !currentIsWhite,
                onTap: () =>
                    Navigator.of(context).pop(TrainingSideChoice.black),
              ),
              if (overridden) ...[
                const SizedBox(height: 8),
                _SideTile(
                  icon: Icons.auto_fix_high_outlined,
                  label: 'Let the file decide',
                  subtitle:
                      'Forget my answer and go back to reading the side off '
                      'the file.',
                  selected: false,
                  onTap: () =>
                      Navigator.of(context).pop(TrainingSideChoice.fromFile),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );
}

class _SideTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _SideTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.10)
          : theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : AppColors.divider,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: AppColors.onSurfaceSoft),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurfaceMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
