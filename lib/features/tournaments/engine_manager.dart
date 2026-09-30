import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chess/tournament/config.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';
import 'engine_check.dart';
import 'tournament_run.dart';

Future<void> manageTournamentEngines(
  BuildContext context,
  TournamentRun run,
) => showDialog<void>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: run,
    builder: (context, _) => AlertDialog(
      title: const Text('Tournament engines'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('Bundled Stockfish'),
                subtitle: Text('Always available; add named settings below.'),
              ),
              for (final engine in run.engines)
                ListTile(
                  title: Text(engine.name),
                  subtitle: Text(
                    '${engine.threads} cores · ${engine.memory} MB · ${engine.executable ?? "Bundled Stockfish"}',
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: 'Edit ${engine.name}',
                        onPressed: run.registryBusy || run.running
                            ? null
                            : () => unawaited(_edit(context, run, engine)),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: 'Remove ${engine.name}',
                        onPressed: run.registryBusy || run.running
                            ? null
                            : () => unawaited(_remove(context, run, engine)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              if (run.engineReport case final report?) Text(report),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: run.registryBusy || run.running
              ? null
              : () => unawaited(_edit(context, run, null)),
          child: const Text('Add UCI engine…'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  ),
);

Future<void> _remove(
  BuildContext context,
  TournamentRun run,
  TournamentEngine engine,
) async {
  if (await confirmAction(
    context,
    title: 'Remove engine',
    message:
        'Remove ${engine.name} from the registry? Saved runs retain their engine settings.',
    confirm: 'Remove',
  ))
    await run.keepEngines(run.engines.where((e) => e.id != engine.id).toList());
}

Future<void> _edit(
  BuildContext context,
  TournamentRun run,
  TournamentEngine? engine,
) => showDialog<void>(
  context: context,
  builder: (_) => _Editor(run: run, engine: engine),
);

class _Editor extends StatefulWidget {
  const _Editor({required this.run, this.engine});
  final TournamentRun run;
  final TournamentEngine? engine;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final _name = TextEditingController(
    text: widget.engine?.name ?? 'Stockfish settings',
  );
  late final _path = TextEditingController(
    text: widget.engine?.executable ?? '',
  );
  late final _args = TextEditingController(
    text: widget.engine?.arguments.join('\n') ?? '',
  );
  late final _options = TextEditingController(
    text: tournamentObject(
      widget.engine?.json['options'],
    ).entries.map((e) => '${e.key}=${e.value}').join('\n'),
  );
  late final _id =
      widget.engine?.id ?? 'engine-${DateTime.now().microsecondsSinceEpoch}';
  int _cores = 1, _memory = 128;
  String? _problem;
  List<String> _output = const [];
  bool _busy = false;

  /// A new engine's name follows the file until the user types one: the
  /// file's name when picked, the engine's `id name` once tested.
  bool _autoName = false;
  @override
  void initState() {
    super.initState();
    _autoName = widget.engine == null;
    _cores = widget.engine?.threads ?? 1;
    _memory = widget.engine?.memory ?? 128;
  }

  @override
  void dispose() {
    for (final c in [_name, _path, _args, _options]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.engine == null ? 'Add UCI engine' : 'Edit engine'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              onChanged: (_) => _autoName = false,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _path,
                    decoration: const InputDecoration(
                      labelText: 'Executable path (empty = bundled Stockfish)',
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : () => unawaited(_pick()),
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Choose file…'),
                ),
              ],
            ),
            _number('Cores', _cores, 1024, (n) => _cores = n),
            _number('Hash (MB)', _memory, 65536, (n) => _memory = n),
            TextField(
              controller: _args,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Arguments (one per line)',
              ),
            ),
            TextField(
              controller: _options,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'UCI options (name=value, one per line)',
              ),
            ),
            if (_problem case final message?)
              Padding(
                padding: const EdgeInsets.only(top: Space.m),
                child: SelectableText(message),
              ),
            if (_output.isNotEmpty) EngineOutput(lines: _output),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : () => unawaited(_save()),
        child: Text(_busy ? 'Testing…' : 'Test and save'),
      ),
    ],
  );
  Widget _number(String name, int value, int max, void Function(int) change) =>
      Row(
        children: [
          Expanded(child: Text(name)),
          NumberField(
            label: name,
            value: value,
            min: 1,
            max: max,
            onChanged: (n) {
              if (mounted) setState(() => change(n));
            },
          ),
        ],
      );

  Future<void> _pick() async {
    final path = await widget.run.pickExecutable();
    if (!mounted || path == null) return;
    setState(() {
      _path.text = path;
      if (_autoName) _name.text = p.basenameWithoutExtension(path);
    });
  }

  TournamentEngine? _engine(String name) {
    final options = <String, String>{};
    for (final line
        in _options.text.split('\n').where((l) => l.trim().isNotEmpty)) {
      final at = line.indexOf('=');
      if (at <= 0) return null;
      options[line.substring(0, at).trim()] = line.substring(at + 1).trim();
    }
    return TournamentEngine({
      ...?widget.engine?.json,
      'id': _id,
      'name': name,
      'executablePath': _path.text.trim().isEmpty ? null : _path.text.trim(),
      'arguments': _args.text.split('\n').where((s) => s.isNotEmpty).toList(),
      'options': options,
      'threads': _cores,
      'hashMb': _memory,
      'ponder': false,
    });
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    var engine = _engine(_name.text.trim());
    if (engine == null) {
      setState(() => _problem = 'Write each UCI option as name=value.');
      return;
    }
    if (engine.name.isEmpty) {
      setState(() => _problem = 'Name the engine.');
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
      _output = const [];
    });
    final check = await widget.run.verify(engine);
    if (!mounted) return;
    if (check case EngineRejected(:final reason, :final output)) {
      setState(() {
        _busy = false;
        _problem = reason;
        _output = output;
      });
      return;
    }
    if (check case EngineVerified(
      :final name,
    ) when _autoName && engine.executable != null && name.isNotEmpty) {
      engine = _engine(name)!;
      _name.text = name;
    }
    await widget.run.keepEngines([
      for (final e in widget.run.engines)
        if (e.id != engine.id) e,
      engine,
    ]);
    if (!mounted) return;
    if (widget.run.engines.any((e) => identical(e, engine))) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _problem = widget.run.engineReport;
    });
  }
}

/// The first lines an engine wrote, under a failed test: its own words
/// beside the app's sentence.
class EngineOutput extends StatelessWidget {
  const EngineOutput({super.key, required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: Space.s),
    padding: const EdgeInsets.all(Space.s),
    constraints: const BoxConstraints(maxHeight: engineOutputHeight),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: SingleChildScrollView(
      child: SelectableText(lines.join('\n'), style: monoText),
    ),
  );
}
