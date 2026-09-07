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

import 'common/name_entry_dialog.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/repertoire_metadata.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/repertoire_service.dart';
import '../services/storage/storage_factory.dart';
import '../services/training/chapter_layout.dart' show ChapterSummary;
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../utils/safe_file_name.dart';
import 'common/confirm_dialog.dart';
import 'common/list_search_field.dart';
import 'layout/empty_state_placeholder.dart';

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
  List<RepertoireMetadata> _chapters = [];

  /// Course chapters found inside each chapter file, by file path. Absent
  /// until that file's headers have been read; empty when it has none.
  final Map<String, List<ChapterSummary>> _courseChapters = {};
  bool _isLoading = true;
  String? _loadError;
  String _search = '';

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

  Future<void> _loadChapters() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final chapters = await StorageFactory.instance.listChapters(_dirPath);
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        _isLoading = false;
      });
      unawaited(_loadCourseChapters(chapters));
    } catch (e) {
      debugPrint('Load chapters failed: $e');
      if (!mounted) return;
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
  Future<void> _loadCourseChapters(List<RepertoireMetadata> chapters) async {
    final service = RepertoireService();
    for (final chapter in chapters) {
      List<ChapterSummary> sections;
      try {
        sections = await service.courseChaptersInFile(chapter.filePath);
      } catch (e) {
        debugPrint('Course chapters of ${chapter.filePath} failed: $e');
        sections = const [];
      }
      if (!mounted) return;
      setState(() => _courseChapters[chapter.filePath] = sections);
    }
  }

  /// The repertoire's color, read from any existing chapter's `// Color:`
  /// comment so new chapters inherit it. Defaults to White.
  Future<String> _repertoireColor() async {
    for (final chapter in _chapters) {
      final content = await StorageFactory.instance.readFile(chapter.filePath);
      if (content == null) continue;
      final color = pgn.extractRepertoireColor(content);
      if (color != null && color.isNotEmpty) {
        return color.toLowerCase() == 'black' ? 'Black' : 'White';
      }
    }
    return 'White';
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
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
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
                    style: const TextStyle(color: AppColors.onSurfaceMuted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
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
              onChanged: (value) => setState(() => _search = value),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _showCreateDialog,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add chapter'),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterCard(RepertoireMetadata chapter) {
    final sections = _courseChaptersOf(chapter);
    final lines =
        '${chapter.gameCount} line${chapter.gameCount == 1 ? '' : 's'}';
    final summary = sections.isEmpty
        ? lines
        : '$lines · ${sections.length} chapters';
    final radius = BorderRadius.circular(12);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => widget.onSelected(ChapterPick(chapter)),
            borderRadius: sections.isEmpty
                ? radius
                : BorderRadius.vertical(top: radius.topLeft),
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
                      Icons.menu_book,
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
                          chapter.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          summary,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[600],
                          ),
                        ),
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
                    color: AppColors.danger,
                    tooltip: 'Delete chapter',
                    onPressed: () => _deleteChapter(chapter),
                  ),
                ],
              ),
            ),
          ),
          if (sections.isNotEmpty) ...[
            const Divider(height: 1, thickness: 1),
            for (final section in sections)
              _buildCourseChapterRow(chapter, section),
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
        padding: const EdgeInsets.fromLTRB(72, 10, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                section.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: matches ? FontWeight.w500 : FontWeight.normal,
                  color: matches ? AppColors.ink : AppColors.onSurfaceMuted,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${section.lineCount} line${section.lineCount == 1 ? '' : 's'}',
              style: AppTextStyles.caption,
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
    if (name == null) return;

    try {
      final storage = StorageFactory.instance;
      final color = await _repertoireColor();
      final path = storage.chapterFilePath(_dirPath, name);
      if (await storage.fileExists(path)) {
        if (mounted) showAppSnackBar(context, 'That chapter already exists.');
        return;
      }
      final header =
          '// $name\n'
          '// Color: $color\n'
          '// Created on ${DateTime.now().toString().split('.')[0]}\n\n';
      await storage.writeFile(path, header);

      final created = RepertoireMetadata(
        filePath: path,
        name: name,
        gameCount: 0,
        lastModified: DateTime.now(),
      );
      if (mounted) widget.onSelected(ChapterPick(created));
    } catch (e) {
      debugPrint('Create chapter failed: $e');
      if (mounted) {
        showAppSnackBar(context, 'Could not create chapter.', isError: true);
      }
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
    final confirmed = await confirmAction(
      context,
      title: 'Delete chapter "${chapter.name}"?',
      message: 'Its file will be moved to Chess Auto Prep recovery trash.',
      confirmLabel: 'Delete',
    );

    if (!confirmed) return;

    try {
      await StorageFactory.instance.deleteFile(chapter.filePath);
      await _loadChapters();
    } catch (e) {
      debugPrint('Delete chapter failed: $e');
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
