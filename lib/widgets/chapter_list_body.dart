/// Static, clickable list of chapters within a repertoire folder.
///
/// A repertoire is a folder; each chapter is a `.pgn` file inside it that the
/// rest of the app treats exactly like a single-file repertoire.  Selecting a
/// chapter hands its [RepertoireMetadata] (pointing at the chapter file) back
/// to the caller, so builder / training / generation all keep working on a
/// plain file path with no further changes.
///
/// An imported course is one such file carrying its own chapters in the
/// `[White]` headers — the ones the trainer groups by once the file is open.
/// They are listed under the file here too, so the picker shows the same
/// chapters as the screen after it, and tapping one opens the file already
/// scoped to that chapter ([ChapterPick.courseChapter]).
library;

import '../design_system/components/name_entry_dialog.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../design_system/components/item_title.dart';

import '../features/repertoires/models/repertoire_metadata.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../features/documents/models/pgn_document.dart';
import '../features/repertoires/widgets/repertoire_messages.dart';
import '../l10n/generated/app_localizations.dart';
import '../features/repertoires/repositories/repertoire_catalog_repository.dart';
import '../services/storage/storage_factory.dart';
import '../features/training/models/chapter_layout.dart' show ChapterSummary;
import '../design_system/theme/workspace_theme.dart';
import '../design_system/theme/app_typography.dart';
import '../utils/app_messages.dart';
import '../utils/safe_file_name.dart';
import '../design_system/components/confirm_dialog.dart';
import '../design_system/components/list_search_field.dart';
import '../design_system/components/empty_state_placeholder.dart';

/// What the picker hands back: a chapter file, and — when the user tapped
/// one of the course chapters listed under it — that chapter's title.
class ChapterPick {
  final RepertoireMetadata chapter;

  /// Null when the whole file was picked.
  final String? courseChapter;

  const ChapterPick(this.chapter, {this.courseChapter});
}

class ChapterListBody extends StatefulWidget {
  /// The repertoire folder whose chapters are listed. `filePath` is the folder.
  final RepertoireMetadata repertoire;

  /// Called when the user taps a chapter file, one of the course chapters
  /// inside it, or creates a new one.
  final ValueChanged<ChapterPick> onSelected;

  const ChapterListBody({
    super.key,
    required this.repertoire,
    required this.onSelected,
  });

  @override
  State<ChapterListBody> createState() => _ChapterListBodyState();
}

class _ChapterListBodyState extends State<ChapterListBody> {
  late final _catalog = context.read<RepertoireCatalogRepository>();
  Object? _readRequest;
  bool _creating = false;
  bool _deleting = false;
  List<RepertoireMetadata> _chapters = [];

  /// Course chapters found inside each chapter file, by file path. Absent
  /// until that file's headers have been read; empty when it has none.
  final Map<String, List<ChapterSummary>> _courseChapters = {};
  bool _isLoading = true;
  String? _loadError;
  String _search = '';
  final Set<String> _expandedCourses = {};
  static const _chapterPreviewCount = 3;

  String get _dirPath => widget.repertoire.filePath;

  /// Files whose name — or one of whose course chapters — matches the search.
  List<RepertoireMetadata> get _visibleChapters => _chapters
      .where(
        (c) =>
            matchesSearch(_search, c.name) ||
            _courseChaptersOf(c).any((s) => matchesSearch(_search, s.name)),
      )
      .toList();

