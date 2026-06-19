/// Quick "where are your games?" prompt that kicks off a build-from-games
/// session. Intentionally a small modal — the heavy review/prune surface lands
/// inline in the Lines tab (see [DraftReviewPane]), so this only collects the
/// few inputs needed to start a download.
library;

import 'package:flutter/material.dart';

import '../../services/games_library/game_filter.dart';
import '../../services/games_library/games_library_service.dart';

/// What the user chose on the source form.
class GamesSourceConfig {
  const GamesSourceConfig({
    required this.platform,
    required this.username,
    required this.isWhite,
    required this.selection,
  });

  final GamesPlatform platform;
  final String username;
  final bool isWhite;
  final GameSelection selection;
}

/// Show the form; resolves to the chosen config, or null if cancelled.
Future<GamesSourceConfig?> showGamesSourceForm(
  BuildContext context, {
  bool initialIsWhite = true,
}) {
  return showDialog<GamesSourceConfig>(
    context: context,
    builder: (_) => _GamesSourceDialog(initialIsWhite: initialIsWhite),
  );
}

class _GamesSourceDialog extends StatefulWidget {
  const _GamesSourceDialog({required this.initialIsWhite});
  final bool initialIsWhite;

  @override
  State<_GamesSourceDialog> createState() => _GamesSourceDialogState();
}

class _GamesSourceDialogState extends State<_GamesSourceDialog> {
  GamesPlatform _platform = GamesPlatform.chesscom;
  final _usernameCtrl = TextEditingController();
  late bool _isWhite = widget.initialIsWhite;
  int _maxGames = 200;
  final Set<GameSpeed> _speeds = {
    GameSpeed.blitz,
    GameSpeed.rapid,
    GameSpeed.classical,
  };
  String? _error;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final username = _usernameCtrl.text.trim();
    if (username.isEmpty) {
      setState(() => _error = 'Enter a username first.');
      return;
    }
    Navigator.of(context).pop(GamesSourceConfig(
      platform: _platform,
      username: username,
      isWhite: _isWhite,
      selection: GameSelection(maxGames: _maxGames, speeds: _speeds),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Build from my games'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<GamesPlatform>(
                segments: const [
                  ButtonSegment(
                      value: GamesPlatform.chesscom, label: Text('Chess.com')),
                  ButtonSegment(
                      value: GamesPlatform.lichess, label: Text('Lichess')),
                ],
                selected: {_platform},
                onSelectionChanged: (s) => setState(() => _platform = s.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('As White')),
                  ButtonSegment(value: false, label: Text('As Black')),
                ],
                selected: {_isWhite},
                onSelectionChanged: (s) => setState(() => _isWhite = s.first),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Most recent $_maxGames games',
                    style: const TextStyle(fontSize: 13)),
              ),
              Slider(
                value: _maxGames.toDouble(),
                min: 20,
                max: 1000,
                divisions: 49,
                label: '$_maxGames',
                onChanged: (v) => setState(() => _maxGames = v.round()),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final s in [
                    GameSpeed.bullet,
                    GameSpeed.blitz,
                    GameSpeed.rapid,
                    GameSpeed.classical,
                  ])
                    FilterChip(
                      label: Text(s.name),
                      selected: _speeds.contains(s),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _speeds.add(s);
                        } else {
                          _speeds.remove(s);
                        }
                      }),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12)),
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
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: const Text('Build draft'),
        ),
      ],
    );
  }
}
