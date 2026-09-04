/// Static, clickable list of chapters within a repertoire folder.
///
/// A repertoire is a folder; each chapter is a `.pgn` file inside it that the
/// rest of the app treats exactly like a single-file repertoire.  Selecting a
/// chapter hands its [RepertoireMetadata] (pointing at the chapter file) back
/// to the caller, so builder / training / generation all keep working on a
/// plain file path with no further changes.
library;

import 'common/name_entry_dialog.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/repertoire_metadata.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/storage/storage_factory.dart';
import '../theme/app_colors.dart';
import '../utils/app_messages.dart';
import '../utils/safe_file_name.dart';
import 'common/list_search_field.dart';
import 'layout/empty_state_placeholder.dart';

class ChapterListBody extends StatefulWidget {
  /// The repertoire folder whose chapters are listed. `filePath` is the folder.
  final RepertoireMetadata repertoire;

  /// Called when the user taps a chapter (or creates one).
  final ValueChanged<RepertoireMetadata> onSelected;

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
  bool _isLoading = true;
  String? _loadError;
  String _search = '';

  String get _dirPath => widget.repertoire.filePath;

  List<RepertoireMetadata> get _visibleChapters =>
      _chapters.where((c) => matchesSearch(_search, c.name)).toList();

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
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => widget.onSelected(chapter),
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
                      '${chapter.gameCount} line'
                      '${chapter.gameCount == 1 ? '' : 's'}',
                      style: TextStyle(fontSize: 14, color: Colors.grey[600]),
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
      if (mounted) widget.onSelected(created);
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Chapter'),
        content: Text(
          'Delete chapter "${chapter.name}"? Its file will be moved to '
          'Chess Auto Prep recovery trash.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

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
