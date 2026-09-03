import 'package:flutter/material.dart';

import '../../../constants/ui_breakpoints.dart';
import '../../../models/repertoire_metadata.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/app_breadcrumb_trail.dart';
import '../../../widgets/app_mode_switcher.dart';
import '../../../widgets/app_overflow_menu.dart';
import '../../../widgets/common/searchable_picker_dialog.dart';
import '../../../widgets/layout/board_zone.dart';

/// App bar for the repertoire screen: title, generation status, and actions.
///
/// Four controls, in the order they are reached for:
/// - the title doubles as the repertoire/chapter switcher,
/// - one "Add lines" menu ([RepertoireAddLinesMenu]) holds every way of
///   putting moves into the repertoire,
/// - Train is the primary (filled) action,
/// - everything else — Audit and both settings dialogs — lives in the
///   trailing overflow menu. Audit used to sit in the bar as a button of
///   its own; six controls read as a wall, and it is a check on what is
///   already there rather than something you reach for while building.
///
/// Chapters are reached from the breadcrumb title, which already lists them
/// with a search box — the bar's separate Chapters icon went nowhere the
/// title did not.
class RepertoireToolbar extends StatelessWidget implements PreferredSizeWidget {
  const RepertoireToolbar({
    super.key,
    required this.title,
    this.isGenerating = false,
    this.isGenerationPaused = false,
    this.isExpectimaxProbe = false,
    this.showTrainButton = false,
    this.showSelectRepertoireAction = false,
    this.generationLocked = false,
    this.trapNavigation,
    required this.onOpenSettings,
    this.onSelectRepertoire,
    this.onTrainRepertoire,
    this.onOpenGeneration,
    this.onPlanBuild,
    this.onBuildByPlaying,
    this.onBuildFromGames,
    this.onOpenAudit,
    this.onImportPgn,
    this.isWhiteRepertoire,
    this.onOpenRepertoireOptions,
  });

  final Widget title;
  final bool isGenerating;
  final bool isGenerationPaused;

  /// The running build is an on-demand expectimax probe, not a repertoire
  /// build — the chip says so.
  final bool isExpectimaxProbe;
  final bool showTrainButton;
  final bool showSelectRepertoireAction;
  final bool generationLocked;
  final Widget? trapNavigation;
  final VoidCallback onOpenSettings;
  final VoidCallback? onSelectRepertoire;
  final VoidCallback? onTrainRepertoire;
  final VoidCallback? onOpenGeneration;
  final VoidCallback? onPlanBuild;
  final VoidCallback? onBuildByPlaying;
  final VoidCallback? onBuildFromGames;
  final VoidCallback? onOpenAudit;
  final VoidCallback? onImportPgn;
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
        if (isGenerating)
          RepertoireGenerationStatusChip(
            isPaused: isGenerationPaused,
            label: isExpectimaxProbe ? 'Computing expectimax…' : null,
            onTap: onOpenGeneration,
          ),
        RepertoireAddLinesMenu(
          onPlanBuild: onPlanBuild,
          onGenerate: onOpenGeneration,
          onBuildByPlaying: onBuildByPlaying,
          onBuildFromGames: onBuildFromGames,
          onImportPgn: onImportPgn,
        ),
        if (showTrainButton && onTrainRepertoire != null)
          RepertoireTrainButton(
            onPressed: generationLocked ? null : onTrainRepertoire,
          ),
        const AppModeSwitcher(),
        AppOverflowMenu(
          entries: [
            if (onOpenAudit != null)
              AppMenuEntry(
                label: 'Audit for gaps…',
                icon: Icons.policy_outlined,
                onRun: onOpenAudit!,
              ),
            if (onOpenRepertoireOptions != null)
              AppMenuEntry(
                label: 'Repertoire settings…',
                // Bordered swatch, not a bare Icon: the sideBlack disc is
                // near-invisible on the popup surface without an outline.
                leading: _SideSwatch(isWhite: isWhiteRepertoire ?? true),
                onRun: onOpenRepertoireOptions!,
                dividerAbove: true,
              ),
            AppMenuEntry(
              label: 'App settings…',
              icon: Icons.settings,
              onRun: onOpenSettings,
              dividerAbove: onOpenRepertoireOptions == null,
            ),
          ],
        ),
      ],
    );
  }
}

/// The side-to-play disc shown beside "Repertoire settings…".
class _SideSwatch extends StatelessWidget {
  const _SideSwatch({required this.isWhite});

  final bool isWhite;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isWhite ? AppColors.sideWhite : AppColors.sideBlack,
        border: Border.all(color: AppColors.outline),
      ),
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
    this.label,
  });

  final bool isPaused;
  final VoidCallback? onTap;

  /// Replaces "Building..." while running (e.g. an expectimax probe).
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: Material(
          color: AppColors.surfaceInset,
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
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(
                      Icons.pause,
                      size: 12,
                      color: AppColors.onSurfaceSoft,
                    ),
                  const SizedBox(width: 6),
                  Text(
                    isPaused ? 'Paused' : (label ?? 'Building...'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceSoft,
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

/// The one place every way of *adding lines* to a repertoire lives: plan a
/// build, generate from the board, play the moves yourself, mine your own
/// games, or load a PGN off disk. One tap opens the menu, one tap runs the
/// item — every entry opens its own configuration step or picker first, so
/// nothing heavy can fire by accident.
///
/// Rows are labels only — no explaining sentence, and no leading icon. The
/// icons were decoration: a sparkle, a gamepad and a download arrow that no
/// reader can tell apart faster than they can read five short labels, and
/// that each suggested the wrong thing (the gamepad read as "play a game",
/// not "author lines by playing them"). The label is the discriminator, so
/// it is the only thing here.
///
/// The rows are ordered in two families — three verbs for making moves at
/// the board, then two sources the moves come out of — and the labels carry
/// that on their own. There is no rule between them: a five-row menu does
/// not need furniture to be read. ("Plan a build" and "Import PGN" were the
/// two labels that broke the pattern — "a build" is the pipeline's word for
/// itself, and "Import" named the transport rather than where the lines
/// come from.)
class RepertoireAddLinesMenu extends StatelessWidget {
  const RepertoireAddLinesMenu({
    super.key,
    this.onPlanBuild,
    this.onGenerate,
    this.onBuildByPlaying,
    this.onBuildFromGames,
    this.onImportPgn,
  });

  final VoidCallback? onPlanBuild;
  final VoidCallback? onGenerate;
  final VoidCallback? onBuildByPlaying;
  final VoidCallback? onBuildFromGames;
  final VoidCallback? onImportPgn;

  List<AppMenuEntry> get _entries => [
    if (onPlanBuild != null)
      AppMenuEntry(label: 'Plan the lines…', onRun: onPlanBuild!),
    if (onGenerate != null)
      AppMenuEntry(label: 'Generate from here…', onRun: onGenerate!),
    // Named for what the user does, not for the mode's internal name: the
    // one thing that separates it from Generate is who chooses our moves.
    if (onBuildByPlaying != null)
      AppMenuEntry(label: 'Play the moves myself…', onRun: onBuildByPlaying!),
    if (onBuildFromGames != null)
      AppMenuEntry(label: 'From my games…', onRun: onBuildFromGames!),
    // One entry, not the old "Load from disk…" / "Paste PGN…" pair: the
    // dialog it opens offers both, so the menu no longer asks the user to
    // pick a transport before it will show them the import.
    if (onImportPgn != null)
      AppMenuEntry(label: 'From a PGN…', onRun: onImportPgn!),
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
                onPressed: e.onRun,
                child: Text(e.label, style: const TextStyle(fontSize: 13)),
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
