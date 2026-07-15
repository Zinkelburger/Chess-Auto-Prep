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
/// The player name(s) — several may be given, separated by `;` — are matched
/// against the White/Black headers to decide the user's colour per game, and
/// a live summary shows how many games matched plus every header spelling
/// currently matching (e.g. "Carlsen, Magnus ×54 · Carlsen,M ×33"). Games
/// where no name matches either side (e.g. a repertoire export with no real
/// player names) count for **both** colours, so repertoire files work
/// without any name gymnastics — view whichever colour the file plays.
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

  /// White/Black header pairs of the picked games, extracted once at pick
  /// time so the match summary can recompute cheaply on every name edit.
  List<({String white, String black})> _headerPairs = const [];
  PlayerNameMatchSummary? _matchSummary;

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
      final headerPairs = _extractHeaderPairs(pgns);
      setState(() {
        _pgns = pgns;
        _fileNames
          ..clear()
          ..addAll(names);
        _headerPairs = headerPairs;
        _gameCount = headerPairs.length;
        _error = _gameCount == 0
            ? 'No games found in the selected files.'
            : null;
        if (!_nameEdited) {
          final guess = _guessPlayerName(pgns);
          if (guess != null) _nameController.text = guess;
        }
        _matchSummary = _computeMatchSummary();
      });
    } catch (e) {
      setState(() => _error = 'Could not read files: $e');
    }
  }

  static List<({String white, String black})> _extractHeaderPairs(String pgns) {
    return splitPgnIntoGames(pgns).map((game) {
      final headers = extractHeaders(game);
      return (white: headers['White'] ?? '', black: headers['Black'] ?? '');
    }).toList();
  }

  /// Live preview of how the typed name(s) would attribute the picked games.
  /// Placeholders are included so the preview matches what analysis will do.
  PlayerNameMatchSummary? _computeMatchSummary() {
    final names = _nameController.text.trim();
    if (names.isEmpty || _headerPairs.isEmpty) return null;
    return summarizePlayerNameMatches(
      headerPairs: _headerPairs,
      namesInput: names,
      includeRepertoirePlaceholders: true,
    );
  }

  /// Most frequent White/Black header name across the games, ignoring
  /// placeholder repertoire names — a sensible default for "whose games
  /// are these".
  static String? _guessPlayerName(String pgns) {
    final counts = <String, int>{};
    for (final match in RegExp(
      r'\[(?:White|Black) "([^"]+)"\]',
    ).allMatches(pgns)) {
      final name = match.group(1)!.trim();
      if (name.isEmpty || name == '?' || isRepertoirePlayer(name)) continue;
      counts[name] = (counts[name] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .first
        .key;
  }

  /// "Matched X of Y games" + every header spelling currently matching, so
  /// the user can tell whether their name(s) cover all the file's variants
  /// ("Carlsen, Magnus" vs "Carlsen,M") before importing.
  Widget _buildMatchSummary(ThemeData theme, PlayerNameMatchSummary summary) {
    final variants = summary.variantCounts.entries
        .map((e) => '${e.key} ×${e.value}')
        .join(' · ');
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Matched ${summary.matchedGames} of ${summary.totalGames} games',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: summary.matchedGames == 0 ? theme.colorScheme.error : null,
            ),
          ),
          if (variants.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Matching as: $variants', style: muted),
          ],
          if (summary.unmatchedGames > 0) ...[
            const SizedBox(height: 4),
            Text(
              '${summary.unmatchedGames} game'
              '${summary.unmatchedGames == 1 ? '' : 's'} match'
              '${summary.unmatchedGames == 1 ? 'es' : ''} neither side — '
              'they will count for both colours.',
              style: muted,
            ),
          ],
        ],
      ),
    );
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
    Navigator.of(context).pop(
      AnalysisImportResult(
        pgns: _pgns,
        playerName: name,
        gameCount: _gameCount,
      ),
    );
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
                label: Text(
                  _fileNames.isEmpty
                      ? 'Choose PGN Files'
                      : 'Choose Different Files',
                ),
              ),
              if (_fileNames.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '${_fileNames.join(', ')} — '
                  '$_gameCount game${_gameCount == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Player name(s)',
                  helperText:
                      'Matched against the White/Black headers to tell '
                      'the player\'s colour per game. Separate several '
                      'names or abbreviations with ";" (e.g. "Carlsen; '
                      'DrNykterstein"). Games where no name matches either '
                      'side count for both colours, so repertoire files '
                      'work with any name.',
                  helperMaxLines: 5,
                  border: const OutlineInputBorder(),
                  errorText: _nameError,
                ),
                onChanged: (_) {
                  _nameEdited = true;
                  setState(() {
                    _nameError = null;
                    _matchSummary = _computeMatchSummary();
                  });
                },
              ),
              if (_matchSummary != null) ...[
                const SizedBox(height: 10),
                _buildMatchSummary(theme, _matchSummary!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _confirm, child: const Text('Import')),
      ],
    );
  }
}
