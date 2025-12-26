import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Dialog for downloading games for analysis
/// Allows user to select platform, username, and date range
class AnalysisDownloadDialog extends StatefulWidget {
  final String? chesscomUsername;
  final String? lichessUsername;

  const AnalysisDownloadDialog({
    super.key,
    this.chesscomUsername,
    this.lichessUsername,
  });

  @override
  State<AnalysisDownloadDialog> createState() => _AnalysisDownloadDialogState();
}

class _AnalysisDownloadDialogState extends State<AnalysisDownloadDialog> {
  String _selectedPlatform = 'chesscom';
  late TextEditingController _usernameController;
  late TextEditingController _maxGamesController;
  int _maxGames = 100;

  @override
  void initState() {
    super.initState();
    // Prefill with appropriate username based on default platform
    final initialUsername = widget.chesscomUsername ?? widget.lichessUsername ?? '';
    _usernameController = TextEditingController(text: initialUsername);
    _maxGamesController = TextEditingController(text: _maxGames.toString());

    // Default to platform that has a username set
    if (widget.chesscomUsername != null && widget.chesscomUsername!.isNotEmpty) {
      _selectedPlatform = 'chesscom';
    } else if (widget.lichessUsername != null && widget.lichessUsername!.isNotEmpty) {
      _selectedPlatform = 'lichess';
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _maxGamesController.dispose();
    super.dispose();
  }

  void _onPlatformChanged(String? platform) {
    if (platform == null) return;

    setState(() {
      _selectedPlatform = platform;
      // Update username field when platform changes
      if (platform == 'chesscom' && widget.chesscomUsername != null) {
        _usernameController.text = widget.chesscomUsername!;
      } else if (platform == 'lichess' && widget.lichessUsername != null) {
        _usernameController.text = widget.lichessUsername!;
      }
    });
  }

  void _onMaxGamesChanged(double value) {
    setState(() {
      _maxGames = value.round();
      _maxGamesController.text = _maxGames.toString();
    });
  }

  void _onMaxGamesTextChanged(String value) {
    final games = int.tryParse(value);
    if (games != null && games >= 1 && games <= 500) {
      setState(() {
        _maxGames = games;
      });
    }
  }

  void _onDownload() {
    final username = _usernameController.text.trim();

    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a username'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Validate max games
    if (_maxGames < 1 || _maxGames > 500) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid number of games (1-500)'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Return platform, username, and maxGames
    Navigator.of(context).pop({
      'platform': _selectedPlatform,
      'username': username,
      'maxGames': _maxGames,
    });
  }

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

            // Platform selection
            RadioListTile<String>(
              title: const Text('Chess.com'),
              subtitle: const Text('Download games (no bullet)'),
              value: 'chesscom',
              groupValue: _selectedPlatform,
              onChanged: _onPlatformChanged,
            ),
            RadioListTile<String>(
              title: const Text('Lichess'),
              subtitle: const Text('Download games (no bullet)'),
              value: 'lichess',
              groupValue: _selectedPlatform,
              onChanged: _onPlatformChanged,
            ),

            const SizedBox(height: 16),

            // Username input
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

            // Max games selector
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
                        label: '$_maxGames game${_maxGames == 1 ? '' : 's'}',
                        onChanged: _onMaxGamesChanged,
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
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    onChanged: _onMaxGamesTextChanged,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Download the last 1-500 games (excluding bullet)',
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
