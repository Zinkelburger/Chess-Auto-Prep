import 'dart:async';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show Setup, Side;
import 'package:flutter/material.dart';

import '../../chess/fen.dart';
import '../../chess/position_setup.dart';
import '../../chess/tournament/config.dart';
import '../../ui/choice_field.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';
import '../../workspace/board_editor.dart';

Future<TournamentConfig?> tournamentSetup(
  BuildContext context, {
  required List<TournamentEngine> engines,
  required Fen position,
  TournamentConfig? previous,
}) => showDialog<TournamentConfig>(
  context: context,
  builder: (_) =>
      _Setup(engines: engines, position: position, previous: previous),
);

class _Setup extends StatefulWidget {
  const _Setup({required this.engines, required this.position, this.previous});
  final List<TournamentEngine> engines;
  final Fen position;
  final TournamentConfig? previous;
  @override
  State<_Setup> createState() => _SetupState();
}

class _SetupState extends State<_Setup> {
  late final _name = TextEditingController(
    text: widget.previous?.name ?? 'Engine match',
  );
  late final _fen = TextEditingController(
    text: widget.previous?.root.value ?? Fen.initial.value,
  );
  late final _seats = [...?widget.previous?.engines];
  late final _time = <String, Object?>{...?(widget.previous?.time)};
  late final _rules = <String, Object?>{...?(widget.previous?.adjudication)};
  late final _values = <String, Object?>{...?(widget.previous?.json)};
  String? _problem;
  @override
  void initState() {
    super.initState();
    if (_seats.isEmpty)
      _seats.addAll([
        TournamentEngine.bundled('Stockfish A'),
        TournamentEngine.bundled('Stockfish B'),
      ]);
  }

  @override
  void dispose() {
    _name.dispose();
    _fen.dispose();
    super.dispose();
  }

