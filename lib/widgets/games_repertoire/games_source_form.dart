/// Quick "where are your games?" prompt that kicks off a build-from-games
/// session. Intentionally a small modal — the heavy review/prune surface lands
/// inline in the Lines tab (see [DraftReviewPane]), so this only collects the
/// few inputs needed to start a download.
library;

import 'package:flutter/material.dart';

import '../../services/games_library/game_filter.dart';
import '../../services/games_library/games_library_service.dart';
import '../../services/games_repertoire/games_source_config.dart';
import '../common/since_date_picker.dart';
import '../starting_position_card.dart';

export '../../services/games_repertoire/games_source_config.dart'
    show GamesSourceConfig;

/// Show the form; resolves to the chosen config, or null if cancelled.
///
/// [initialChesscomUsername] / [initialLichessUsername] prefill the username
/// field from whatever is already saved app-wide (e.g. the tactics trainer), so
/// the user doesn't have to retype it. The platform defaults to whichever one
/// has a saved username.
///
/// [currentFen]/[currentMoveSans] feed the "From current position" option and
/// its starting-position preview. [atRoot] disables that option when the
/// board is already at the game start.
Future<GamesSourceConfig?> showGamesSourceForm(
  BuildContext context, {
  bool initialIsWhite = true,
  String? initialChesscomUsername,
  String? initialLichessUsername,
  bool atRoot = true,
  String? rootFen,
  String? currentFen,
  List<String> currentMoveSans = const [],
}) {
  return showDialog<GamesSourceConfig>(
    context: context,
    builder: (_) => _GamesSourceDialog(
      initialIsWhite: initialIsWhite,
      initialChesscomUsername: initialChesscomUsername,
      initialLichessUsername: initialLichessUsername,
      atRoot: atRoot,
      rootFen: rootFen,
      currentFen: currentFen,
      currentMoveSans: currentMoveSans,
    ),
  );
}

class _GamesSourceDialog extends StatefulWidget {
  const _GamesSourceDialog({
    required this.initialIsWhite,
    this.initialChesscomUsername,
    this.initialLichessUsername,
    required this.atRoot,
    required this.rootFen,
    required this.currentFen,
    required this.currentMoveSans,
  });
  final bool initialIsWhite;
  final String? initialChesscomUsername;
  final String? initialLichessUsername;
  final bool atRoot;
  final String? rootFen;
  final String? currentFen;
  final List<String> currentMoveSans;

  @override
  State<_GamesSourceDialog> createState() => _GamesSourceDialogState();
}

class _GamesSourceDialogState extends State<_GamesSourceDialog> {
  late GamesPlatform _platform;
  late final TextEditingController _usernameCtrl;
  late bool _isWhite = widget.initialIsWhite;
  bool _fromCurrentPosition = false;

  // Selection mode: by date (default — usually what you want for a repertoire)
  // or by a fixed count of most-recent games.
  bool _useDate = true;
  DateTime _since = DateTime.now().subtract(const Duration(days: 180));
  int _maxGames = 200;
  final Set<GameSpeed> _speeds = {
    GameSpeed.blitz,
    GameSpeed.rapid,
    GameSpeed.classical,
  };
  String? _error;

  String? get _savedFor => _platform == GamesPlatform.chesscom
      ? widget.initialChesscomUsername
      : widget.initialLichessUsername;

  @override
  void initState() {
    super.initState();
    final chesscom = widget.initialChesscomUsername?.trim() ?? '';
    final lichess = widget.initialLichessUsername?.trim() ?? '';
    // Default to whichever platform already has a saved username.
    _platform = chesscom.isEmpty && lichess.isNotEmpty
        ? GamesPlatform.lichess
        : GamesPlatform.chesscom;
    _usernameCtrl = TextEditingController(text: _savedFor?.trim() ?? '');
  }

  void _onPlatformChanged(GamesPlatform platform) {
    setState(() {
      _platform = platform;
      // Swap in the saved username for the newly selected platform.
      _usernameCtrl.text = _savedFor?.trim() ?? '';
    });
  }

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
    Navigator.of(context).pop(
      GamesSourceConfig(
        platform: _platform,
        username: username,
        isWhite: _isWhite,
        selection: _useDate
            ? GameSelection(since: _since, speeds: _speeds)
            : GameSelection(maxGames: _maxGames, speeds: _speeds),
        startMoves: _fromCurrentPosition ? widget.currentMoveSans : const [],
      ),
    );
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
                    value: GamesPlatform.chesscom,
                    label: Text('Chess.com'),
                  ),
                  ButtonSegment(
                    value: GamesPlatform.lichess,
                    label: Text('Lichess'),
                  ),
                ],
                selected: {_platform},
                onSelectionChanged: (s) => _onPlatformChanged(s.first),
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
              if (widget.rootFen != null) ...[
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('All my games')),
                    ButtonSegment(
                      value: true,
                      label: Text('From current position'),
                    ),
                  ],
                  selected: {_fromCurrentPosition},
                  onSelectionChanged: widget.atRoot
                      ? null
                      : (s) => setState(() => _fromCurrentPosition = s.first),
                ),
                const SizedBox(height: 8),
                StartingPositionCard(
                  label: _fromCurrentPosition
                      ? 'ONLY GAMES THROUGH'
                      : 'DRAFTING FROM',
                  fen: _fromCurrentPosition
                      ? (widget.currentFen ?? widget.rootFen!)
                      : widget.rootFen!,
                  moveSans: _fromCurrentPosition
                      ? widget.currentMoveSans
                      : const [],
                  flipped: !_isWhite,
                ),
                const SizedBox(height: 4),
                Text(
                  _fromCurrentPosition
                      ? 'Only games that reach this position are drafted; '
                            'all other openings are left out.'
                      : 'Every downloaded game is used, drafting lines from '
                            'the first move.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey[500]),
                ),
              ],
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    label: Text('From date'),
                    icon: Icon(Icons.event, size: 16),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text('Most recent'),
                    icon: Icon(Icons.format_list_numbered, size: 16),
                  ),
                ],
                selected: {_useDate},
                onSelectionChanged: (s) => setState(() => _useDate = s.first),
              ),
              const SizedBox(height: 12),
              if (_useDate)
                SinceDatePicker(
                  date: _since,
                  label: 'Games since',
                  onChanged: (d) => setState(
                    () => _since =
                        d ?? DateTime.now().subtract(const Duration(days: 180)),
                  ),
                )
              else ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Most recent $_maxGames games',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Slider(
                  value: _maxGames.toDouble(),
                  min: 20,
                  max: 1000,
                  divisions: 49,
                  label: '$_maxGames',
                  onChanged: (v) => setState(() => _maxGames = v.round()),
                ),
              ],
              const SizedBox(height: 12),
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
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
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