  List<ChapterSummary> _courseChaptersOf(RepertoireMetadata chapter) =>
      _courseChapters[chapter.filePath] ?? const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadChapters());
  }

  @override
  void didUpdateWidget(covariant ChapterListBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repertoire.filePath != _dirPath) unawaited(_loadChapters());
  }

  Future<void> _loadChapters() async {
    if (!mounted) return;
    final request = _readRequest = Object();
    setState(() {
      _courseChapters.clear();
      _expandedCourses.clear();
      _isLoading = true;
      _loadError = null;
    });

    try {
      final chapters = await _catalog.listChapters(_dirPath);
      if (!mounted || !identical(request, _readRequest)) return;
      setState(() {
        _chapters = chapters;
        _isLoading = false;
      });
      unawaited(_loadCourseChapters(chapters, request));
    } catch (e) {
      debugPrint('Load chapters failed: $e');
      if (!mounted || !identical(request, _readRequest)) return;
      setState(() {
        _chapters = [];
        _isLoading = false;
        _loadError = 'Could not load chapters.\n$e';
      });
    }
  }

  /// Reads each file's course chapters after the list is up, so the files
  /// show at once and a course's chapters fill in under it. A file that
  /// cannot be read simply lists no chapters; the file itself still opens.
  Future<void> _loadCourseChapters(
    List<RepertoireMetadata> chapters,
    Object request,
  ) async {
    for (final chapter in chapters) {
      List<ChapterSummary> sections;
      try {
        sections = await _catalog.chapterSections(chapter.filePath);
      } catch (e) {
        debugPrint('Course chapters of ${chapter.filePath} failed: $e');
        sections = const [];
      }
      if (!mounted || !identical(request, _readRequest)) return;
      setState(() => _courseChapters[chapter.filePath] = sections);
    }
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
              Icon(
                Icons.error_outline,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(_loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadChapters,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_chapters.isEmpty) {
      return Column(
        children: [
          _buildToolbar(),
          const Divider(height: 1, thickness: 1),
          const Expanded(
            child: EmptyStatePlaceholder(
              icon: Icons.menu_book,
              title: 'No chapters yet',
              subtitle: 'Add a chapter to start organizing this repertoire.',
            ),
          ),
        ],
      );
    }

    final chapters = _visibleChapters;
    return Column(
      children: [
        _buildToolbar(),
        const Divider(height: 1, thickness: 1),
        Expanded(
          child: chapters.isEmpty
              ? Center(
                  child: Text(
                    'No chapter matches "$_search".',
                    style: AppTypography.secondary(context),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  itemCount: chapters.length,
                  itemBuilder: (context, index) =>
                      _buildChapterCard(chapters[index]),
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
              hintText: 'Search chapters',
              onChanged: (value) {
                if (!mounted) return;
                setState(() => _search = value);
              },
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _creating ? null : _showCreateDialog,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add chapter'),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterCard(RepertoireMetadata chapter) {
    final sections = _courseChaptersOf(chapter);
    final searching = _search.trim().isNotEmpty;
    final expanded = _expandedCourses.contains(chapter.filePath);
    final visibleSections = searching && !matchesSearch(_search, chapter.name)
        ? sections.where((section) => matchesSearch(_search, section.name))
        : expanded || sections.length <= _chapterPreviewCount || searching
        ? sections
        : sections.take(_chapterPreviewCount);
    final lines =
        '${chapter.gameCount} line${chapter.gameCount == 1 ? '' : 's'}';
    final summary = sections.isEmpty
        ? lines
        : '$lines · ${sections.length} chapters';
    final radius = BorderRadius.circular(12);
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => widget.onSelected(ChapterPick(chapter)),
            borderRadius: sections.isEmpty
                ? radius
                : BorderRadius.vertical(top: radius.topLeft),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: WorkspaceTheme.of(context).inset,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.menu_book,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ItemTitle(
                          chapter.name,
                          maxLines: 2,
                          style: AppTypography.bodyStrong(context),
                        ),
                        const SizedBox(height: 4),
                        Text(summary, style: AppTypography.secondary(context)),
                      ],
                    ),
                  ),
                  // Same one-click rename / delete as the repertoire list.
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Rename chapter',
                    onPressed: () => _renameChapter(chapter),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete chapter',
                    onPressed: () => _deleteChapter(chapter),
                  ),
                ],
              ),
            ),
          ),
          if (sections.isNotEmpty) ...[
            const Divider(height: 1, thickness: 1),
            for (final section in visibleSections)
              _buildCourseChapterRow(chapter, section),
            if (!searching && sections.length > _chapterPreviewCount)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    if (!mounted) return;
                    setState(() {
                      if (expanded) {
                        _expandedCourses.remove(chapter.filePath);
                      } else {
                        _expandedCourses.add(chapter.filePath);
                      }
                    });
                  },
                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  label: Text(
                    expanded
                        ? 'Show fewer chapters'
                        : 'Show all ${sections.length} chapters',
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// One course chapter inside [chapter]'s file: the file opens scoped to it.
  Widget _buildCourseChapterRow(
    RepertoireMetadata chapter,
    ChapterSummary section,
  ) {
    final matches = _search.isEmpty || matchesSearch(_search, section.name);
    return InkWell(
      onTap: () =>
          widget.onSelected(ChapterPick(chapter, courseChapter: section.name)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(48, 7, 12, 7),
        child: Row(
          children: [
            Expanded(
              child: ItemTitle(
                section.name,
                maxLines: 2,
                style: AppTypography.body(context).copyWith(
                  fontWeight: matches ? FontWeight.w500 : FontWeight.normal,
                  color: matches
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${section.lineCount} line${section.lineCount == 1 ? '' : 's'}',
              style: AppTypography.secondary(context),
            ),
          ],
        ),
      ),
    );
  }

  // ── Create / Rename / Delete ──────────────────────────────────────────

  bool _nameTaken(String name, {String? except}) => _chapters.any(
    (c) =>
        c.name.toLowerCase() == name.toLowerCase() &&
        c.name.toLowerCase() != except?.toLowerCase(),
  );

  Future<void> _showCreateDialog() async {
    if (_creating) return;
    final request = _readRequest;
    final folder = _dirPath;
    final name = await showNameEntryDialog(
      context,
      title: 'Add Chapter',
      prompt: 'Name this chapter (e.g. a variation or system):',
      fieldLabel: 'Chapter Name',
      confirmLabel: 'Create',
      allowUnchanged: true,
      validate: (value) =>
          validateSafeFileName(value) ??
          (_nameTaken(value) ? 'A chapter named "$value" exists' : null),
    );
    if (name == null || !mounted || !identical(request, _readRequest)) return;
    setState(() => _creating = true);
    try {
      final result = await _catalog.createChapter(
        folderPath: folder,
        name: name,
      );
      if (!mounted || !identical(request, _readRequest)) return;
      if (result case PgnSaved(:final after)) {
        widget.onSelected(
          ChapterPick(
            RepertoireMetadata(
              filePath: after.path,
              name: name,
              lastModified: DateTime.now(),
            ),
          ),
        );
      } else {
        showAppSnackBar(context, switch (result) {
          PgnNameCollision() => 'That chapter already exists.',
          PgnWriteUncertain(:final recoveryPath) =>
            'Chapter creation needs verification: ${p.join(folder, "$name.pgn")}.'
                '${recoveryPath == null ? "" : " Recovery: $recoveryPath."} Do not retry.',
          _ => 'Could not create chapter.',
        }, isError: true);
      }
    } catch (error) {
      if (mounted && identical(request, _readRequest)) {
        showAppSnackBar(context, 'Could not create chapter.', isError: true);
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _renameChapter(RepertoireMetadata chapter) async {
    final newName = await showNameEntryDialog(
      context,
      title: 'Rename Chapter',
      fieldLabel: 'Chapter Name',
      confirmLabel: 'Rename',
      initialValue: chapter.name,
      validate: (value) =>
          validateSafeFileName(value) ??
          (_nameTaken(value, except: chapter.name)
              ? 'A chapter named "$value" exists'
              : null),
    );
    if (newName == null || newName.isEmpty) return;

    try {
      final storage = StorageFactory.instance;
      final newPath = storage.chapterFilePath(_dirPath, newName);
      await storage.renameFile(chapter.filePath, newPath);
      await _loadChapters();
    } catch (e) {
      debugPrint('Rename chapter failed: $e');
      if (mounted) {
        showAppSnackBar(context, 'Could not rename chapter.', isError: true);
      }
    }
  }

  Future<void> _deleteChapter(RepertoireMetadata chapter) async {
    if (_deleting) return;
    _deleting = true;
    final request = _readRequest;
    bool isCurrent() => mounted && identical(request, _readRequest);
    try {
      final captured = await _catalog.prepareChapterDeletion(chapter.filePath);
      if (!mounted || !isCurrent()) return;
      if (captured is! PgnOpened) {
        await showChapterDeletionResult(
          context,
          captured,
          chapterPath: chapter.filePath,
        );
        return;
      }
      final confirmed = await confirmAction(
        context,
        title: AppLocalizations.of(context).chapterDeleteTitle(chapter.name),
        message: AppLocalizations.of(context).chapterDeleteConfirm,
        confirmLabel: AppLocalizations.of(context).delete,
      );
      if (!confirmed || !mounted || !isCurrent()) return;
      final result = await _catalog.deleteChapter(captured.snapshot);
      if (!mounted) return;
      if (isCurrent() &&
          (result is PgnQuarantined || result is PgnQuarantineUncertain)) {
        unawaited(_loadChapters());
      }
      await showChapterDeletionResult(
        context,
        result,
        chapterPath: chapter.filePath,
      );
    } catch (_) {
      if (mounted && isCurrent()) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context).chapterDeleteFailed,
          isError: true,
        );
      }
    } finally {
      _deleting = false;
    }
  }
}
