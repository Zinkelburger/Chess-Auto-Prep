/// Repertoire selection screen
/// Shows all saved repertoires and allows selecting or creating new ones
library;

import 'package:flutter/material.dart';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../models/repertoire_metadata.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/storage/storage_factory.dart';
import '../utils/app_messages.dart';
import '../widgets/layout/empty_state_placeholder.dart';
import '../widgets/pgn_import_dialog.dart';

class RepertoireSelectionScreen extends StatefulWidget {
  const RepertoireSelectionScreen({super.key});

  @override
  State<RepertoireSelectionScreen> createState() =>
      _RepertoireSelectionScreenState();
}

class _RepertoireSelectionScreenState extends State<RepertoireSelectionScreen> {
  List<RepertoireMetadata> _repertoires = [];
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadRepertoires();
  }

  Future<void> _loadRepertoires() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final repertoires = await StorageFactory.instance.listRepertoireFiles();
      repertoires.sort((a, b) => b.lastModified.compareTo(a.lastModified));

      if (!mounted) return;
      setState(() {
        _repertoires = repertoires;
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
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Select Repertoire'),
        actions: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateDialog,
        icon: const Icon(Icons.add),
        label: const Text('Create New'),
      ),
    );
  }

  Widget _buildBody() {
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                _loadError!,
                textAlign: TextAlign.center,
              ),
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

    if (_repertoires.isEmpty) {
      return EmptyStatePlaceholder(
        icon: Icons.library_books,
        title: 'No Repertoires Found',
        subtitle: 'Create a new repertoire to get started',
        actionLabel: 'Create Repertoire',
        actionIcon: Icons.add,
        onAction: _showCreateDialog,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _repertoires.length,
      itemBuilder: (context, index) {
        final repertoire = _repertoires[index];
        return _buildRepertoireCard(repertoire);
      },
    );
  }

  Widget _buildRepertoireCard(RepertoireMetadata repertoire) {
    final name = repertoire.name;
    final gameCount = repertoire.gameCount;
    final lastModified = repertoire.lastModified;

    String timeAgo = 'Unknown';
    final difference = DateTime.now().difference(lastModified);

    if (difference.inDays > 0) {
      timeAgo = '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      timeAgo = '${difference.inHours}h ago';
    } else {
      timeAgo = '${difference.inMinutes}m ago';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _selectRepertoire(repertoire),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Repertoire icon
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.library_books,
                  color: Colors.orange,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),

              // Repertoire info
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
                      '$gameCount game${gameCount == 1 ? '' : 's'}',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Modified $timeAgo',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),

              // Actions
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  if (value == 'delete') {
                    _deleteRepertoire(repertoire);
                  } else if (value == 'rename') {
                    _renameRepertoire(repertoire);
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

  void _selectRepertoire(RepertoireMetadata repertoire) {
    Navigator.of(context).pop(repertoire);
  }

  Future<void> _showCreateDialog() async {
    final nameController = TextEditingController();
    String selectedColor = 'White';
    String? nameError;
    PgnImportResult? importResult;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Create New Repertoire'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter a name for your new repertoire:'),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Repertoire Name',
                  hintText: 'Enter repertoire name',
                  errorText: nameError,
                ),
                autofocus: true,
                onChanged: (_) {
                  if (nameError != null) setState(() => nameError = null);
                },
              ),
              const SizedBox(height: 16),
              const Text('Choose your color:'),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'White',
                    label: Text('White'),
                    icon: Icon(Icons.circle_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: 'Black',
                    label: Text('Black'),
                    icon: Icon(Icons.circle, size: 16),
                  ),
                ],
                selected: {selectedColor},
                onSelectionChanged: (Set<String> newSelection) {
                  setState(() {
                    selectedColor = newSelection.first;
                  });
                },
              ),
              const SizedBox(height: 16),
              _InlinePgnAttach(
                importResult: importResult,
                onChanged: (result) {
                  setState(() => importResult = result);
                  if (result != null &&
                      nameController.text.trim().isEmpty) {
                    nameController.text = 'Imported Repertoire';
                  }
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
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  setState(() => nameError = 'Please enter a name');
                  return;
                }
                final exists = _repertoires.any(
                  (r) => r.name.toLowerCase() == name.toLowerCase(),
                );
                if (exists) {
                  setState(() =>
                      nameError = 'A repertoire named "$name" already exists');
                  return;
                }
                Navigator.of(context).pop({
                  'name': name,
                  'color': selectedColor,
                  'pgn': importResult,
                });
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    nameController.dispose();

    if (result != null) {
      await _createRepertoire(
        result['name']! as String,
        result['color']! as String,
        pgnImport: result['pgn'] as PgnImportResult?,
      );
    }
  }

  Future<void> _createRepertoire(
    String name,
    String color, {
    PgnImportResult? pgnImport,
  }) async {
    try {
      final storage = StorageFactory.instance;
      final filePath = await storage.repertoireFilePath(name);

      if (await storage.fileExists(filePath)) {
        if (mounted) {
          showAppSnackBar(context, AppMessages.repertoireExists(name));
        }
        return;
      }

      final header = '// $name Repertoire\n'
          '// Color: $color\n'
          '// Created on ${DateTime.now().toString().split('.')[0]}\n\n';

      int gameCount = 0;
      if (pgnImport != null) {
        await storage.writeFile(filePath, '$header${pgnImport.pgnContent}\n');
        gameCount = pgnImport.gameCount;
      } else {
        await storage.writeFile(filePath, header);
      }

      if (mounted) {
        Navigator.of(context).pop(RepertoireMetadata(
          filePath: filePath,
          name: name,
          gameCount: gameCount,
          lastModified: DateTime.now(),
        ));
      }
    } catch (e) {
      debugPrint('Create repertoire failed: $e');
      if (mounted) {
        showAppSnackBar(context, AppMessages.createRepertoireFailed,
            isError: true);
      }
    }
  }

  Future<void> _deleteRepertoire(RepertoireMetadata repertoire) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Repertoire'),
        content: Text(
            'Delete repertoire "${repertoire.name}"? This action cannot be undone.'),
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

    if (confirmed == true) {
      try {
        await StorageFactory.instance.deleteFile(repertoire.filePath);
        await _loadRepertoires();
      } catch (e) {
        debugPrint('Delete repertoire failed: $e');
        if (mounted) {
          showAppSnackBar(context, AppMessages.deleteRepertoireFailed,
              isError: true);
        }
      }
    }
  }

  Future<void> _renameRepertoire(RepertoireMetadata repertoire) async {
    final nameController = TextEditingController(text: repertoire.name);
    String? nameError;

    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Rename Repertoire'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter new name for the repertoire:'),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Repertoire Name',
                  errorText: nameError,
                ),
                autofocus: true,
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
            TextButton(
              onPressed: () {
                final newName = nameController.text.trim();
                if (newName.isEmpty) {
                  setState(() => nameError = 'Please enter a name');
                  return;
                }
                if (newName == repertoire.name) return;
                final exists = _repertoires.any(
                  (r) =>
                      r.name.toLowerCase() == newName.toLowerCase() &&
                      r.filePath != repertoire.filePath,
                );
                if (exists) {
                  setState(() => nameError =
                      'A repertoire named "$newName" already exists');
                  return;
                }
                Navigator.of(context).pop(newName);
              },
              child: const Text('Rename'),
            ),
          ],
        ),
      ),
    );

    nameController.dispose();

    if (result != null && result.isNotEmpty) {
      try {
        final storage = StorageFactory.instance;
        final newPath = await storage.repertoireFilePath(result);
        await storage.renameFile(repertoire.filePath, newPath);
        await _loadRepertoires();
      } catch (e) {
        debugPrint('Rename repertoire failed: $e');
        if (mounted) {
          showAppSnackBar(context, AppMessages.renameRepertoireFailed,
              isError: true);
        }
      }
    }
  }
}

