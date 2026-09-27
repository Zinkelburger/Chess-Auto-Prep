import 'package:flutter/material.dart';

import '../../chess/fen.dart';
import '../../chess/tournament/config.dart';
import '../../ui/choice_field.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';

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
            TextField(
              controller: _fen,
              decoration: const InputDecoration(labelText: 'Starting FEN'),
            ),
            Wrap(
              children: [
                TextButton(
                  onPressed: () => _fen.text = Fen.initial.value,
                  child: const Text('Start position'),
                ),
                TextButton(
                  onPressed: () => _fen.text = widget.position.value,
                  child: const Text('Current board'),
                ),
              ],
            ),
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
      'timeControl': _time,
      'adjudication': _rules,
    });
    if (value.problem case final message?) {
      _change(() => _problem = message);
      return;
    }
    Navigator.pop(context, value);
  }
}
