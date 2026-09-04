/// "Download a player's games" — the one form that turns a username into a
/// saved game-set.
library;

///
/// Three questions, in the order you would ask them out loud: which site,
/// whose account, how much. Each answer is one control. It used to ask the
/// same three things with a pair of radio tiles carrying identical
/// subtitles, and a range picked by a slider *and* a number box *and* a
/// running caption *and* a help line — four widgets for one integer.
///
/// Pops with an [AnalysisPlayerInfo], or `null` if the user cancels.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/analysis_player_info.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';

/// How the amount to download is specified.
enum _DownloadMode { months, games }

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
  String _platform = 'chesscom';
  late final TextEditingController _usernameController;

  _DownloadMode _mode = _DownloadMode.months;
  late final TextEditingController _amountController;

  String? _usernameError;
  String? _amountError;

  static const _keyMode = 'analysis_download.mode';
  static const _keyMonths = 'analysis_download.months';
  static const _keyMaxGames = 'analysis_download.max_games';

  /// Remembered separately per mode, so flipping the toggle back and forth
  /// does not overwrite "24 months" with "100 games".
  int _months = 6;
  int _maxGames = 100;

  int get _amount => _mode == _DownloadMode.months ? _months : _maxGames;

  @override
  void initState() {
    super.initState();

    // An explicit platform wins; otherwise default to whichever platform
    // already has a username.
    if (widget.initialPlatform == 'chesscom' ||
        widget.initialPlatform == 'lichess') {
      _platform = widget.initialPlatform!;
    } else if (widget.chesscomUsername?.isNotEmpty == true) {
      _platform = 'chesscom';
    } else if (widget.lichessUsername?.isNotEmpty == true) {
      _platform = 'lichess';
    }

    _usernameController = TextEditingController(text: _usernameFor(_platform));
    _amountController = TextEditingController(text: '$_amount');
    unawaited(_loadPrefs());
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  String _usernameFor(String platform) => platform == 'chesscom'
      ? (widget.chesscomUsername ?? widget.lichessUsername ?? '')
      : (widget.lichessUsername ?? widget.chesscomUsername ?? '');

  /// Restore the user's last-used range.
  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _mode = prefs.getString(_keyMode) == 'games'
          ? _DownloadMode.games
          : _DownloadMode.months;
      _months = _atLeastOne(prefs.getInt(_keyMonths)) ?? _months;
      _maxGames = _atLeastOne(prefs.getInt(_keyMaxGames)) ?? _maxGames;
      _amountController.text = '$_amount';
    });
  }

  static int? _atLeastOne(int? value) =>
      (value != null && value >= 1) ? value : null;

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyMode,
      _mode == _DownloadMode.games ? 'games' : 'months',
    );
    await prefs.setInt(_keyMonths, _months);
    await prefs.setInt(_keyMaxGames, _maxGames);
  }

  // ── Callbacks ────────────────────────────────────────────────────

  void _onPlatformChanged(String platform) {
    setState(() {
      _platform = platform;
      // Only offer the saved name for the newly picked site; leave anything
      // the user typed themselves alone.
      final saved = platform == 'chesscom'
          ? widget.chesscomUsername
          : widget.lichessUsername;
      if (saved != null && saved.isNotEmpty) {
        _usernameController.text = saved;
        _usernameError = null;
      }
    });
  }

  void _onModeChanged(_DownloadMode mode) {
    setState(() {
      _mode = mode;
      _amountController.text = '$_amount';
      _amountError = null;
    });
  }

  void _onAmountChanged(String value) {
    final parsed = int.tryParse(value.trim());
    setState(() {
      _amountError = null;
      if (parsed == null || parsed < 1) return;
      if (_mode == _DownloadMode.months) {
        _months = parsed;
      } else {
        _maxGames = parsed;
      }
    });
  }

  void _onDownload() {
    final username = _usernameController.text.trim();
    final amount = int.tryParse(_amountController.text.trim());

    setState(() {
      _usernameError = username.isEmpty ? AppMessages.enterUsername : null;
      _amountError = (amount == null || amount < 1)
          ? (_mode == _DownloadMode.months
                ? AppMessages.invalidMonths
                : AppMessages.invalidGameCount)
          : null;
    });
    if (_usernameError != null || _amountError != null) return;

    unawaited(_savePrefs());
    Navigator.of(context).pop(
      AnalysisPlayerInfo(
        platform: _platform,
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
      title: const Text('Download a player’s games'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'chesscom', label: Text('Chess.com')),
                  ButtonSegment(value: 'lichess', label: Text('Lichess')),
                ],
                selected: {_platform},
                onSelectionChanged: (s) => _onPlatformChanged(s.first),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _usernameController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Username',
                  helperText:
                      'Their public '
                      '${_platform == 'chesscom' ? 'Chess.com' : 'Lichess'}'
                      ' username — yours or an opponent’s.',
                  border: const OutlineInputBorder(),
                  errorText: _usernameError,
                ),
                onChanged: (_) {
                  if (_usernameError != null) {
                    setState(() => _usernameError = null);
                  }
                },
                onSubmitted: (_) => _onDownload(),
              ),
              const SizedBox(height: 24),
              const Text(
                'How many games',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              SegmentedButton<_DownloadMode>(
                segments: const [
                  ButtonSegment(
                    value: _DownloadMode.months,
                    label: Text('Recent months'),
                  ),
                  ButtonSegment(
                    value: _DownloadMode.games,
                    label: Text('Last N games'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => _onModeChanged(s.first),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _amountController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: _mode == _DownloadMode.months
                        ? 'Months'
                        : 'Games',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: _amountError,
                  ),
                  onChanged: _onAmountChanged,
                  onSubmitted: (_) => _onDownload(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _mode == _DownloadMode.months
                    ? 'Every game they played in the last $_months '
                          'month${_months == 1 ? '' : 's'}. Bullet is skipped.'
                    : 'Their last $_maxGames game'
                          '${_maxGames == 1 ? '' : 's'}. Bullet is skipped.',
                style: AppTextStyles.caption,
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
        FilledButton(onPressed: _onDownload, child: const Text('Download')),
      ],
    );
  }
}
