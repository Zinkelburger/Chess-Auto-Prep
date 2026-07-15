import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/pgn_parsing_service.dart';
import '../services/pgn_tree_core.dart';
import '../utils/file_text_reader.dart';
import 'dart:io';

/// Result of a PGN-file import for analysis.
class AnalysisImportResult {
  final String pgns;
  final String playerName;
  final int gameCount;

  const AnalysisImportResult({
    required this.pgns,
    required this.playerName,
    required this.gameCount,
  });
}

/// Dialog for importing local PGN file(s) as an analysis "player".
///
/// The player name is matched against the White/Black headers to decide the
/// user's colour per game. Games where the name matches neither side (e.g. a
/// repertoire export with no real player names) count for **both** colours,
/// so repertoire files work without any name gymnastics — view whichever
/// colour the file plays.
///
/// Pops with an [AnalysisImportResult], or `null` if the user cancels.
class AnalysisImportDialog extends StatefulWidget {
  const AnalysisImportDialog({super.key});

  @override
  State<AnalysisImportDialog> createState() => _AnalysisImportDialogState();
}

class _AnalysisImportDialogState extends State<AnalysisImportDialog> {
  final TextEditingController _nameController = TextEditingController();

  final List<String> _fileNames = [];
  String _pgns = '';
  int _gameCount = 0;
  bool _nameEdited = false;

  String? _error;
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pgn', 'txt'],
        allowMultiple: true,
        withData: false,
        withReadStream: false,
      );
      if (result == null || result.files.isEmpty) return;

      final contents = <String>[];
      final names = <String>[];
      for (final file in result.files) {
        final path = file.path;
        if (path == null) continue;
        contents.add(stripBom(await readTextFile(File(path))));
        names.add(file.name);
      }
      if (contents.isEmpty) return;

      final pgns = contents.join('\n\n');
      setState(() {
        _pgns = pgns;
        _fileNames
          ..clear()
          ..addAll(names);
        _gameCount = countPgnGames(pgns);
        _error = _gameCount == 0 ? 'No games found in the selected files.' : null;
        if (!_nameEdited) {
          final guess = _guessPlayerName(pgns);
          if (guess != null) _nameController.text = guess;
        }
      });
    } catch (e) {
      setState(() => _error = 'Could not read files: $e');
    }
  }

  /// Most frequent White/Black header name across the games, ignoring
  /// placeholder repertoire names — a sensible default for "whose games
  /// are these".
  static String? _guessPlayerName(String pgns) {
    final counts = <String, int>{};
    for (final match
        in RegExp(r'\[(?:White|Black) "([^"]+)"\]').allMatches(pgns)) {
      final name = match.group(1)!.trim();
      if (name.isEmpty || name == '?' || isRepertoirePlayer(name)) continue;
      counts[name] = (counts[name] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    return (counts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .first
        .key;
  }

  void _confirm() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter a player name');
      return;
    }
    if (_pgns.isEmpty || _gameCount == 0) {
      setState(() => _error = 'Select PGN files with at least one game.');
      return;
    }
    Navigator.of(context).pop(AnalysisImportResult(
      pgns: _pgns,
      playerName: name,
      gameCount: _gameCount,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Import PGN Files for Analysis'),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Analyze games from PGN files instead of downloading them — '
                'including repertoire files.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _pickFiles,
                icon: const Icon(Icons.file_open, size: 18),
                label: Text(_fileNames.isEmpty
                    ? 'Choose PGN Files'
                    : 'Choose Different Files'),
              ),
              if (_fileNames.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '${_fileNames.join(', ')} — '
                  '$_gameCount game${_gameCount == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Player name',
                  helperText: 'Matched against the White/Black headers to tell '
                      'the player\'s colour per game. Games where it matches '
                      'neither side count for both colours, so repertoire '
                      'files work with any name.',
                  helperMaxLines: 4,
                  border: const OutlineInputBorder(),
                  errorText: _nameError,
                ),
                onChanged: (_) {
                  _nameEdited = true;
                  if (_nameError != null) {
                    setState(() => _nameError = null);
                  }
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _confirm,
          child: const Text('Import'),
        ),
      ],
    );
  }
}
