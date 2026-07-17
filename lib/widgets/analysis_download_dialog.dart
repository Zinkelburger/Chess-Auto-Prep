import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/analysis_player_info.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';

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

  /// Preselects the platform ('chesscom' or 'lichess'). Pass it when the
  /// dialog re-downloads an existing player so the dialog targets that
  /// player's platform instead of defaulting to whichever username field
  /// happens to be filled.
  final String? initialPlatform;

  const AnalysisDownloadDialog({
    super.key,
    this.chesscomUsername,
    this.lichessUsername,
    this.initialPlatform,
  });

  @override
  State<AnalysisDownloadDialog> createState() => _AnalysisDownloadDialogState();
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

  String? _usernameError;
  String? _rangeError;

  @override
  void initState() {
    super.initState();

    // An explicit platform wins; otherwise default to whichever platform
    // already has a username.
    if (widget.initialPlatform == 'chesscom' ||
        widget.initialPlatform == 'lichess') {
      _selectedPlatform = widget.initialPlatform!;
    } else if (widget.chesscomUsername != null &&
        widget.chesscomUsername!.isNotEmpty) {
      _selectedPlatform = 'chesscom';
    } else if (widget.lichessUsername != null &&
        widget.lichessUsername!.isNotEmpty) {
      _selectedPlatform = 'lichess';
    }

    final initialUsername = _selectedPlatform == 'chesscom'
        ? (widget.chesscomUsername ?? widget.lichessUsername ?? '')
        : (widget.lichessUsername ?? widget.chesscomUsername ?? '');
    _usernameController = TextEditingController(text: initialUsername);
    _monthsController = TextEditingController(text: _months.toString());
    _maxGamesController = TextEditingController(text: _maxGames.toString());

    _loadPrefs();
  }

  static const _keyMode = 'analysis_download.mode';
  static const _keyMonths = 'analysis_download.months';
  static const _keyMaxGames = 'analysis_download.max_games';

  /// Restore the user's last-used download range.
  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _mode = prefs.getString(_keyMode) == 'games'
          ? _DownloadMode.games
          : _DownloadMode.months;
      final months = prefs.getInt(_keyMonths);
      if (months != null && months >= 1) {
        _months = months;
        _monthsController.text = '$months';
      }
      final maxGames = prefs.getInt(_keyMaxGames);
      if (maxGames != null && maxGames >= 1 && maxGames <= 500) {
        _maxGames = maxGames;
        _maxGamesController.text = '$maxGames';
      }
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyMode,
      _mode == _DownloadMode.games ? 'games' : 'months',
    );
    await prefs.setInt(_keyMonths, _months);
    await prefs.setInt(_keyMaxGames, _maxGames);
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
    bool hasError = false;

    if (username.isEmpty) {
      _usernameError = AppMessages.enterUsername;
      hasError = true;
    } else {
      _usernameError = null;
    }

    if (_mode == _DownloadMode.games && (_maxGames < 1 || _maxGames > 500)) {
      _rangeError = AppMessages.invalidGameCount;
      hasError = true;
    } else if (_mode == _DownloadMode.months && _months < 1) {
      _rangeError = AppMessages.invalidMonths;
      hasError = true;
    } else {
      _rangeError = null;
    }

    if (hasError) {
      setState(() {});
      return;
    }

    _savePrefs();

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
                  errorText: _usernameError,
                ),
                onChanged: (_) {
                  if (_usernameError != null) {
                    setState(() => _usernameError = null);
                  }
                },
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
        FilledButton(onPressed: _onDownload, child: const Text('Download')),
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
                      style: const TextStyle(color: AppColors.onSurfaceMuted),
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
                decoration: InputDecoration(
                  labelText: 'Months',
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  errorText: _mode == _DownloadMode.months ? _rangeError : null,
                ),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null && parsed >= 1) {
                    setState(() {
                      _months = parsed;
                      _rangeError = null;
                    });
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Fetch all non-bullet games from the last N months (up to 10 years)',
          style: AppTextStyles.caption,
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
                      style: const TextStyle(color: AppColors.onSurfaceMuted),
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
                decoration: InputDecoration(
                  labelText: 'Games',
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  errorText: _mode == _DownloadMode.games ? _rangeError : null,
                ),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null && parsed >= 1 && parsed <= 500) {
                    setState(() {
                      _maxGames = parsed;
                      _rangeError = null;
                    });
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Download the last 1–500 games (excluding bullet)',
          style: AppTextStyles.caption,
        ),
      ],
    );
  }
}
