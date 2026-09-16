/// Embeddable repertoire list with import / rename / delete actions.
///
/// Used both inside [RepertoireSelectionScreen] (full-screen push) and inline
/// in screens that need a repertoire before they can function (Builder, Trainer).
library;

import '../../../l10n/generated/app_localizations.dart';
import 'repertoire_messages.dart';

import 'dart:async';

import '../models/repertoire_creation.dart';
import '../models/repertoire_recovery_entry.dart';
import '../models/repertoire_recovery_required.dart';

import '../../../widgets/common/name_entry_dialog.dart';

import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';

import '../../../widgets/common/item_title.dart';

import '../models/repertoire_metadata.dart';
import '../../../screens/repertoire_chapters_screen.dart';
import 'repertoire_creation_screen.dart';
import 'repertoire_import_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../controllers/repertoire_catalog_controller.dart';
import '../../../widgets/pgn_import_dialog.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_messages.dart';
import '../../../l10n/localized_time.dart';
import '../../../widgets/common/confirm_dialog.dart';
import '../../../widgets/common/list_search_field.dart';
import '../../../widgets/layout/empty_state_placeholder.dart';
import '../../../widgets/chapter_list_body.dart' show ChapterPick;

class RepertoireListBody extends ConsumerStatefulWidget {
  /// Called with the chosen *chapter*'s metadata (a `.pgn` file path). A
  /// repertoire is a folder; tapping one opens its chapter list, and the
  /// selected chapter is what the builder / trainer actually load.
  final ValueChanged<RepertoireMetadata> onSelected;

  /// Called instead of [onSelected] when the user tapped one of the course
  /// chapters the chapter list shows inside a file, with that chapter's
  /// title. Left null, such a tap opens the whole file through [onSelected]
  /// — right for the Builder, whose outline shows the chapters anyway.
  final void Function(RepertoireMetadata chapter, String courseChapter)?
  onCourseChapterSelected;

  /// When set, studies are listed in their own section (as trainable
  /// custom-tactics sets) and tapping one calls this instead.
  final ValueChanged<RepertoireMetadata>? onStudySelected;

  /// Open a folder directly; chapter browsing remains a separate action.
  final ValueChanged<RepertoireMetadata>? onRepertoireSelected;

  final Future<PickedPgnImport?> Function() pickPgn;

  const RepertoireListBody({
    super.key,
    required this.onSelected,
    this.onCourseChapterSelected,
    this.onRepertoireSelected,
    this.onStudySelected,
    this.pickPgn = pickPgnImport,
  });

  @override
  ConsumerState<RepertoireListBody> createState() => _RepertoireListBodyState();
}

class _RepertoireListBodyState extends ConsumerState<RepertoireListBody> {
  AppLocalizations get l10n => AppLocalizations.of(context);

  String _search = '';
  bool _showRecovery = false;
  bool _importing = false;
  bool _pasting = false;

  bool get _includeStudies => widget.onStudySelected != null;
  RepertoireCatalogController get _controller =>
      ref.read(repertoireCatalogProvider(_includeStudies).notifier);
  List<RepertoireMetadata> get _repertoires =>
      ref.read(repertoireCatalogProvider(_includeStudies)).repertoires;
  List<RepertoireMetadata> get _studies =>
      ref.read(repertoireCatalogProvider(_includeStudies)).studies;
  bool get _busy => ref.read(repertoireCatalogProvider(_includeStudies)).busy;
  List<RepertoireMetadata> get _visibleRepertoires =>
      _repertoires.where((r) => matchesSearch(_search, r.name)).toList();
  List<RepertoireMetadata> get _visibleStudies =>
      _studies.where((s) => matchesSearch(_search, s.name)).toList();

  Future<void> _loadRepertoires() => _controller.refresh();

