import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chess/tournament/config.dart';
import '../../ui/app_icons.dart';
import '../../ui/attempting.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/field_row.dart';
import '../../ui/form_dialog.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';
import '../../ui/tool_button.dart';
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
        width: dialogWide,
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
                      ToolButton(
                        icon: AppIcons.edit,
                        tooltip: 'Edit ${engine.name}…',
                        onPressed: run.registryBusy || run.running
                            ? null
                            : () => unawaited(_edit(context, run, engine)),
                      ),
                      ToolButton(
                        icon: AppIcons.remove,
                        tooltip: 'Remove ${engine.name}…',
                        onPressed: run.registryBusy || run.running
                            ? null
                            : () => unawaited(_remove(context, run, engine)),
                      ),
                    ],
                  ),
                ),
              if (run.engineReport case final report?) Text(report),
            ],
          ),
        ),
      ),
      // Nothing here waits for an answer, so Close; the action at the right.
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton.icon(
          onPressed: run.registryBusy || run.running
              ? null
              : () => unawaited(_edit(context, run, null)),
          icon: const Icon(AppIcons.add, size: IconSize.action),
          label: const Text('Add UCI engine…'),
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
    title: 'Remove “${engine.name}”?',
    message: 'Saved runs keep their engine settings.',
    confirm: 'Remove',
  )) {
    await run.keepEngines(run.engines.where((e) => e.id != engine.id).toList());
  }
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

class _EditorState extends State<_Editor> with Attempting<_Editor> {
  late final _name = TextEditingController(text: widget.engine?.name ?? '');
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
  List<String> _output = const [];

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
  Widget build(BuildContext context) => FormDialog(
    title: widget.engine == null ? 'Add UCI engine' : 'Edit engine',
    width: dialogWide,
    confirm: busy ? 'Testing…' : 'Test and save',
    onConfirm: () => unawaited(_save()),
    busy: busy,
    canFail: true,
    problem: problem,
    body: SingleChildScrollView(
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
                onPressed: busy ? null : () => unawaited(_pick()),
                icon: const Icon(AppIcons.open, size: IconSize.action),
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
          if (_output.isNotEmpty) EngineOutput(lines: _output),
        ],
      ),
    ),
  );
  Widget _number(String name, int value, int max, void Function(int) change) =>
      FieldRow(
        label: name,
        child: NumberField(
          label: name,
          value: value,
          min: 1,
          max: max,
          onChanged: (n) => setState(() => change(n)),
        ),
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
    final engine = _engine(_name.text.trim());
    if (engine == null) {
      setState(() => problem = 'Write each UCI option as name=value.');
      return;
    }
    if (engine.name.isEmpty) {
      setState(() => problem = 'Name the engine.');
      return;
    }
    setState(() => _output = const []);
    final kept = await attempt(
      'test and save engine',
      () => _verifyAndKeep(engine),
      failure: 'Could not test the engine.',
    );
    if (mounted && (kept ?? false)) Navigator.pop(context);
  }

  /// Tests [engine] and keeps it in the list; false with [problem] (and
  /// for a failed test [_output]) saying why it is not kept.
  Future<bool> _verifyAndKeep(TournamentEngine tested) async {
    var engine = tested;
    final check = await widget.run.verify(engine);
    if (!mounted) return false;
    if (check case EngineRejected(:final reason, :final output)) {
      setState(() {
        problem = reason;
        _output = output;
      });
      return false;
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
    final kept = widget.run.engines.any((e) => identical(e, engine));
    if (!kept && mounted) setState(() => problem = widget.run.engineReport);
    return kept;
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
