import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/opponent_list.dart';
import '../utils/file_text_reader.dart';

/// What the user asked for: which list, how far back to fetch, and whether
/// opponents already on disk should be fetched again.
class OpponentImportRequest {
  final OpponentList list;
  final int monthsBack;
  final bool redownloadExisting;

  const OpponentImportRequest({
    required this.list,
    required this.monthsBack,
    required this.redownloadExisting,
  });
}

/// Dialog for importing an opponent list into Player Analysis.
///
/// The list names the people you are about to play and their chess.com /
/// lichess accounts (see `opponent_list.dart` for the format — the
/// `tools/mcp/chess_prep` server writes it, or write it by hand). Each
/// opponent becomes one player entry whose games are downloaded from every
/// account listed.
///
/// Pops with an [OpponentImportRequest], or `null` if the user cancels.
class OpponentListImportDialog extends StatefulWidget {
  const OpponentListImportDialog({super.key});

  @override
  State<OpponentListImportDialog> createState() =>
      _OpponentListImportDialogState();
}

class _OpponentListImportDialogState extends State<OpponentListImportDialog> {
  final _textController = TextEditingController();
  final _monthsController = TextEditingController(text: '6');

  String? _fileName;
  OpponentList? _parsed;
  String? _parseError;
  bool _redownloadExisting = false;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_reparse);
  }

  @override
  void dispose() {
    _textController.dispose();
    _monthsController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );
      final path = result?.files.single.path;
      if (path == null || !mounted) return;
      final text = await readTextFile(File(path));
      if (!mounted) return;
      setState(() => _fileName = result!.files.single.name);
      // Setting the text triggers _reparse through the listener.
      _textController.text = text;
    } catch (e) {
      if (!mounted) return;
      setState(() => _parseError = 'Could not read file: $e');
    }
  }

  void _reparse() {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _parsed = null;
        _parseError = null;
      });
      return;
    }
    try {
      final list = OpponentList.parse(text);
      setState(() {
        _parsed = list;
        _parseError = null;
      });
    } on FormatException catch (e) {
      setState(() {
        _parsed = null;
        _parseError = e.message;
      });
    }
  }

  int? get _months {
    final n = int.tryParse(_monthsController.text.trim());
    return (n == null || n < 1) ? null : n;
  }

  bool get _canImport =>
      _parsed != null && _parsed!.downloadable.isNotEmpty && _months != null;

  void _confirm() {
    if (!_canImport) return;
    Navigator.of(context).pop(
      OpponentImportRequest(
        list: _parsed!,
        monthsBack: _months!,
        redownloadExisting: _redownloadExisting,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final parsed = _parsed;

    return AlertDialog(
      title: const Text('Import Opponents'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add a whole field at once. Each opponent becomes a player '
                'here, with games from every account listed.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                'Made by the chess_prep tool (opponents_export), or by hand: '
                'a JSON list of {"name", "chesscom", "lichess"}.',
                style: muted,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.file_open, size: 18),
                    label: Text(
                      _fileName == null
                          ? 'Choose File'
                          : 'Choose Different File',
                    ),
                  ),
                  if (_fileName != null) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _fileName!,
                        style: muted,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _textController,
                maxLines: 6,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Or paste the list',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                  hintText:
                      '[{"name": "Jane Doe", "chesscom": "janed", '
                      '"lichess": "jd_li"}]',
                ),
              ),
              if (_parseError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _parseError!,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (parsed != null) ...[
                const SizedBox(height: 12),
                _ListPreview(list: parsed),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _monthsController,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Months',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Games from the last N months, per account.',
                      style: muted,
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                value: _redownloadExisting,
                onChanged: (v) =>
                    setState(() => _redownloadExisting = v ?? false),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Re-download opponents already saved'),
                subtitle: Text(
                  'Off: keep their current games and only fetch new people.',
                  style: muted,
                ),
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
        FilledButton(
          onPressed: _canImport ? _confirm : null,
          child: Text(
            parsed == null
                ? 'Import'
                : 'Import ${parsed.downloadable.length} '
                      'opponent${parsed.downloadable.length == 1 ? '' : 's'}',
          ),
        ),
      ],
    );
  }
}

/// Event name, how many rows are usable, and what was skipped — shown before
/// the download so a broken list is caught here rather than after ten
/// network calls.
class _ListPreview extends StatelessWidget {
  final OpponentList list;

  const _ListPreview({required this.list});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final usable = list.downloadable;
    final accounts = usable.fold<int>(0, (n, o) => n + o.accounts.length);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${list.event ?? 'Opponents'} — ${usable.length} '
            'opponent${usable.length == 1 ? '' : 's'}, $accounts '
            'account${accounts == 1 ? '' : 's'}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: usable.isEmpty ? theme.colorScheme.error : null,
            ),
          ),
          if (usable.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              usable
                      .take(6)
                      .map(
                        (o) => o.pairingProb == null
                            ? o.name
                            : '${o.name} '
                                  '(${(o.pairingProb! * 100).toStringAsFixed(0)}%)',
                      )
                      .join(', ') +
                  (usable.length > 6 ? ', …' : ''),
              style: muted,
            ),
          ],
          for (final w in list.warnings.take(5)) ...[
            const SizedBox(height: 4),
            Text('• $w', style: muted),
          ],
          if (list.warnings.length > 5) ...[
            const SizedBox(height: 4),
            Text('• …and ${list.warnings.length - 5} more', style: muted),
          ],
        ],
      ),
    );
  }
}