  @override
  void initState() {
    super.initState();
    // A legacy host recreates this widget on re-entry/Refresh. The provider
    // may still be alive in another selector; refresh that shared owner too.
    scheduleMicrotask(() {
      if (mounted) unawaited(_controller.refresh());
    });
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 920),
      child: _buildContents(context),
    ),
  );

  Widget _buildContents(BuildContext context) {
    final catalog = ref.watch(repertoireCatalogProvider(_includeStudies));
    if (catalog.loading && _repertoires.isEmpty && _studies.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final recoveryError = catalog.actionError is RepertoireRecoveryRequired
        ? catalog.actionError
        : null;
    final error = catalog.loadError ?? recoveryError;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 64,
                color: AppColors.danger,
              ),
              const SizedBox(height: 16),
              Text(
                error is RepertoireRecoveryRequired
                    ? l10n.recoveryRequired
                    : l10n.catalogLoadFailed,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadRepertoires,
                icon: const Icon(Icons.refresh),
                label: Text(
                  error is RepertoireRecoveryRequired
                      ? l10n.recoverLibrary
                      : l10n.retry,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_showRecovery) {
      return Column(
        children: [
          _buildToolbar(),
          const Divider(height: 1),
          if (catalog.actionError != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                l10n.restoreFailed,
                style: const TextStyle(color: AppColors.danger),
              ),
            ),
          Expanded(
            child: catalog.recovery.isEmpty
                ? EmptyStatePlaceholder(
                    icon: Icons.restore_from_trash,
                    title: l10n.recoveryEmpty,
                    subtitle: l10n.recoveryEmptyHelp,
                  )
                : ListView(
                    children: [
                      for (final item in catalog.recovery)
                        ListTile(
                          title: Text(item.name),
                          subtitle: Text(
                            item.available
                                ? l10n.deletedAt(
                                    formatLocalizedTimeAgo(
                                      l10n,
                                      item.deletedAt,
                                    ),
                                  )
                                : l10n.recoveryFilesChanged,
                          ),
                          trailing: TextButton.icon(
                            onPressed: _busy || !item.available
                                ? null
                                : () => _restore(item),
                            icon: const Icon(Icons.restore),
                            label: Text(l10n.restore),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      );
    }

    // Keep the import action in the same place for empty and populated lists.
    if (_repertoires.isEmpty && _studies.isEmpty) {
      return Column(
        children: [
          _buildToolbar(),
          const Divider(height: 1, thickness: 1),
          Expanded(
            child: EmptyStatePlaceholder(
              icon: Icons.library_books,
              title: l10n.catalogEmpty,
              subtitle: l10n.catalogEmptyHelp,
            ),
          ),
        ],
      );
    }

    final showSections = _studies.isNotEmpty;
    final repertoires = _visibleRepertoires;
    final studies = _visibleStudies;
    final nothingMatched = repertoires.isEmpty && studies.isEmpty;

    return Column(
      children: [
        _buildToolbar(),
        const Divider(height: 1, thickness: 1),
        Expanded(
          child: nothingMatched
              ? Center(
                  child: Text(
                    l10n.nothingMatches(_search),
                    style: const TextStyle(color: AppColors.onSurfaceMuted),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  children: [
                    if (showSections && repertoires.isNotEmpty)
                      _buildSectionHeader(l10n.repertoires),
                    for (final repertoire in repertoires)
                      _buildRepertoireCard(repertoire),
                    if (showSections && studies.isNotEmpty) ...[
                      _buildSectionHeader(l10n.studiesTactics),
                      for (final study in studies) _buildStudyCard(study),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    final importingFile = _importing && !_pasting;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _showRecovery ? l10n.repertoireRecovery : l10n.yourRepertoires,
            style: AppTextStyles.title,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_controller.supportsRecovery)
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _showRecovery = !_showRecovery);
                          unawaited(_loadRepertoires());
                        },
                  icon: Icon(
                    _showRecovery ? Icons.arrow_back : Icons.restore_from_trash,
                  ),
                  label: Text(
                    _showRecovery ? l10n.backToLibrary : l10n.recovery,
                  ),
                ),
              if (_showRecovery)
                TextButton.icon(
                  onPressed: _busy ? null : _loadRepertoires,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.refresh),
                ),
              if (!_showRecovery) ...[
                FilledButton.icon(
                  onPressed: (_importing || _busy) ? null : _importRepertoire,
                  icon: importingFile
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.folder_open, size: 20),
                  label: Text(
                    importingFile ? l10n.importing : l10n.openPgnFile,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: (_importing || _busy) ? null : _createRepertoire,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.createNewRepertoire),
                ),
                TextButton.icon(
                  onPressed: (_importing || _busy)
                      ? null
                      : () => _importRepertoire(paste: true),
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: Text(l10n.pastePgn),
                ),
              ],
            ],
          ),
          if (!_showRecovery &&
              (_repertoires.isNotEmpty || _studies.isNotEmpty)) ...[
            const SizedBox(height: 16),
            ListSearchField(
              hintText: l10n.searchRepertoires,
              clearLabel: l10n.clearSearch,
              onChanged: (value) {
                if (!mounted) return;
                setState(() => _search = value);
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.onSurfaceMuted,
        ),
      ),
    );
  }

  /// A study listed as a trainable custom-tactics set.  Managing studies
  /// (rename/delete/edit) lives in Study mode, so no actions menu here.
  Widget _buildStudyCard(RepertoireMetadata study) {
    final chapterCount = study.gameCount;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => widget.onStudySelected?.call(study),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceInset,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.menu_book_outlined,
                  color: AppColors.onSurfaceSoft,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ItemTitle(
                      study.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.chapterCount(chapterCount),
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.onSurfaceMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRepertoireCard(RepertoireMetadata repertoire) {
    final name = repertoire.name;
    final chapterCount = repertoire.gameCount;
    final lastModified = repertoire.lastModified;

    final timeAgo = formatLocalizedTimeAgo(l10n, lastModified);

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: const Icon(Icons.library_books_outlined, size: 22),
      title: ItemTitle(name, style: AppTextStyles.bodyStrong),
      subtitle: Text(
        l10n.repertoireDetails(l10n.chapterCount(chapterCount), timeAgo),
        style: AppTextStyles.caption,
      ),
      onTap: () => widget.onRepertoireSelected != null
          ? widget.onRepertoireSelected!(repertoire)
          : _openRepertoire(repertoire),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.list_alt, size: 18),
            tooltip: l10n.browseChapters,
            onPressed: () => _openRepertoire(repertoire),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: l10n.renameRepertoire,
            onPressed: _busy ? null : () => _renameRepertoire(repertoire),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: l10n.deleteRepertoire,
            onPressed: _busy ? null : () => _deleteRepertoire(repertoire),
          ),
        ],
      ),
    );
  }

  // ── Open (drill into chapters) ────────────────────────────────────────

  /// Opens the chapter list for [repertoire]; a chosen chapter is forwarded to
  /// [widget.onSelected] (the contract the builder / trainer already consume).
  Future<void> _openRepertoire(RepertoireMetadata repertoire) async {
    final pick = await Navigator.of(context).push<ChapterPick>(
      MaterialPageRoute(
        builder: (_) => RepertoireChaptersScreen(repertoire: repertoire),
      ),
    );
    if (pick != null && mounted) {
      final courseChapter = pick.courseChapter;
      final onCourseChapter = widget.onCourseChapterSelected;
      if (courseChapter != null && onCourseChapter != null) {
        onCourseChapter(pick.chapter, courseChapter);
      } else {
        widget.onSelected(pick.chapter);
      }
    } else if (mounted) {
      // Chapters may have been added/removed while browsing.
      await _loadRepertoires();
    }
  }

  Future<void> _createRepertoire() async {
    final created = await Navigator.of(context).push<RepertoireCreationResult>(
      MaterialPageRoute(
        builder: (_) => RepertoireCreationScreen(
          pickPgn: widget.pickPgn,
          create: _controller.create,
        ),
      ),
    );
    if (!mounted || created == null) return;
    await _loadRepertoires();
    if (!mounted) return;
    if (created.gameCount == 0) {
      showAppSnackBar(
        context,
        l10n.createdRepertoire(p.basename(created.directoryPath)),
      );
      return;
    }
    await _openCreated(created);
  }

  Future<void> _openCreated(RepertoireCreationResult created) async {
    if (created.chapterPaths.length > 1) {
      await _openRepertoire(
        RepertoireMetadata(
          filePath: created.directoryPath,
          name: p.basename(created.directoryPath),
          gameCount: created.chapterPaths.length,
          lastModified: DateTime.now(),
        ),
      );
    } else {
      widget.onSelected(
        RepertoireMetadata(
          filePath: created.chapterPath,
          name: p.basenameWithoutExtension(created.chapterPath),
          gameCount: created.gameCount,
          lastModified: DateTime.now(),
        ),
      );
    }
  }

  Future<void> _importRepertoire({bool paste = false}) async {
    if (!mounted || _importing) return;
    setState(() {
      _importing = true;
      _pasting = paste;
    });
    try {
      final names = _repertoires.map((r) => r.name).toList();
      final created = paste
          ? await showRepertoirePasteDialog(
              context,
              existingNames: names,
              create: _controller.create,
            )
          : await showRepertoireImportDialog(
              context,
              existingNames: names,
              create: _controller.create,
              pickPgn: widget.pickPgn,
            );
      if (created == null || !mounted) return;
      showAppSnackBar(
        context,
        l10n.importedRepertoire(p.basename(created.directoryPath)),
      );
      await _openCreated(created);
      if (mounted) await _loadRepertoires();
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _restore(RepertoireRecoveryEntry entry) async {
    final name = await showNameEntryDialog(
      context,
      title: l10n.restoreRepertoire,
      prompt: l10n.restoreNamePrompt,
      fieldLabel: l10n.repertoireName,
      cancelLabel: l10n.cancel,
      emptyNameMessage: l10n.nameRequired,
      confirmLabel: l10n.restore,
      allowUnchanged: true,
      initialValue: entry.name,
      validate: (name) =>
          repertoireNameProblem(l10n, name) ??
          (_repertoires.any(
                (r) =>
                    p.equals(
                      p.dirname(r.filePath),
                      p.dirname(entry.originalPath),
                    ) &&
                    r.name.toLowerCase() == name.toLowerCase(),
              )
              ? l10n.duplicateRepertoireName
              : null),
    );
    if (name == null || !mounted) return;
    try {
      await _controller.restore(entry.id, name: name);
    } catch (_) {
      // The catalog owns the persistent error and recovery action.
    }
  }

  Future<void> _deleteRepertoire(RepertoireMetadata repertoire) async {
    final confirmed = await confirmAction(
      context,
      title: l10n.deleteRepertoirePrompt(repertoire.name),
      message: _controller.supportsRecovery
          ? l10n.deleteRepertoireHelp
          : l10n.deleteLegacyRepertoireHelp,
      confirmLabel: l10n.delete,
      cancelLabel: l10n.cancel,
    );

    if (confirmed && mounted) {
      try {
        await _controller.moveToRecovery(repertoire);
      } catch (e) {
        debugPrint('Delete repertoire failed: $e');
        if (mounted && e is! RepertoireRecoveryRequired) {
          showAppSnackBar(context, l10n.deleteRepertoireFailed, isError: true);
        }
      }
    }
  }

  Future<void> _renameRepertoire(RepertoireMetadata repertoire) async {
    final result = await showNameEntryDialog(
      context,
      title: l10n.renameRepertoire,
      prompt: l10n.renameRepertoirePrompt,
      fieldLabel: l10n.repertoireName,
      cancelLabel: l10n.cancel,
      emptyNameMessage: l10n.nameRequired,
      confirmLabel: l10n.rename,
      initialValue: repertoire.name,
      validate: (name) =>
          repertoireNameProblem(l10n, name) ??
          (_repertoires.any(
                (r) =>
                    r.name.toLowerCase() == name.toLowerCase() &&
                    r.filePath != repertoire.filePath,
              )
              ? l10n.repertoireExists(name)
              : null),
    );

    if (mounted && result != null && result.isNotEmpty) {
      try {
        await _controller.rename(repertoire, result);
      } catch (e) {
        debugPrint('Rename repertoire failed: $e');
        if (mounted && e is! RepertoireRecoveryRequired) {
          showAppSnackBar(context, l10n.renameRepertoireFailed, isError: true);
        }
      }
    }
  }
}
