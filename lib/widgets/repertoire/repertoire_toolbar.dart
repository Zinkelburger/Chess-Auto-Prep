import 'package:flutter/material.dart';

import '../../constants/ui_breakpoints.dart';
import '../../screens/settings_screen.dart';
import '../../theme/app_colors.dart';
import '../app_mode_menu_button.dart';
import '../shortcut_tooltip.dart';
import '../layout/board_zone.dart';

/// App bar for the repertoire screen: title, generation status, and actions.
///
/// Actions are grouped by workflow, not by feature:
/// - the title doubles as the repertoire switcher,
/// - "Generate ▾" is the single entry point for adding lines (generate,
///   build from games, import PGN),
/// - Train is the primary (filled) action,
/// - everything occasional lives in the trailing overflow menu.
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
    required this.onOpenSettings,
    this.onSelectRepertoire,
    this.onTrainRepertoire,
    this.onOpenGeneration,
    this.onBuildFromGames,
    this.onOpenAudit,
    this.onImportPgnFile,
    this.onImportPgnPaste,
    this.isWhiteRepertoire,
    this.onSwitchColor,
  });

  final Widget title;
  final bool isGenerating;
  final bool isGenerationPaused;
  final bool showTrainButton;
  final bool showSelectRepertoireAction;
  final bool generationLocked;
  final Widget? trapNavigation;
  final VoidCallback onOpenSettings;
  final VoidCallback? onSelectRepertoire;
  final VoidCallback? onTrainRepertoire;
  final VoidCallback? onOpenGeneration;
  final VoidCallback? onBuildFromGames;
  final VoidCallback? onOpenAudit;
  final VoidCallback? onImportPgnFile;
  final VoidCallback? onImportPgnPaste;
  final bool? isWhiteRepertoire;
  final VoidCallback? onSwitchColor;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  bool get _titleIsSwitcher =>
      showSelectRepertoireAction && onSelectRepertoire != null;

  bool get _hasAddSources =>
      onBuildFromGames != null ||
      onImportPgnFile != null ||
      onImportPgnPaste != null;

  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 16,
      title: _titleIsSwitcher
          ? RepertoireSwitcherTitle(
              title: title,
              onTap: generationLocked ? null : onSelectRepertoire,
            )
          : title,
      actions: [
        BoardZoneControls(trapNavigation: trapNavigation),
        if (isGenerating)
          RepertoireGenerationStatusChip(
            isPaused: isGenerationPaused,
            onTap: onOpenGeneration,
          ),
        if (onOpenGeneration != null)
          RepertoireAddLinesButton(
            onGenerate: onOpenGeneration,
            onBuildFromGames: onBuildFromGames,
            onImportPgnFile: onImportPgnFile,
            onImportPgnPaste: onImportPgnPaste,
            showMenu: _hasAddSources,
          ),
        if (onOpenAudit != null) RepertoireAuditButton(onPressed: onOpenAudit),
        if (showTrainButton && onTrainRepertoire != null)
          RepertoireTrainButton(
            onPressed: generationLocked ? null : onTrainRepertoire,
          ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 20),
          tooltip: 'More actions',
          onSelected: (value) {
            switch (value) {
              case 'switch_color':
                onSwitchColor?.call();
              case 'settings':
                onOpenSettings();
            }
          },
          itemBuilder: (_) => [
            if (isWhiteRepertoire != null && onSwitchColor != null)
              PopupMenuItem(
                value: 'switch_color',
                child: ListTile(
                  leading: Icon(
                    Icons.circle,
                    size: 20,
                    color: isWhiteRepertoire! ? Colors.black : Colors.white,
                  ),
                  title: Text(
                    'Switch to ${isWhiteRepertoire! ? 'Black' : 'White'}',
                  ),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            const PopupMenuItem(
              value: 'settings',
              child: ListTile(
                leading: Icon(Icons.settings, size: 20),
                title: Text('Settings'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
        const AppModeMenuButton(),
      ],
    );
  }
}

/// Title wrapper that doubles as the repertoire switcher.
class RepertoireSwitcherTitle extends StatelessWidget {
  const RepertoireSwitcherTitle({
    super.key,
    required this.title,
    required this.onTap,
  });

  final Widget title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Switch repertoire',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: title),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down,
                size: 20,
                color: onTap == null ? Colors.grey[700] : Colors.grey[400],
              ),
            ],
          ),
        ),
      ),
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

