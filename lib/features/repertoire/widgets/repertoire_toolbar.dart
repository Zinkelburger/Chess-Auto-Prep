import 'package:flutter/material.dart';

import '../../../constants/ui_breakpoints.dart';
import '../../../models/repertoire_metadata.dart';
import '../../../screens/settings_screen.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/app_breadcrumb_trail.dart';
import '../../../widgets/app_mode_menu_button.dart';
import '../../../widgets/common/searchable_picker_dialog.dart';
import '../../../widgets/layout/board_zone.dart';

/// App bar for the repertoire screen: title, generation status, and actions.
///
/// Actions are grouped by workflow, not by feature:
/// - the title doubles as the repertoire switcher,
/// - one "Add lines" menu ([RepertoireAddLinesMenu]) holds every way of
///   putting moves into the repertoire (generate, build by playing, from
///   games, import/paste PGN); Audit stands beside it as a check on what is
///   already there,
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
    this.showChaptersAction = false,
    this.generationLocked = false,
    this.trapNavigation,
    required this.onOpenSettings,
    this.onSelectRepertoire,
    this.onOpenChapters,
    this.onTrainRepertoire,
    this.onOpenGeneration,
    this.onPlanBuild,
    this.onBuildByPlaying,
    this.onBuildFromGames,
    this.onOpenAudit,
    this.onImportPgnFile,
    this.onImportPgnPaste,
    this.isWhiteRepertoire,
    this.onOpenRepertoireOptions,
  });

  final Widget title;
  final bool isGenerating;
  final bool isGenerationPaused;
  final bool showTrainButton;
  final bool showSelectRepertoireAction;
  final bool showChaptersAction;
  final bool generationLocked;
  final Widget? trapNavigation;
  final VoidCallback onOpenSettings;
  final VoidCallback? onSelectRepertoire;
  final VoidCallback? onOpenChapters;
  final VoidCallback? onTrainRepertoire;
  final VoidCallback? onOpenGeneration;
  final VoidCallback? onPlanBuild;
  final VoidCallback? onBuildByPlaying;
  final VoidCallback? onBuildFromGames;
  final VoidCallback? onOpenAudit;
  final VoidCallback? onImportPgnFile;
  final VoidCallback? onImportPgnPaste;
  final bool? isWhiteRepertoire;

  /// Opens the settings dialog for the open repertoire (side played, board
  /// size). Deliberately two clicks away — flipping the side rewrites which
  /// moves count as ours.
  final VoidCallback? onOpenRepertoireOptions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  bool get _titleIsSwitcher =>
      showSelectRepertoireAction && onSelectRepertoire != null;

  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 16,
      title: AppBarTitleWithTrail(
        title: _titleIsSwitcher
            ? RepertoireSwitcherTitle(
                title: title,
                onTap: generationLocked ? null : onSelectRepertoire,
              )
            : title,
      ),
      actions: [
        BoardZoneControls(trapNavigation: trapNavigation),
        if (showChaptersAction && onOpenChapters != null)
          IconButton(
            tooltip: 'Chapters',
            icon: const Icon(Icons.menu_book, size: 20),
            onPressed: generationLocked ? null : onOpenChapters,
          ),
        if (isGenerating)
          RepertoireGenerationStatusChip(
            isPaused: isGenerationPaused,
            onTap: onOpenGeneration,
          ),
        RepertoireAddLinesMenu(
          onPlanBuild: onPlanBuild,
          onGenerate: onOpenGeneration,
          onBuildByPlaying: onBuildByPlaying,
          onBuildFromGames: onBuildFromGames,
          onImportPgnFile: onImportPgnFile,
          onImportPgnPaste: onImportPgnPaste,
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
              case 'repertoire_options':
                onOpenRepertoireOptions?.call();
              case 'settings':
                onOpenSettings();
            }
          },
          itemBuilder: (_) => [
            if (onOpenRepertoireOptions != null)
              PopupMenuItem(
                value: 'repertoire_options',
                child: ListTile(
                  // Bordered swatch, not a bare Icon: the sideBlack disc is
                  // near-invisible on the popup surface without an outline.
                  leading: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (isWhiteRepertoire ?? true)
                          ? AppColors.sideWhite
                          : AppColors.sideBlack,
                      border: Border.all(color: AppColors.outline),
                    ),
                  ),
                  title: const Text('Repertoire settings…'),
                  subtitle: isWhiteRepertoire == null
                      ? null
                      : Text(
                          'Playing ${isWhiteRepertoire! ? 'White' : 'Black'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            const PopupMenuItem(
              value: 'settings',
              child: ListTile(
                leading: Icon(Icons.settings, size: 20),
                title: Text('App settings…'),
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
                color: onTap == null
                    ? AppColors.onSurfaceDisabled
                    : AppColors.onSurfaceSoft,
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

/// Breadcrumb title for the builder: `Repertoire ▸ Chapter ▾`.
///
/// The repertoire segment switches repertoires; the chapter segment opens a
/// dropdown of sibling chapters (current one checked, with line counts) plus
/// "Add chapter" and "View all chapters" actions. This makes the folder →
/// chapter hierarchy visible at all times and turns chapter switching into a
/// single click instead of a full-screen detour.
class RepertoireBreadcrumbTitle extends StatelessWidget {
  const RepertoireBreadcrumbTitle({
    super.key,
    required this.repertoireName,
    required this.chapterName,
    required this.chapters,
    required this.currentChapterPath,
    this.onSwitchRepertoire,
    required this.onSelectChapter,
    this.onAddChapter,
    this.onViewChapters,
    this.enabled = true,
  });

  final String repertoireName;
  final String chapterName;
  final List<RepertoireMetadata> chapters;
  final String? currentChapterPath;
  final VoidCallback? onSwitchRepertoire;
  final ValueChanged<RepertoireMetadata> onSelectChapter;
  final VoidCallback? onAddChapter;
  final VoidCallback? onViewChapters;
  final bool enabled;

  static const _addValue = '__add_chapter__';
  static const _viewAllValue = '__view_chapters__';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repTap = enabled ? onSwitchRepertoire : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Repertoire Builder',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[500]),
        ),
        const SizedBox(height: 1),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Tooltip(
                message: 'Switch repertoire',
                waitDuration: const Duration(milliseconds: 600),
                child: InkWell(
                  onTap: repTap,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Text(
                      repertoireName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: Colors.grey[500]),
            Flexible(child: _buildChapterMenu(context, theme)),
          ],
        ),
      ],
    );
  }

  Widget _buildChapterMenu(BuildContext context, ThemeData theme) {
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              chapterName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(
            Icons.arrow_drop_down,
            size: 20,
            color: enabled ? Colors.grey[400] : Colors.grey[700],
          ),
        ],
      ),
    );

    if (!enabled) return child;

    // A searchable dialog rather than a popup menu: a real repertoire runs to
    // dozens of chapters, and a menu has nowhere to put a text box. The two
    // actions ride along as rows so nothing is lost in the swap.
    return Tooltip(
      message: 'Switch chapter',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => _openChapterPicker(context),
        child: child,
      ),
    );
  }

  Future<void> _openChapterPicker(BuildContext context) async {
    final picked = await showSearchablePicker<String>(
      context: context,
      title: 'Switch chapter',
      searchHint: 'Search chapters',
      selected: currentChapterPath,
      items: [
        for (final c in chapters)
          PickerItem(
            value: c.filePath,
            label: c.name,
            subtitle: '${c.gameCount} line${c.gameCount == 1 ? '' : 's'}',
            icon: Icons.bookmark_outline,
            // The counts are noise to type against; chapters are found by
            // name.
            searchText: c.name,
          ),
        const PickerItem(
          value: _addValue,
          label: 'Add chapter',
          icon: Icons.add,
        ),
        const PickerItem(
          value: _viewAllValue,
          label: 'View all chapters',
          icon: Icons.list_alt,
        ),
      ],
      emptyMessage: 'This repertoire has no chapters yet.',
    );

    if (picked == null) return;
    if (picked == _addValue) {
      onAddChapter?.call();
      return;
    }
    if (picked == _viewAllValue) {
      onViewChapters?.call();
      return;
    }
    for (final c in chapters) {
      if (c.filePath == picked) {
        onSelectChapter(c);
        return;
      }
    }
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
                        color: AppColors.onWarning,
                      ),
                    )
                  else
                    const Icon(
                      Icons.pause,
                      size: 12,
                      color: AppColors.onWarning,
                    ),
                  const SizedBox(width: 6),
                  Text(
                    isPaused ? 'Paused' : 'Building...',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.onWarning,
                    ),
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

