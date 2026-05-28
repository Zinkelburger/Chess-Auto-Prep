import 'package:flutter/material.dart';

import '../../screens/settings_screen.dart';
import '../../theme/app_colors.dart';
import '../app_mode_menu_button.dart';

/// App bar for the repertoire screen: title, generation status, and actions.
class RepertoireToolbar extends StatelessWidget implements PreferredSizeWidget {
  const RepertoireToolbar({
    super.key,
    required this.title,
    this.isGenerating = false,
    this.isGenerationPaused = false,
    this.showTrainButton = false,
    this.showSelectRepertoireAction = false,
    this.generationLocked = false,
    required this.onOpenSettings,
    this.onSelectRepertoire,
    this.onTrainRepertoire,
  });

  final Widget title;
  final bool isGenerating;
  final bool isGenerationPaused;
  final bool showTrainButton;
  final bool showSelectRepertoireAction;
  final bool generationLocked;
  final VoidCallback onOpenSettings;
  final VoidCallback? onSelectRepertoire;
  final VoidCallback? onTrainRepertoire;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 16,
      title: title,
      actions: [
        if (isGenerating)
          RepertoireGenerationStatusChip(
            isPaused: isGenerationPaused,
          ),
        if (showTrainButton && onTrainRepertoire != null)
          RepertoireTrainButton(
            onPressed: generationLocked ? null : onTrainRepertoire,
          ),
        IconButton(
          icon: const Icon(Icons.settings, size: 20),
          tooltip: 'Settings',
          onPressed: onOpenSettings,
        ),
        const AppModeMenuButton(),
        if (showSelectRepertoireAction && onSelectRepertoire != null)
          RepertoireSelectButton(
            onPressed: generationLocked ? null : onSelectRepertoire,
          ),
      ],
    );
  }
}

/// Two-line app bar title with repertoire name and game count.
class RepertoireToolbarTitle extends StatelessWidget {
  const RepertoireToolbarTitle({
    super.key,
    this.repertoireName,
    this.gameCount,
  });

  final String? repertoireName;
  final int? gameCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Repertoire Builder',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        if (repertoireName != null) ...[
          Text(
            '$repertoireName • ${gameCount ?? 0} game${(gameCount ?? 0) == 1 ? '' : 's'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class RepertoireGenerationStatusChip extends StatelessWidget {
  const RepertoireGenerationStatusChip({
    super.key,
    required this.isPaused,
  });

  final bool isPaused;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isPaused
                ? AppColors.warningSurface
                : AppColors.warningSurface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isPaused)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(Icons.pause, size: 12, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                isPaused ? 'Paused' : 'Building...',
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RepertoireSelectButton extends StatelessWidget {
  const RepertoireSelectButton({
    super.key,
    required this.onPressed,
  });

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: compact
            ? IconButton(
                tooltip: 'Select repertoire',
                onPressed: onPressed,
                icon: const Icon(Icons.library_books),
              )
            : TextButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.library_books),
                label: const Text('Select Repertoire'),
              ),
      ),
    );
  }
}

class RepertoireTrainButton extends StatelessWidget {
  const RepertoireTrainButton({
    super.key,
    required this.onPressed,
  });

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 900;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: compact
            ? IconButton(
                tooltip: 'Train repertoire',
                onPressed: onPressed,
                icon: const Icon(Icons.school),
              )
            : TextButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.school),
                label: const Text('Train'),
              ),
      ),
    );
  }
}

/// Opens global settings from the repertoire toolbar.
void openRepertoireSettings(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const SettingsScreen()),
  );
}
