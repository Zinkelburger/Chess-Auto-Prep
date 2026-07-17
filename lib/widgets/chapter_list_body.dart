/// Static, clickable list of chapters within a repertoire folder.
///
/// A repertoire is a folder; each chapter is a `.pgn` file inside it that the
/// rest of the app treats exactly like a single-file repertoire.  Selecting a
/// chapter hands its [RepertoireMetadata] (pointing at the chapter file) back
/// to the caller, so builder / training / generation all keep working on a
/// plain file path with no further changes.
library;

import 'package:flutter/material.dart';

import '../models/repertoire_metadata.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/storage/storage_factory.dart';
import '../utils/app_messages.dart';
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

  String get _dirPath => widget.repertoire.filePath;

  @override
  void initState() {
    super.initState();
    _loadChapters();
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
      return EmptyStatePlaceholder(
        icon: Icons.menu_book,
        title: 'No Chapters Yet',
        subtitle:
            'Add a chapter (e.g. "King\'s Gambit") to start organizing '
            'this repertoire',
        actionLabel: 'Add Chapter',
        actionIcon: Icons.add,
        onAction: _showCreateDialog,
      );
    }

    return Stack(
      children: [
        ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
          itemCount: _chapters.length,
          itemBuilder: (context, index) => _buildChapterCard(_chapters[index]),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            onPressed: _showCreateDialog,
            icon: const Icon(Icons.add),
            label: const Text('Add Chapter'),
          ),
        ),
      ],
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
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.menu_book,
                  color: Colors.orange,
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
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  if (value == 'delete') {
                    _deleteChapter(chapter);
                  } else if (value == 'rename') {
                    _renameChapter(chapter);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.edit, size: 20),
                        SizedBox(width: 12),
                        Text('Rename'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, size: 20, color: Colors.red),
                        SizedBox(width: 12),
                        Text('Delete', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
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
    final controller = TextEditingController();
    String? nameError;

    final name = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add Chapter'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Name this chapter (e.g. a variation or system):'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Chapter Name',
                  hintText: "King's Gambit",
                  errorText: nameError,
                ),
                onChanged: (_) {
                  if (nameError != null) setState(() => nameError = null);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setState(() => nameError = 'Please enter a name');
                  return;
                }
                if (_nameTaken(value)) {
                  setState(() => nameError = 'A chapter named "$value" exists');
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
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
    final controller = TextEditingController(text: chapter.name);
    String? nameError;

    final newName = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Rename Chapter'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Chapter Name',
              errorText: nameError,
            ),
            onChanged: (_) {
              if (nameError != null) setState(() => nameError = null);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setState(() => nameError = 'Please enter a name');
                  return;
                }
                if (value == chapter.name) {
                  Navigator.of(context).pop();
                  return;
                }
                if (_nameTaken(value, except: chapter.name)) {
                  setState(() => nameError = 'A chapter named "$value" exists');
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: const Text('Rename'),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
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
          'Delete chapter "${chapter.name}"? This cannot be undone.',
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
