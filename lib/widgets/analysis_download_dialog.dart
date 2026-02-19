import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/analysis_player_info.dart';

/// How the download range is specified.
enum _DownloadMode { months, games }

/// Dialog for downloading games for analysis.
///
/// Lets the user choose between fetching the last N months of games or the
/// last N games by count. Defaults to **6 months**.
///
/// Pops with an [AnalysisPlayerInfo], or `null` if the user cancels.
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

  // ── Range controls ──
  _DownloadMode _mode = _DownloadMode.months;

  int _months = 6;
  late final TextEditingController _monthsController;

  int _maxGames = 100;
  late final TextEditingController _maxGamesController;

  @override
  void initState() {
    super.initState();

    final initialUsername =
        widget.chesscomUsername ?? widget.lichessUsername ?? '';
    _usernameController = TextEditingController(text: initialUsername);
    _monthsController = TextEditingController(text: _months.toString());
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
    _monthsController.dispose();
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

  void _onDownload() {
    final username = _usernameController.text.trim();

    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a username')),
      );
      return;
    }

    if (_mode == _DownloadMode.games && (_maxGames < 1 || _maxGames > 500)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid number of games (1–500)'),
        ),
      );
      return;
    }

    if (_mode == _DownloadMode.months && _months < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid number of months (1 or more)'),
        ),
      );
      return;
    }

    Navigator.of(context).pop(
      AnalysisPlayerInfo(
        platform: _selectedPlatform,
        username: username,
        maxGames: _mode == _DownloadMode.games ? _maxGames : 100,
        monthsBack: _mode == _DownloadMode.months ? _months : null,
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select platform, enter username, and choose a download range:',
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

              // ── Download range ──
              const Text(
                'Download Range',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),

              // Mode toggle
              Center(
                child: SegmentedButton<_DownloadMode>(
                  segments: const [
                    ButtonSegment(
                      value: _DownloadMode.months,
                      label: Text('By months'),
                      icon: Icon(Icons.calendar_month, size: 18),
                    ),
                    ButtonSegment(
                      value: _DownloadMode.games,
                      label: Text('By game count'),
                      icon: Icon(Icons.tag, size: 18),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selection) {
                    setState(() => _mode = selection.first);
                  },
                ),
              ),

              const SizedBox(height: 12),

              // Slider + text field for the active mode
              if (_mode == _DownloadMode.months)
                _buildMonthsControl()
              else
                _buildGamesControl(),
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
          onPressed: _onDownload,
          child: const Text('Download'),
        ),
      ],
    );
  }

  // ── Months slider ────────────────────────────────────────────────

  Widget _buildMonthsControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  Slider(
                    value: _months.toDouble().clamp(1, 120),
                    min: 1,
                    max: 120,
                    divisions: 119,
                    label: '$_months month${_months == 1 ? '' : 's'}',
                    onChanged: (value) {
                      setState(() {
                        _months = value.round();
                        _monthsController.text = _months.toString();
                      });
                    },
                  ),
                  Center(
                    child: Text(
                      'Last $_months month${_months == 1 ? '' : 's'}',
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
                controller: _monthsController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Months',
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null && parsed >= 1) {
                    setState(() => _months = parsed);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Fetch all non-bullet games from the last N months (up to 10 years)',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }

  // ── Games slider ─────────────────────────────────────────────────

  Widget _buildGamesControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  Slider(
                    value: _maxGames.toDouble().clamp(1, 500),
                    min: 1,
                    max: 500,
                    divisions: 499,
                    label: '$_maxGames game${_maxGames == 1 ? '' : 's'}',
                    onChanged: (value) {
                      setState(() {
                        _maxGames = value.round();
                        _maxGamesController.text = _maxGames.toString();
                      });
                    },
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
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Games',
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null && parsed >= 1 && parsed <= 500) {
                    setState(() => _maxGames = parsed);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Download the last 1–500 games (excluding bullet)',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }
}
