import 'package:flutter/material.dart';

import '../../constants/ui_breakpoints.dart';
import '../../screens/settings_screen.dart';
import '../../theme/app_colors.dart';
import '../app_mode_menu_button.dart';
import '../layout/board_zone.dart';

/// App bar for the repertoire screen: title, generation status, and actions.
///
/// Actions are grouped by workflow, not by feature:
/// - the title doubles as the repertoire switcher,
/// - a pick-then-run control ([RepertoireActionRunner]) is the single entry
///   point for every repertoire action (generate, build from games, import
///   PGN, audit): a dropdown chooses the action, a "Run" button fires it,
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
        if (onOpenGeneration != null || onOpenAudit != null)
          RepertoireActionRunner(
            onGenerate: onOpenGeneration,
            onBuildFromGames: onBuildFromGames,
            onImportPgnFile: onImportPgnFile,
            onImportPgnPaste: onImportPgnPaste,
            onOpenAudit: onOpenAudit,
          ),
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

/// A repertoire action the user can pick from the runner dropdown.
class _RepAction {
  const _RepAction(
    this.id,
    this.label,
    this.icon,
    this.onRun,
  );

  final String id;
  final String label;
  final IconData icon;
  final VoidCallback onRun;
}

/// Pick-then-run control for repertoire actions (generate, add lines, audit).
///
/// A dropdown selects *which* action; a separate "Run" button executes it.
/// Splitting the picker from the trigger means opening the menu can never fire
/// a heavy action (e.g. Generate) by accident — the failure mode of the old
/// split button.
class RepertoireActionRunner extends StatefulWidget {
  const RepertoireActionRunner({
    super.key,
    this.onGenerate,
    this.onBuildFromGames,
    this.onImportPgnFile,
    this.onImportPgnPaste,
    this.onOpenAudit,
  });

  final VoidCallback? onGenerate;
  final VoidCallback? onBuildFromGames;
  final VoidCallback? onImportPgnFile;
  final VoidCallback? onImportPgnPaste;
  final VoidCallback? onOpenAudit;

  @override
  State<RepertoireActionRunner> createState() => _RepertoireActionRunnerState();
}

class _RepertoireActionRunnerState extends State<RepertoireActionRunner> {
  String? _selectedId;

  List<_RepAction> get _actions => [
        if (widget.onGenerate != null)
          _RepAction('generate', 'Generate', Icons.auto_awesome,
              widget.onGenerate!),
        if (widget.onBuildFromGames != null)
          _RepAction('from_games', 'From my games',
              Icons.download_for_offline_outlined, widget.onBuildFromGames!),
        if (widget.onImportPgnFile != null)
          _RepAction('import_pgn_file', 'Import PGN file', Icons.file_open,
              widget.onImportPgnFile!),
        if (widget.onImportPgnPaste != null)
          _RepAction('import_pgn_paste', 'Paste PGN', Icons.paste,
              widget.onImportPgnPaste!),
        if (widget.onOpenAudit != null)
          _RepAction('audit', 'Audit for gaps', Icons.policy_outlined,
              widget.onOpenAudit!),
      ];

  @override
  Widget build(BuildContext context) {
    final actions = _actions;
    if (actions.isEmpty) return const SizedBox.shrink();

    // Keep the selection valid as the available actions change.
    var selectedId = _selectedId;
    if (selectedId == null || !actions.any((a) => a.id == selectedId)) {
      selectedId = actions.first.id;
    }
    final selected = actions.firstWhere((a) => a.id == selectedId);

    final theme = Theme.of(context);
    final compact =
        MediaQuery.sizeOf(context).width < kToolbarCompactBreakpoint;

    final dropdown = DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: selectedId,
        isDense: true,
        borderRadius: BorderRadius.circular(8),
        onChanged: (value) => setState(() => _selectedId = value),
        selectedItemBuilder: (_) => [
          for (final a in actions)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(a.icon, size: 18),
                const SizedBox(width: 6),
                Text(a.label),
              ],
            ),
        ],
        items: [
          for (final a in actions)
            DropdownMenuItem(
              value: a.id,
              child: Row(
                children: [
                  Icon(a.icon, size: 20),
                  const SizedBox(width: 10),
                  Text(a.label),
                ],
              ),
            ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: 'Choose action',
              waitDuration: const Duration(milliseconds: 600),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: dropdown,
              ),
            ),
            const SizedBox(width: 6),
            if (compact)
              IconButton.filledTonal(
                tooltip: 'Run ${selected.label}',
                onPressed: selected.onRun,
                iconSize: 18,
                icon: const Icon(Icons.play_arrow),
              )
            else
              FilledButton.tonalIcon(
                onPressed: selected.onRun,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Run'),
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

/// Opens global settings from the repertoire toolbar.
Future<void> openRepertoireSettings(BuildContext context) {
  return Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const SettingsScreen()),
  );
}