String _truncateFilename(String name, {int maxLength = 24}) {
  if (name.length <= maxLength) return name;
  final ext = p.extension(name);
  final base = p.basenameWithoutExtension(name);
  final available = maxLength - ext.length - 1;
  if (available < 4) return '${name.substring(0, maxLength - 1)}\u2026';
  return '${base.substring(0, available)}\u2026$ext';
}

/// Inline PGN attach widget for the create-repertoire dialog.
///
/// Centered "+ Add PGN" pill that opens a file picker directly. After picking,
/// shows the filename as a pill next to the add button.
class _InlinePgnAttach extends StatefulWidget {
  final PgnImportResult? importResult;
  final ValueChanged<PgnImportResult?> onChanged;

  const _InlinePgnAttach({
    required this.importResult,
    required this.onChanged,
  });

  @override
  State<_InlinePgnAttach> createState() => _InlinePgnAttachState();
}

class _InlinePgnAttachState extends State<_InlinePgnAttach> {
  String? _fileName;
  String? _error;

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pgn', 'txt'],
        withData: false,
        withReadStream: false,
      );
      if (result == null || result.files.isEmpty) return;

      final path = result.files.single.path;
      if (path == null) return;

      final content = await StorageFactory.instance.readFile(path);
      if (content == null) return;

      final count = pgn.countPgnGames(content);
      setState(() {
        _fileName = result.files.single.name;
        _error = count == 0 ? 'No lines found in file.' : null;
      });

      if (count > 0) {
        widget.onChanged(
            PgnImportResult(pgnContent: content, gameCount: count));
      } else {
        widget.onChanged(null);
      }
    } catch (e) {
      setState(() => _error = 'Could not read file: $e');
      widget.onChanged(null);
    }
  }

  void _clear() {
    setState(() {
      _fileName = null;
      _error = null;
    });
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: _pickFile,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 15, color: cs.onPrimaryContainer),
                    const SizedBox(width: 5),
                    Text(
                      'Add PGN',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.importResult != null && _fileName != null) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.description,
                          size: 13, color: cs.onPrimaryContainer),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _truncateFilename(_fileName!),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: cs.onPrimaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: _clear,
                        child: Icon(Icons.close,
                            size: 13, color: cs.onPrimaryContainer),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.warning_amber, size: 13, color: cs.error),
              const SizedBox(width: 5),
              Text(_error!,
                  style: TextStyle(fontSize: 11, color: cs.error)),
            ],
          ),
        ],
      ],
    );
  }
}
