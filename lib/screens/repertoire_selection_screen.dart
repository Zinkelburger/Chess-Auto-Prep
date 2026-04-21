/// Repertoire selection screen
/// Shows all saved repertoires and allows selecting or creating new ones
library;

import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import '../utils/app_messages.dart';
import '../widgets/pgn_import_dialog.dart';

class RepertoireSelectionScreen extends StatefulWidget {
  const RepertoireSelectionScreen({super.key});

  @override
  State<RepertoireSelectionScreen> createState() =>
      _RepertoireSelectionScreenState();
}

class _RepertoireSelectionScreenState extends State<RepertoireSelectionScreen> {
  List<Map<String, dynamic>> _repertoires = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRepertoires();
  }

  Future<void> _loadRepertoires() async {
    setState(() => _isLoading = true);

    try {
      final directory = await getApplicationDocumentsDirectory();
      final repertoireDir = Directory('${directory.path}/repertoires');

      // Create repertoires directory if it doesn't exist
      if (!await repertoireDir.exists()) {
        await repertoireDir.create(recursive: true);
      }

      final files = await repertoireDir
          .list()
          .where((file) => file.path.endsWith('.pgn'))
          .toList();
      final repertoires = <Map<String, dynamic>>[];

      for (final file in files) {
        final fileName = file.path.split('/').last.replaceAll('.pgn', '');
        final stat = await file.stat();
        final content = await File(file.path).readAsString();
        final gameCount = _countGamesInPgn(content);

        repertoires.add({
          'name': fileName,
          'fileName': fileName,
          'gameCount': gameCount,
          'lastModified': stat.modified,
          'filePath': file.path,
        });
      }

      repertoires.sort((a, b) => (b['lastModified'] as DateTime)
          .compareTo(a['lastModified'] as DateTime));

      if (!mounted) return;
      setState(() {
        _repertoires = repertoires;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Load repertoires failed: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  int _countGamesInPgn(String content) {
    return '[Event '.allMatches(content).length;
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
    if (_repertoires.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.library_books,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 24),
            Text(
              'No Repertoires Found',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Create a new repertoire to get started',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _showCreateDialog,
              icon: const Icon(Icons.add),
              label: const Text('Create Repertoire'),
            ),
          ],
        ),
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

  Widget _buildRepertoireCard(Map<String, dynamic> repertoire) {
    final name = repertoire['name'] as String;
    final gameCount = repertoire['gameCount'] as int;
    final lastModified = repertoire['lastModified'] as DateTime;

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

  void _selectRepertoire(Map<String, dynamic> repertoire) {
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
              if (importResult != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 18,
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${importResult!.gameCount} game${importResult!.gameCount == 1 ? '' : 's'} ready to import',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => importResult = null),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: () async {
                    final pgn = await showPgnImportDialog(
                      context,
                      title: 'Import PGN',
                      confirmLabel: 'Attach',
                    );
                    if (pgn != null) {
                      setState(() => importResult = pgn);
                      if (nameController.text.trim().isEmpty) {
                        nameController.text = 'Imported Repertoire';
                      }
                    }
                  },
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import PGN (optional)'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
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
      final directory = await getApplicationDocumentsDirectory();
      final repertoireDir = Directory('${directory.path}/repertoires');

      if (!await repertoireDir.exists()) {
        await repertoireDir.create(recursive: true);
      }

      final file = File('${repertoireDir.path}/$name.pgn');

      if (await file.exists()) {
        if (mounted) {
          showAppSnackBar(context, AppMessages.repertoireExists(name));
        }
        return;
      }

      final header = '// $name Repertoire\n'
          '// Color: $color\n'
          '// Created on ${DateTime.now().toString().split('.')[0]}\n\n';

      if (pgnImport != null) {
        await file.writeAsString('$header${pgnImport.pgnContent}\n');
        if (mounted) {
          showAppSnackBar(
            context,
            'Created "$name" with ${pgnImport.gameCount} '
            'game${pgnImport.gameCount == 1 ? '' : 's'}.',
          );
        }
      } else {
        await file.writeAsString(header);
      }

      await _loadRepertoires();
    } catch (e) {
      debugPrint('Create repertoire failed: $e');
      if (mounted) {
        showAppSnackBar(context, AppMessages.createRepertoireFailed,
            isError: true);
      }
    }
  }

  Future<void> _deleteRepertoire(Map<String, dynamic> repertoire) async {
    final name = repertoire['name'] as String;
    final filePath = repertoire['filePath'] as String;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Repertoire'),
        content:
            Text('Delete repertoire "$name"? This action cannot be undone.'),
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
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }

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

  Future<void> _renameRepertoire(Map<String, dynamic> repertoire) async {
    final name = repertoire['name'] as String;
    final filePath = repertoire['filePath'] as String;
    final nameController = TextEditingController(text: name);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Repertoire'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter new name for the repertoire:'),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Repertoire Name',
              ),
              autofocus: true,
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
              if (newName.isNotEmpty && newName != name) {
                Navigator.of(context).pop(newName);
              }
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    nameController.dispose();

    if (result != null && result.isNotEmpty) {
      try {
        final directory = await getApplicationDocumentsDirectory();
        final repertoireDir = Directory('${directory.path}/repertoires');
        final oldFile = File(filePath);
        final newFile = File('${repertoireDir.path}/$result.pgn');

        if (await newFile.exists()) {
          if (mounted) {
            showAppSnackBar(context, AppMessages.repertoireExists(result));
          }
          return;
        }

        await oldFile.rename(newFile.path);
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