/// Split button: "Generate" as the default action, with a dropdown listing
/// the other ways to add lines (from games, import file, paste PGN).
class RepertoireAddLinesButton extends StatelessWidget {
  const RepertoireAddLinesButton({
    super.key,
    required this.onGenerate,
    this.onBuildFromGames,
    this.onImportPgnFile,
    this.onImportPgnPaste,
    this.showMenu = true,
  });

  final VoidCallback? onGenerate;
  final VoidCallback? onBuildFromGames;
  final VoidCallback? onImportPgnFile;
  final VoidCallback? onImportPgnPaste;
  final bool showMenu;

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < kToolbarCompactBreakpoint;

    final menuItems = <PopupMenuEntry<String>>[
      if (compact)
        const PopupMenuItem(
          value: 'generate',
          child: ListTile(
            leading: Icon(Icons.auto_awesome, size: 20),
            title: Text('Generate'),
            trailing:
                Text('G', style: TextStyle(fontSize: 12, color: Colors.grey)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      if (onBuildFromGames != null)
        const PopupMenuItem(
          value: 'from_games',
          child: ListTile(
            leading: Icon(Icons.download_for_offline_outlined, size: 20),
            title: Text('From my games'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      if (onImportPgnFile != null)
        const PopupMenuItem(
          value: 'import_pgn_file',
          child: ListTile(
            leading: Icon(Icons.file_open, size: 20),
            title: Text('Import PGN file'),
            trailing:
                Text('I', style: TextStyle(fontSize: 12, color: Colors.grey)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      if (onImportPgnPaste != null)
        const PopupMenuItem(
          value: 'import_pgn_paste',
          child: ListTile(
            leading: Icon(Icons.paste, size: 20),
            title: Text('Paste PGN'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
    ];

    void onSelected(String value) {
      switch (value) {
        case 'generate':
          onGenerate?.call();
        case 'from_games':
          onBuildFromGames?.call();
        case 'import_pgn_file':
          onImportPgnFile?.call();
        case 'import_pgn_paste':
          onImportPgnPaste?.call();
      }
    }

    if (compact) {
      // One toolbar slot: sparkles icon opens the full add-lines menu.
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Center(
          child: PopupMenuButton<String>(
            icon: const Icon(Icons.auto_awesome, size: 20),
            tooltip: 'Add lines',
            onSelected: onSelected,
            itemBuilder: (_) => menuItems,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShortcutTooltip(
              description: 'Generate repertoire',
              shortcut: 'G',
              child: TextButton.icon(
                onPressed: onGenerate,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Generate'),
              ),
            ),
            if (showMenu)
              PopupMenuButton<String>(
                icon: const Icon(Icons.arrow_drop_down, size: 20),
                tooltip: 'More ways to add lines',
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                onSelected: onSelected,
                itemBuilder: (_) => menuItems,
              ),
          ],
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
    final compact =
        MediaQuery.sizeOf(context).width < kToolbarCompactBreakpoint;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: compact
            ? IconButton.filled(
                tooltip: 'Train repertoire',
                onPressed: onPressed,
                iconSize: 18,
                icon: const Icon(Icons.school),
              )
            : FilledButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.school, size: 18),
                label: const Text('Train'),
              ),
      ),
    );
  }
}

class RepertoireAuditButton extends StatelessWidget {
  const RepertoireAuditButton({
    super.key,
    required this.onPressed,
  });

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: ShortcutIconButton(
          description: 'Audit repertoire',
          shortcut: 'A',
          onPressed: onPressed,
          icon: const Icon(Icons.policy_outlined, size: 20),
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
