import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/match.dart';
import '../../chess/bughouse/table.dart';
import '../../chess/bughouse/table_setup.dart';
import '../../ui/theme.dart';
import 'bughouse_lab.dart';

/// Asks what to play out: a name, where from — the boards as they stand or
/// a dual FEN — how many games, how hard each team thinks, whether the
/// teams swap seats, and the clock. Answers the match to start, or null.
/// The seed is the owner's to give, when the match starts.
Future<MatchConfig?> showNewMatchDialog(
  BuildContext context,
  BughouseLab lab,
) => showDialog<MatchConfig>(
  context: context,
  builder: (context) => _NewMatchDialog(lab: lab),
);

/// Said of a start that does not read, here and of a stored match.
const notAPosition = 'That is not a position yet — check the moves or the FEN.';

class _NewMatchDialog extends StatefulWidget {
  const _NewMatchDialog({required this.lab});

  final BughouseLab lab;

  @override
  State<_NewMatchDialog> createState() => _NewMatchDialogState();
}

class _NewMatchDialogState extends State<_NewMatchDialog> {
  late final _name = TextEditingController(text: _defaultName);
  final _fen = TextEditingController();
  final _games = TextEditingController(text: '10');
  final _first = TextEditingController(text: '800');
  final _second = TextEditingController(text: '800');
  final _plies = TextEditingController(text: '240');
  bool _fromBoards = true;
  bool _swap = true;
  ClockCase? _chosenClock;
  String? _problem;

  /// The line on the boards, board by board: what the match asks about.
  String get _opening {
    final line = widget.lab.line;
    return [
      for (final board in BoardNumber.values)
        if (line.of(board).take(line.upto(board)) case final moves
            when moves.isNotEmpty)
          '${board.label}: ${moves.map((m) => m.san).join(' ')}',
    ].join(' · ');
  }

  String get _defaultName => _opening.isEmpty ? 'Bughouse match' : _opening;

  /// The lab's clock case until the user picks another.
  ClockCase get _clock => _chosenClock ?? widget.lab.clock;

  @override
  void dispose() {
    for (final field in [_name, _fen, _games, _first, _second, _plies]) {
      field.dispose();
    }
    super.dispose();
  }

  int _number(TextEditingController field, int least, int most, int fallback) =>
      (int.tryParse(field.text.trim()) ?? fallback).clamp(least, most);

  void _play() {
    final start = _fromBoards
        ? widget.lab.position
        : switch (readDualFen(_fen.text)) {
            SetupReady(:final position) => position,
            SetupRefused() => null,
          };
    if (start == null) {
      setState(() {
        _problem = notAPosition;
      });
      return;
    }
    MatchTeam team(String name, TextEditingController nodes) => (
      name: name,
      budget: (nodes: _number(nodes, 50, 1000000, 800), movetimeMs: null),
    );
    Navigator.of(context).pop(
      MatchConfig(
        name: _name.text.trim().isEmpty ? 'Bughouse match' : _name.text.trim(),
        startDualFen: start.dualFen,
        openingLabel: _fromBoards ? _opening : '',
        teams: [team('Hivemind A', _first), team('Hivemind B', _second)],
        games: _number(_games, 1, 1000, 10),
        alternateSeats: _swap,
        clock: _clock,
        maxPlies: _number(_plies, 20, 2000, 240),
        seed: 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final games = _number(_games, 1, 1000, 10);
    return AlertDialog(
      title: const Text('New match'),
      content: SizedBox(
        width: nameDialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: Space.m),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('The boards')),
                ButtonSegment(value: false, label: Text('A dual FEN')),
              ],
              selected: {_fromBoards},
              showSelectedIcon: false,
              onSelectionChanged: (picked) =>
                  setState(() => _fromBoards = picked.single),
            ),
            if (!_fromBoards)
              TextField(
                controller: _fen,
                style: labSetupText,
                decoration: const InputDecoration(labelText: 'Dual FEN'),
              ),
            const SizedBox(height: Space.s),
            _NumberRow(label: 'Games', field: _games, onChanged: _changed),
            _NumberRow(label: 'Hivemind A thinks (nodes)', field: _first),
            _NumberRow(label: 'Hivemind B thinks (nodes)', field: _second),
            _NumberRow(label: 'Draw after (half-moves)', field: _plies),
            CheckboxListTile(
              value: _swap,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Swap seats every other game'),
              onChanged: (on) => setState(() => _swap = on ?? true),
            ),
            SegmentedButton<ClockCase>(
              segments: [
                for (final clock in ClockCase.values)
                  ButtonSegment(
                    value: clock,
                    label: Text(clock.label),
                    tooltip: clock.hint,
                  ),
              ],
              selected: {_clock},
              showSelectedIcon: false,
              onSelectionChanged: (picked) =>
                  setState(() => _chosenClock = picked.single),
            ),
            if (_problem case final problem?)
              Padding(
                padding: const EdgeInsets.only(top: Space.s),
                child: Text(
                  problem,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
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
          onPressed: _play,
          child: Text(games == 1 ? 'Play 1 game' : 'Play $games games'),
        ),
      ],
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({required this.label, required this.field, this.onChanged});

  final String label;
  final TextEditingController field;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(label)),
      SizedBox(
        width: settingNumberWidth + Space.l,
        child: TextField(
          controller: field,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.right,
          onChanged: (_) => onChanged?.call(),
        ),
      ),
    ],
  );
}