  void _change(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.previous == null ? 'New tournament' : 'Configure next run',
    ),
    content: SizedBox(
      width: 660,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: Space.m),
            Text('Engines', style: Theme.of(context).textTheme.titleMedium),
            for (var i = 0; i < _seats.length; i++) _seat(i),
            TextButton.icon(
              onPressed: () =>
                  _change(() => _seats.add(TournamentEngine.bundled())),
              icon: const Icon(Icons.add),
              label: const Text('Add engine'),
            ),
            const SizedBox(height: Space.m),
            _startPosition(),
            _choices('Format', _values, 'format', {
              'roundRobin': 'Round robin',
              'gauntlet': 'Gauntlet',
            }, 'roundRobin'),
            _number(
              'Games per pairing',
              _values,
              'gamesPerPairing',
              10,
              1,
              1000,
            ),
            _number('Simultaneous games', _values, 'concurrency', 1, 1, 64),
            _toggle('Alternate colors', _values, 'alternateColors', true),
            _presets(),
            _choices('Time control', _time, 'kind', {
              'movetime': 'Time per move',
              'incremental': 'Clock + increment',
              'fixedDepth': 'Fixed depth',
              'fixedNodes': 'Fixed nodes',
            }, 'movetime'),
            ..._limits(),
            _toggle('Annotate evaluations', _values, 'annotateMoves', false),
            ExpansionTile(
              title: const Text('Adjudication'),
              children: _adjudication(),
            ),
            if (_problem != null)
              Text(
                _problem!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _start, child: const Text('Start new run')),
    ],
  );

  /// The FEN the games start from beside a small board showing it, greyed
  /// while no game could start from it; typed, taken from the board on
  /// screen, or set up in the board editor.
  Widget _startPosition() {
    final setup = SetupEdits.read(_fen.text);
    final playable = setup != null && setup.illegal == null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(
          opacity: playable ? 1 : 0.4,
          child: StaticChessboard(
            size: setupPreviewSize,
            orientation: Side.white,
            fen: (setup ?? Setup.standard).fen,
            settings: BoardTheme.of(context).previewSettings,
          ),
        ),
        const SizedBox(width: Space.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _fen,
                style: monoText,
                onChanged: (_) => _change(() {}),
                decoration: InputDecoration(
                  labelText: 'Starting FEN',
                  errorText: playable ? null : 'Use a legal starting FEN.',
                ),
              ),
              Wrap(
                children: [
                  TextButton(
                    onPressed: () =>
                        _change(() => _fen.text = Fen.initial.value),
                    child: const Text('Start position'),
                  ),
                  TextButton(
                    onPressed: () =>
                        _change(() => _fen.text = widget.position.value),
                    child: const Text('Current board'),
                  ),
                  TextButton(
                    onPressed: () => unawaited(_editPosition()),
                    child: const Text('Edit position…'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _editPosition() async {
    final start = playableFen(_fen.text) ?? Fen.initial;
    final edited = await showBoardEditor(context, initial: start);
    if (edited != null) _change(() => _fen.text = edited.value);
  }

  Widget _seat(int index) {
    final engine = _seats[index];
    final options = [TournamentEngine.bundled(), ...widget.engines];
    return Row(
      children: [
        Expanded(
          child: ChoiceField(
            text: engine.name,
            hint: 'Engine ${index + 1}',
            options: options.map((e) => e.name).toList(),
            onChanged: (name) {
              final found = options.where((e) => e.name == name).firstOrNull;
              if (found != null) _change(() => _seats[index] = found);
            },
          ),
        ),
        IconButton(
          tooltip: 'Remove engine ${index + 1}',
          onPressed: _seats.length > 2
              ? () => _change(() => _seats.removeAt(index))
              : null,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }

  Widget _number(
    String name,
    Map<String, Object?> data,
    String key,
    int value,
    int min,
    int max,
  ) => Row(
    children: [
      Expanded(child: Text(name)),
      NumberField(
        label: name,
        value: tournamentInt(data, key, value),
        min: min,
        max: max,
        onChanged: (n) => _change(() => data[key] = n),
      ),
    ],
  );
  Widget _toggle(
    String name,
    Map<String, Object?> data,
    String key,
    bool value,
  ) => CheckboxListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(name),
    value: data[key] as bool? ?? value,
    onChanged: (n) => _change(() => data[key] = n),
  );
  Widget _choices(
    String name,
    Map<String, Object?> data,
    String key,
    Map<String, String> options,
    String fallback,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.s),
    child: Row(
      children: [
        Expanded(child: Text(name)),
        SizedBox(
          width: 240,
          child: ChoiceField(
            text: options[data[key] ?? fallback] ?? options[fallback]!,
            options: options.values.toList(),
            hint: name,
            onChanged: (text) {
              final found = options.entries
                  .where((e) => e.value == text)
                  .firstOrNull;
              if (found != null) _change(() => data[key] = found.key);
            },
          ),
        ),
      ],
    ),
  );

  /// One click sets the whole time control; the fields below stay for a
  /// custom one, and a chip is lit while the fields still say what it set.
  Widget _presets() {
    final current = describeTime(_time);
    return Padding(
      padding: const EdgeInsets.only(top: Space.s),
      child: Wrap(
        spacing: Space.xs,
        runSpacing: Space.xs,
        children: [
          for (final preset in tournamentTimePresets)
            ChoiceChip(
              showCheckmark: false,
              label: Text(preset.label),
              tooltip: describeTime(preset.time),
              selected: describeTime(preset.time) == current,
              onSelected: (_) => _change(
                () => _time
                  ..clear()
                  ..addAll(preset.time),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _limits() => switch (_time['kind'] ?? 'movetime') {
    'incremental' => [
      _number('Initial clock (ms)', _time, 'baseMs', 60000, 1, 3600000),
      _number('Increment (ms)', _time, 'incrementMs', 600, 0, 60000),
      _number(
        'Moves per period (0 = sudden death)',
        _time,
        'movesPerSession',
        0,
        0,
        1000,
      ),
    ],
    'fixedDepth' => [_number('Depth', _time, 'depth', 12, 1, 128)],
    'fixedNodes' => [_number('Nodes', _time, 'nodes', 1000000, 1, 2000000000)],
    _ => [_number('Time per move (ms)', _time, 'movetimeMs', 2000, 1, 3600000)],
  };
  List<Widget> _adjudication() => [
    _number('Maximum moves', _rules, 'maxMoves', 300, 1, 10000),
    _toggle('Fifty-move rule', _rules, 'fiftyMoveRule', true),
    _toggle('Threefold repetition', _rules, 'threefoldRepetition', true),
    _toggle('Adjudicate draws', _rules, 'drawEnabled', true),
    _number('Draw from move', _rules, 'drawMoveNumber', 40, 1, 10000),
    _number('Consecutive level moves', _rules, 'drawMoveCount', 8, 1, 1000),
    _number('Draw threshold (cp)', _rules, 'drawScoreCp', 10, 0, 10000),
    _toggle('Adjudicate resignation', _rules, 'resignEnabled', true),
    _toggle('Both engines must agree', _rules, 'twoSidedResign', true),
    _number('Consecutive losing moves', _rules, 'resignMoveCount', 4, 1, 1000),
    _number(
      'Resignation threshold (cp)',
      _rules,
      'resignScoreCp',
      900,
      1,
      32000,
    ),
  ];
  void _start() {
    FocusScope.of(context).unfocus();
    final value = TournamentConfig({
      ..._values,
      'name': _name.text.trim(),
      'startFen': _fen.text.trim(),
      'engines': _seats.map((e) => e.json).toList(),
      // Sudden death is saved as v1 saves it, without the key: v1 reads
      // a 0 as a 0-move period and divides by it.
      'timeControl': {
        ..._time,
      }..removeWhere((k, v) => k == 'movesPerSession' && (v is! num || v <= 0)),
      'adjudication': _rules,
    });
    if (value.problem case final message?) {
      _change(() => _problem = message);
      return;
    }
    Navigator.pop(context, value);
  }
}
