import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../services/opponent_list.dart';
import '../services/player_list_parser.dart';

/// Pasting and previewing happens on the group page, not in a dialog.
class PlayerImportPanel extends StatefulWidget {
  const PlayerImportPanel({
    super.key,
    required this.onImport,
    this.importLabel = 'Add to group',
  });
  final String importLabel;
  final Future<void> Function(OpponentList) onImport;
  @override
  State<PlayerImportPanel> createState() => _PlayerImportPanelState();
}

class _PlayerImportPanelState extends State<PlayerImportPanel> {
  final _text = TextEditingController();
  OpponentList? _list;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _list = null;
    });
    try {
      var text = _text.text.trim();
      final uri = Uri.tryParse(text);
      if (uri != null &&
          (uri.scheme == 'https' || uri.scheme == 'http') &&
          !text.contains('\n')) {
        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          throw FormatException(
            'Could not load the page (${response.statusCode}). Copy and paste its table instead.',
          );
        }
        text = playerTableTextFromHtml(response.body);
      }
      final list = parsePlayerList(text);
      if (mounted) setState(() => _list = list);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_list == null || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onImport(_list!);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save players: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _text,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText:
                'Paste a player table (with column headings), or an entry-list URL.',
          ),
          onChanged: (_) {
            if (mounted) setState(() => _list = null);
          },
        ),
        Row(
          children: [
            OutlinedButton(
              onPressed: _busy ? null : _preview,
              child: Text(_busy ? 'Working…' : 'Preview players'),
            ),
            if (_list != null) ...[
              Text('${_list!.opponents.length} players'),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _busy ? null : _import,
                child: Text(widget.importLabel),
              ),
            ],
          ],
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_list != null)
          SizedBox(
            height: 100,
            child: ListView(
              children: [
                for (final p in _list!.opponents)
                  Text(
                    '${p.name} · ${p.uscfId ?? 'No USCF ID'} · ${p.rating ?? 'unrated'}',
                  ),
                for (final warning in _list!.warnings) Text(warning),
              ],
            ),
          ),
      ],
    ),
  );
}
