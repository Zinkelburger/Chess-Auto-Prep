/// Embeddable repertoire list with import / rename / delete actions.
///
/// Used both inside [RepertoireSelectionScreen] (full-screen push) and inline
/// in screens that need a repertoire before they can function (Builder, Trainer).
library;

import 'common/name_entry_dialog.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/repertoire_metadata.dart';
import '../screens/repertoire_chapters_screen.dart';
import '../features/repertoire/widgets/repertoire_import_dialog.dart';
import '../services/storage/storage_factory.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../utils/safe_file_name.dart';
import '../utils/time_format.dart';
import 'common/list_search_field.dart';
import 'layout/empty_state_placeholder.dart';

class RepertoireListBody extends StatefulWidget {
  /// Called with the chosen *chapter*'s metadata (a `.pgn` file path). A
  /// repertoire is a folder; tapping one opens its chapter list, and the
  /// selected chapter is what the builder / trainer actually load.
  final ValueChanged<RepertoireMetadata> onSelected;

  /// When set, studies are listed in their own section (as trainable
  /// custom-tactics sets) and tapping one calls this instead.
  final ValueChanged<RepertoireMetadata>? onStudySelected;

  const RepertoireListBody({
    super.key,
    required this.onSelected,
    this.onStudySelected,
  });

  @override
  State<RepertoireListBody> createState() => _RepertoireListBodyState();
}

class _RepertoireListBodyState extends State<RepertoireListBody> {
  List<RepertoireMetadata> _repertoires = [];
  List<RepertoireMetadata> _studies = [];
  bool _isLoading = true;
  String? _loadError;
  String _search = '';

  List<RepertoireMetadata> get _visibleRepertoires =>
      _repertoires.where((r) => matchesSearch(_search, r.name)).toList();

  List<RepertoireMetadata> get _visibleStudies =>
      _studies.where((s) => matchesSearch(_search, s.name)).toList();

  @override
  void initState() {
    super.initState();
    unawaited(_loadRepertoires());
  }

  Future<void> _loadRepertoires() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final repertoires = await StorageFactory.instance.listRepertoires();
      repertoires.sort((a, b) => b.lastModified.compareTo(a.lastModified));
      final studies = widget.onStudySelected == null
          ? <RepertoireMetadata>[]
          : await StorageFactory.instance.listStudyFiles();
      studies.sort((a, b) => b.lastModified.compareTo(a.lastModified));

      if (!mounted) return;
      setState(() {
        _repertoires = repertoires;
        _studies = studies;
        _isLoading = false;
        _loadError = null;
      });
    } catch (e) {
      debugPrint('Load repertoires failed: $e');
      if (!mounted) return;
      setState(() {
        _repertoires = [];
        _isLoading = false;
        _loadError = 'Could not load repertoires.\n$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
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
              Text(_loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadRepertoires,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // Keep the import action in the same place for empty and populated lists.
    if (_repertoires.isEmpty && _studies.isEmpty) {
      return Column(
        children: [
          _buildToolbar(),
          const Divider(height: 1, thickness: 1),
          const Expanded(
            child: EmptyStatePlaceholder(
              icon: Icons.library_books,
              title: 'No repertoires yet',
              subtitle: 'Import a PGN file to start training your repertoire.',
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
                    'Nothing matches "$_search".',
                    style: const TextStyle(color: AppColors.onSurfaceMuted),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    if (showSections && repertoires.isNotEmpty)
                      _buildSectionHeader('Repertoires'),
                    for (final repertoire in repertoires)
                      _buildRepertoireCard(repertoire),
                    if (showSections && studies.isNotEmpty) ...[
                      _buildSectionHeader('Studies — custom tactics'),
                      for (final study in studies) _buildStudyCard(study),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: ListSearchField(
              hintText: 'Search repertoires',
              onChanged: (value) => setState(() => _search = value),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _importRepertoire,
            icon: const Icon(Icons.upload_file, size: 18),
            label: const Text('Import repertoire'),
          ),
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
                    Text(
                      study.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$chapterCount chapter${chapterCount == 1 ? '' : 's'}',
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

    final timeAgo = formatTimeAgo(lastModified);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _openRepertoire(repertoire),
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
                  Icons.library_books,
                  color: AppColors.onSurfaceSoft,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$chapterCount chapter${chapterCount == 1 ? '' : 's'}',
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.onSurfaceMuted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text('Modified $timeAgo', style: AppTextStyles.caption),
                  ],
                ),
              ),
              // Rename / delete sit right on the card: two one-click targets
              // beat a menu that hides both behind an extra tap.
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Rename repertoire',
                onPressed: () => _renameRepertoire(repertoire),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                color: AppColors.danger,
                tooltip: 'Delete repertoire',
                onPressed: () => _deleteRepertoire(repertoire),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Open (drill into chapters) ────────────────────────────────────────

  /// Opens the chapter list for [repertoire]; a chosen chapter is forwarded to
  /// [widget.onSelected] (the contract the builder / trainer already consume).
  Future<void> _openRepertoire(RepertoireMetadata repertoire) async {
    final chapter = await Navigator.of(context).push<RepertoireMetadata>(
      MaterialPageRoute(
        builder: (_) => RepertoireChaptersScreen(repertoire: repertoire),
      ),
    );
    if (chapter != null && mounted) {
      widget.onSelected(chapter);
    } else if (mounted) {
      // Chapters may have been added/removed while browsing.
      await _loadRepertoires();
    }
  }

  Future<void> _importRepertoire() async {
    final created = await showRepertoireImportDialog(
      context,
      existingNames: _repertoires.map((r) => r.name).toList(),
    );
    if (created == null || !mounted) return;
    widget.onSelected(
      RepertoireMetadata(
        filePath: created.chapterPath,
        name: 'Main',
        gameCount: created.gameCount,
        lastModified: DateTime.now(),
      ),
    );
  }

  Future<void> _deleteRepertoire(RepertoireMetadata repertoire) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Repertoire'),
        content: Text(
          'Delete repertoire "${repertoire.name}"? Its files will be moved '
          'to Chess Auto Prep recovery trash.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await StorageFactory.instance.deleteRepertoireDirectory(
          repertoire.filePath,
        );
        await _loadRepertoires();
      } catch (e) {
        debugPrint('Delete repertoire failed: $e');
        if (mounted) {
          showAppSnackBar(
            context,
            AppMessages.deleteRepertoireFailed,
            isError: true,
          );
        }
      }
    }
  }

  Future<void> _renameRepertoire(RepertoireMetadata repertoire) async {
    final result = await showNameEntryDialog(
      context,
      title: 'Rename Repertoire',
      prompt: 'Enter new name for the repertoire:',
      fieldLabel: 'Repertoire Name',
      confirmLabel: 'Rename',
      initialValue: repertoire.name,
      validate: (name) =>
          validateSafeFileName(name) ??
          (_repertoires.any(
                (r) =>
                    r.name.toLowerCase() == name.toLowerCase() &&
                    r.filePath != repertoire.filePath,
              )
              ? 'A repertoire named "$name" already exists'
              : null),
    );

    if (result != null && result.isNotEmpty) {
      try {
        final storage = StorageFactory.instance;
        await storage.renameRepertoireDirectory(repertoire.filePath, result);
        await _loadRepertoires();
      } catch (e) {
        debugPrint('Rename repertoire failed: $e');
        if (mounted) {
          showAppSnackBar(
            context,
            AppMessages.renameRepertoireFailed,
            isError: true,
          );
        }
      }
    }
  }
}
