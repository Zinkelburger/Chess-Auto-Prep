/// Repertoire selection screen
/// Shows all saved repertoires and allows selecting or creating new ones
library;

import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class RepertoireSelectionScreen extends StatefulWidget {
  const RepertoireSelectionScreen({super.key});

  @override
  State<RepertoireSelectionScreen> createState() => _RepertoireSelectionScreenState();
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

      if (!await repertoireDir.exists()) {
        await repertoireDir.create(recursive: true);
      }

      final files = await repertoireDir.list().where((file) => file.path.endsWith('.pgn')).toList();
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

      repertoires.sort((a, b) => (b['lastModified'] as DateTime).compareTo(a['lastModified'] as DateTime));

      setState(() {
        _repertoires = repertoires;
        _isLoading = false;
      });
    } catch (e) {
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
        title: const Text('Select Repertoire'),
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

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Repertoire'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter a name for your new repertoire:'),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Repertoire Name',
                hintText: 'e.g., "Sicilian Dragon", "French Defense"',
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
              final name = nameController.text.trim();
              if (name.isNotEmpty) {
                Navigator.of(context).pop(name);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await _createRepertoire(result);
    }
  }

  Future<void> _createRepertoire(String name) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final repertoireDir = Directory('${directory.path}/repertoires');

      if (!await repertoireDir.exists()) {
        await repertoireDir.create(recursive: true);
      }

      final file = File('${repertoireDir.path}/$name.pgn');

      if (await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Repertoire "$name" already exists')),
          );
        }
        return;
      }

      // Create empty PGN file with a comment
      await file.writeAsString('// $name Repertoire\n// Created on ${DateTime.now().toString().split('.')[0]}\n\n');

      await _loadRepertoires();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Created repertoire "$name"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating repertoire: $e')),
        );
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
        content: Text('Delete repertoire "$name"? This action cannot be undone.'),
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

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted repertoire "$name"')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting repertoire: $e')),
          );
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

    if (result != null && result.isNotEmpty) {
      try {
        final directory = await getApplicationDocumentsDirectory();
        final oldFile = File(filePath);
        final newFile = File('${directory.path}/repertoires/$result.pgn');

        if (await newFile.exists()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Repertoire "$result" already exists')),
            );
          }
          return;
        }

        await oldFile.rename(newFile.path);
        await _loadRepertoires();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Renamed repertoire to "$result"')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error renaming repertoire: $e')),
          );
        }
      }
    }
  }
}