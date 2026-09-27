import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../ui/theme.dart';
import '../../chess/players/player.dart';
import 'players.dart';

Future<Player?> editPlayer(
  BuildContext context,
  Players players, {
  Player? player,
}) => showDialog<Player>(
  context: context,
  builder: (_) => _PlayerDialog(players: players, player: player),
);

class _PlayerDialog extends StatefulWidget {
  const _PlayerDialog({required this.players, this.player});
  final Players players;
  final Player? player;
  @override
  State<_PlayerDialog> createState() => _PlayerDialogState();
}

class _PlayerDialogState extends State<_PlayerDialog> {
  final _form = GlobalKey<FormState>();
  static const fields = {
    'name': 'Name',
    'chesscom': 'Chess.com usernames',
    'lichess': 'Lichess usernames',
    'aliases': 'Names used in PGN files',
    'uscf_id': 'US Chess ID',
    'fide_id': 'FIDE ID',
    'rating': 'Rating',
    'notes': 'Prep notes',
  };
  late final _boxes = {
    for (final key in fields.keys)
      key: TextEditingController(
        text: key == 'aliases'
            ? widget.player?.strings(key).join('; ') ?? ''
            : widget.player?.text(key) ?? '',
      ),
  };
  late final _files = {...?widget.player?.files};
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    for (final c in _boxes.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final player = (widget.player ?? Player.create(_boxes['name']!.text))
        .edited({
          'pgn_files': _files.toList(),
          for (final e in _boxes.entries)
            e.key: switch (e.key) {
              'aliases' =>
                e.value.text
                    .split(';')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList(),
              'rating' || 'fide_id' => int.tryParse(e.value.text),
              _ => e.value.text.trim(),
            },
        });
    final saved = await widget.players.save(player, expected: widget.player);
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop(player);
    } else {
      setState(() {
        _saving = false;
        _error =
            widget.players.error ??
            'Save could not complete. Retry from the player list.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.player == null ? 'Add player' : 'Edit ${widget.player!.name}',
    ),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.m),
                  child: TextFormField(
                    controller: _boxes[e.key],
                    autofocus: e.key == 'name',
                    minLines: e.key == 'notes' ? 3 : 1,
                    maxLines: e.key == 'notes' ? 6 : 1,
                    decoration: InputDecoration(
                      labelText: e.value,
                      helperText: e.key == 'aliases'
                          ? 'Separate exact spellings with semicolons.'
                          : e.key == 'chesscom' || e.key == 'lichess'
                          ? 'Separate multiple usernames with commas.'
                          : null,
                    ),
                    validator: (value) {
                      final text = value?.trim() ?? '';
                      if (e.key == 'name' && text.isEmpty)
                        return 'Enter a player name.';
                      if ({'uscf_id', 'fide_id', 'rating'}.contains(e.key) &&
                          text.isNotEmpty &&
                          !RegExp(r'^\d+$').hasMatch(text))
                        return 'Use digits only.';
                      if ({'chesscom', 'lichess'}.contains(e.key) &&
                          text.isNotEmpty &&
                          !RegExp(r'^[a-zA-Z0-9_,;\s-]+$').hasMatch(text))
                        return 'Enter usernames, not profile URLs.';
                      return null;
                    },
                  ),
                ),
              if (_files.isNotEmpty)
                Wrap(
                  spacing: Space.s,
                  children: [
                    for (final file in _files)
                      InputChip(
                        label: Text(p.basename(file)),
                        onDeleted: _saving
                            ? null
                            : () {
                                if (mounted)
                                  setState(() => _files.remove(file));
                              },
                      ),
                  ],
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? 'Saving…' : 'Save player'),
      ),
    ],
  );
}

Future<void> importPlayers(BuildContext context, Players players) =>
    showDialog<void>(context: context, builder: (_) => _ImportDialog(players));

class _ImportDialog extends StatefulWidget {
  const _ImportDialog(this.players);
  final Players players;
  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _text = TextEditingController();
  List<Player>? _preview;
  String? _error;
  bool _saving = false;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _read() {
    try {
      final read = readPlayerList(_text.text);
      if (read.isEmpty) throw const FormatException('No players found.');
      setState(() {
        _preview = read;
        _error = null;
      });
    } on Object catch (e) {
      setState(() {
        _preview = null;
        _error = '$e';
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final saved = await widget.players.import(_preview!);
    if (!mounted) return;
    if (saved)
      Navigator.pop(context);
    else
      setState(() {
        _saving = false;
        _error = widget.players.error;
      });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Paste players'),
    content: SizedBox(
      width: 560,
      height: 420,
      child: Column(
        children: [
          TextField(
            controller: _text,
            minLines: 5,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Table or opponents JSON',
              hintText: 'Name, Rating, Chess.com, Lichess',
            ),
            onChanged: (_) {
              if (mounted) setState(() => _preview = null);
            },
          ),
          const SizedBox(height: Space.m),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_preview != null) ...[
            Text(
              '${_preview!.length} players · existing records keep their notes and filled fields',
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final p in _preview!)
                    ListTile(
                      title: Text(p.name),
                      subtitle: Text(
                        p.accounts
                            .map((a) => '${a.site.label}: ${a.username}')
                            .join(' · '),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      if (_preview == null)
        FilledButton(onPressed: _read, child: const Text('Preview players'))
      else
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(
            _saving
                ? 'Saving…'
                : widget.players.group == null
                ? 'Add players'
                : 'Add to group',
          ),
        ),
    ],
  );
}