/// One entry in the "Add lines" menu.
class _AddLinesEntry {
  const _AddLinesEntry(this.label, this.icon, this.onRun, {this.hint});

  final String label;
  final IconData icon;
  final VoidCallback onRun;
  final String? hint;
}

/// The one place every way of *adding lines* to a repertoire lives: generate
/// with the engine, build by playing, mine your own games, import or paste a
/// PGN. One tap opens the menu, one tap runs the item — every entry opens its
/// own configuration step or picker first, so nothing heavy can fire by
/// accident and there is no separate "Run" step to explain.
class RepertoireAddLinesMenu extends StatelessWidget {
  const RepertoireAddLinesMenu({
    super.key,
    this.onPlanBuild,
    this.onGenerate,
    this.onBuildByPlaying,
    this.onBuildFromGames,
    this.onImportPgnFile,
    this.onImportPgnPaste,
  });

  final VoidCallback? onPlanBuild;
  final VoidCallback? onGenerate;
  final VoidCallback? onBuildByPlaying;
  final VoidCallback? onBuildFromGames;
  final VoidCallback? onImportPgnFile;
  final VoidCallback? onImportPgnPaste;

  List<_AddLinesEntry> get _entries => [
    if (onPlanBuild != null)
      _AddLinesEntry(
        'Plan a build…',
        Icons.route_outlined,
        onPlanBuild!,
        hint: 'Answer a few forks; get chapters, then generate them all',
      ),
    if (onGenerate != null)
      _AddLinesEntry(
        'Generate from here…',
        Icons.auto_awesome,
        onGenerate!,
        hint: 'One engine build from the board position',
      ),
    if (onBuildByPlaying != null)
      _AddLinesEntry(
        'Build by playing',
        Icons.sports_esports,
        onBuildByPlaying!,
        hint: 'Play your moves; the app answers',
      ),
    if (onBuildFromGames != null)
      _AddLinesEntry(
        'From my games…',
        Icons.download_for_offline_outlined,
        onBuildFromGames!,
        hint: 'Mine lines you already play',
      ),
    if (onImportPgnFile != null)
      _AddLinesEntry('Import PGN file…', Icons.file_open, onImportPgnFile!),
    if (onImportPgnPaste != null)
      _AddLinesEntry('Paste PGN…', Icons.paste, onImportPgnPaste!),
  ];

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    if (entries.isEmpty) return const SizedBox.shrink();
    final compact =
        MediaQuery.sizeOf(context).width < kToolbarCompactBreakpoint;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: MenuAnchor(
          menuChildren: [
            for (final e in entries)
              MenuItemButton(
                leadingIcon: Icon(e.icon, size: 20),
                onPressed: e.onRun,
                child: e.hint == null
                    ? Text(e.label)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(e.label),
                          Text(
                            e.hint!,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: AppColors.onSurfaceMuted),
                          ),
                        ],
                      ),
              ),
          ],
          builder: (context, controller, _) {
            void toggle() =>
                controller.isOpen ? controller.close() : controller.open();
            return compact
                ? IconButton.filledTonal(
                    tooltip: 'Add lines',
                    onPressed: toggle,
                    iconSize: 18,
                    icon: const Icon(Icons.add),
                  )
                : FilledButton.tonalIcon(
                    onPressed: toggle,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Add lines'),
                        SizedBox(width: 2),
                        Icon(Icons.arrow_drop_down, size: 18),
                      ],
                    ),
                  );
          },
        ),
      ),
    );
  }
}

/// Audit is a check on what is already there, not a way of adding lines, so
/// it stands beside the menu rather than inside it.
class RepertoireAuditButton extends StatelessWidget {
  const RepertoireAuditButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < kToolbarCompactBreakpoint;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: compact
            ? IconButton.outlined(
                tooltip: 'Audit for gaps',
                onPressed: onPressed,
                iconSize: 18,
                icon: const Icon(Icons.policy_outlined),
              )
            : OutlinedButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.policy_outlined, size: 18),
                label: const Text('Audit'),
              ),
      ),
    );
  }
}

class RepertoireTrainButton extends StatelessWidget {
  const RepertoireTrainButton({super.key, required this.onPressed});

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
