import 'package:flutter/material.dart';

import '../../screens/settings_screen.dart';
import '../../theme/app_colors.dart';
import '../app_mode_menu_button.dart';
import '../shortcut_tooltip.dart';
import '../layout/board_zone.dart';
import '../layout/repertoire_mode.dart';
import '../layout/repertoire_mode_switcher.dart';

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
    this.trapNavigation,
    this.mode,
    this.onModeChanged,
    required this.onOpenSettings,
    this.onSelectRepertoire,
    this.onTrainRepertoire,
    this.onOpenGeneration,
  });

  final Widget title;
  final bool isGenerating;
  final bool isGenerationPaused;
  final bool showTrainButton;
  final bool showSelectRepertoireAction;
  final bool generationLocked;
  final Widget? trapNavigation;
  final RepertoireMode? mode;
  final ValueChanged<RepertoireMode>? onModeChanged;
  final VoidCallback onOpenSettings;
  final VoidCallback? onSelectRepertoire;
  final VoidCallback? onTrainRepertoire;
  final VoidCallback? onOpenGeneration;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 16,
      title: title,
      actions: [
        if (mode != null && onModeChanged != null)
          RepertoireModeSwitcher(
            mode: mode!,
            onModeChanged: onModeChanged!,
            enabled: !generationLocked,
          ),
        BoardZoneControls(trapNavigation: trapNavigation),
        if (onOpenGeneration != null)
          RepertoireGenerateButton(onPressed: onOpenGeneration),
        if (isGenerating)
          RepertoireGenerationStatusChip(
            isPaused: isGenerationPaused,
            onTap: onOpenGeneration,
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
    this.onTap,
  });

  final bool isPaused;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: Material(
          color: isPaused
              ? AppColors.warningSurface
              : AppColors.warningSurface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
        ),
      ),
    );
  }
}

class RepertoireGenerateButton extends StatelessWidget {
  const RepertoireGenerateButton({
    super.key,
    required this.onPressed,
  });

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 900;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Center(
        child: compact
            ? ShortcutIconButton(
                description: 'Generate repertoire',
                shortcut: 'G',
                onPressed: onPressed,
                icon: const Icon(Icons.auto_awesome),
              )
            : ShortcutTooltip(
                description: 'Generate repertoire',
                shortcut: 'G',
                child: TextButton.icon(
                  onPressed: onPressed,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Generate'),
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
Future<void> openRepertoireSettings(BuildContext context) {
  return Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const SettingsScreen()),
  );
}
