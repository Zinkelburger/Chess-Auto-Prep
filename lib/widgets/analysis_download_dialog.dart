import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/analysis_player_info.dart';

/// Dialog for downloading games for analysis.
///
/// Pops with an [AnalysisPlayerInfo] containing the chosen platform, username,
/// and max-games count, or `null` if the user cancels.
class AnalysisDownloadDialog extends StatefulWidget {
  final String? chesscomUsername;
  final String? lichessUsername;

  const AnalysisDownloadDialog({
    super.key,
    this.chesscomUsername,
    this.lichessUsername,
  });

  @override
  State<AnalysisDownloadDialog> createState() =>
      _AnalysisDownloadDialogState();
}

class _AnalysisDownloadDialogState extends State<AnalysisDownloadDialog> {
  String _selectedPlatform = 'chesscom';
  late final TextEditingController _usernameController;
  late final TextEditingController _maxGamesController;
  int _maxGames = 100;

  @override
  void initState() {
    super.initState();

    final initialUsername =
        widget.chesscomUsername ?? widget.lichessUsername ?? '';
    _usernameController = TextEditingController(text: initialUsername);
    _maxGamesController = TextEditingController(text: _maxGames.toString());

    // Default to whichever platform already has a username.
    if (widget.chesscomUsername != null &&
        widget.chesscomUsername!.isNotEmpty) {
      _selectedPlatform = 'chesscom';
    } else if (widget.lichessUsername != null &&
        widget.lichessUsername!.isNotEmpty) {
      _selectedPlatform = 'lichess';
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _maxGamesController.dispose();
    super.dispose();
  }

  // ── Callbacks ────────────────────────────────────────────────────

  void _onPlatformChanged(String? platform) {
    if (platform == null) return;
    setState(() {
      _selectedPlatform = platform;
      if (platform == 'chesscom' && widget.chesscomUsername != null) {
        _usernameController.text = widget.chesscomUsername!;
      } else if (platform == 'lichess' && widget.lichessUsername != null) {
        _usernameController.text = widget.lichessUsername!;
      }
    });
  }

  void _onMaxGamesSliderChanged(double value) {
    setState(() {
      _maxGames = value.round();
      _maxGamesController.text = _maxGames.toString();
    });
  }

  void _onMaxGamesTextChanged(String value) {
    final parsed = int.tryParse(value);
    if (parsed != null && parsed >= 1 && parsed <= 500) {
      setState(() => _maxGames = parsed);
    }
  }

  void _onDownload() {
    final username = _usernameController.text.trim();

    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a username')),
      );
      return;
    }

    if (_maxGames < 1 || _maxGames > 500) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid number of games (1–500)'),
        ),
      );
      return;
    }

    Navigator.of(context).pop(
      AnalysisPlayerInfo(
        platform: _selectedPlatform,
        username: username,
        maxGames: _maxGames,
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Download Games for Analysis'),
      content: SizedBox(
        width: 450,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select platform, enter username, and choose how many games:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),

            // ── Platform ──
            RadioGroup<String>(
              groupValue: _selectedPlatform,
              onChanged: (value) => _onPlatformChanged(value),
              child: const Column(
                children: [
                  RadioListTile<String>(
                    title: Text('Chess.com'),
                    subtitle: Text('Download games (no bullet)'),
                    value: 'chesscom',
                  ),
                  RadioListTile<String>(
                    title: Text('Lichess'),
                    subtitle: Text('Download games (no bullet)'),
                    value: 'lichess',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Username ──
            TextField(
              controller: _usernameController,
              decoration: InputDecoration(
                labelText: 'Username',
                hintText: 'Enter username',
                helperText: _selectedPlatform == 'chesscom'
                    ? 'Your Chess.com username'
                    : 'Your Lichess username',
                border: const OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 24),

            // ── Max games ──
            const Text(
              'Number of Games',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Slider(
                        value: _maxGames.toDouble().clamp(1, 500),
                        min: 1,
                        max: 500,
                        divisions: 499,
                        label:
                            '$_maxGames game${_maxGames == 1 ? '' : 's'}',
                        onChanged: _onMaxGamesSliderChanged,
                      ),
                      Center(
                        child: Text(
                          'Last $_maxGames game${_maxGames == 1 ? '' : 's'}',
                          style: TextStyle(color: Colors.grey[700]),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 70,
                  child: TextField(
                    controller: _maxGamesController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Games',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    onChanged: _onMaxGamesTextChanged,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Download the last 1–500 games (excluding bullet)',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _onDownload,
          child: const Text('Download'),
        ),
      ],
    );
  }
}
