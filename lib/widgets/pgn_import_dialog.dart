/// Compact PGN import dialog — file picker + paste textarea.
///
/// Used for "create new repertoire with PGN" and other contexts that need
/// both file-pick and paste in one compact dialog. The main repertoire
/// screen uses inline popup menus instead (see PgnWithAnalysisPane).
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/storage/storage_factory.dart';

/// Result returned when the user confirms an import.
class PgnImportResult {
  final String pgnContent;
  final int gameCount;

  const PgnImportResult({required this.pgnContent, required this.gameCount});
}

/// Shows a compact dialog for importing PGN — from file or pasted text.
///
/// Returns a [PgnImportResult] if the user confirms, or `null` on cancel.
Future<PgnImportResult?> showPgnImportDialog(
  BuildContext context, {
  String title = 'Import PGN',
  String confirmLabel = 'Import',
}) {
  return showDialog<PgnImportResult>(
    context: context,
    builder: (context) =>
        _PgnImportDialog(title: title, confirmLabel: confirmLabel),
  );
}

class _PgnImportDialog extends StatefulWidget {
  final String title;
  final String confirmLabel;

  const _PgnImportDialog({required this.title, required this.confirmLabel});

  @override
  State<_PgnImportDialog> createState() => _PgnImportDialogState();
}

class _PgnImportDialogState extends State<_PgnImportDialog> {
  final _controller = TextEditingController();
  int _gameCount = 0;
  String? _error;
  String? _fileName;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _recount() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() {
        _gameCount = 0;
        _error = null;
      });
      return;
    }

    try {
      final count = pgn.countPgnGames(text);
      setState(() {
        _gameCount = count;
        _error = count == 0 ? 'No valid lines found in PGN.' : null;
      });
    } catch (e) {
      setState(() {
        _gameCount = 0;
        _error = 'Could not parse PGN: $e';
      });
    }
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pgn', 'txt'],
        withData: false,
        withReadStream: false,
      );

      if (result == null || result.files.isEmpty) return;

      final path = result.files.single.path;
      if (path == null) return;

      final content = await StorageFactory.instance.readFile(path);
      if (content == null) return;
      _controller.text = content;
      setState(() => _fileName = result.files.single.name);
      _recount();
    } catch (e) {
      setState(() => _error = 'Could not read file: $e');
    }
  }

  void _confirm() {
    final text = _controller.text.trim();
    if (text.isEmpty || _gameCount == 0) return;

    Navigator.of(
      context,
    ).pop(PgnImportResult(pgnContent: text, gameCount: _gameCount));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.upload_file, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Text(widget.title, style: const TextStyle(fontSize: 16)),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // File picker pill
            OutlinedButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.file_open, size: 16),
              label: Text(
                _fileName ?? 'Open .pgn file',
                style: const TextStyle(fontSize: 13),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(38),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(child: Divider(color: cs.outlineVariant)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      'or paste',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(child: Divider(color: cs.outlineVariant)),
                ],
              ),
            ),

            // Textarea
            TextField(
              controller: _controller,
              maxLines: 6,
              minLines: 3,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                hintText:
                    '[Event "Opening"]\n[Result "*"]\n\n1. e4 e5 2. Nf3 *',
                hintStyle: TextStyle(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.all(10),
              ),
              onChanged: (_) => _recount(),
            ),

            const SizedBox(height: 8),

            // Status row
            if (_error != null)
              Row(
                children: [
                  Icon(Icons.warning_amber, size: 14, color: cs.error),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: 11, color: cs.error),
                    ),
                  ),
                ],
              )
            else if (_gameCount > 0)
              Row(
                children: [
                  Icon(Icons.check_circle_outline, size: 14, color: cs.primary),
                  const SizedBox(width: 6),
                  Text(
                    '$_gameCount line${_gameCount == 1 ? '' : 's'} found',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: cs.primary,
                    ),
                  ),
                ],
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
          onPressed: _gameCount > 0 ? _confirm : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
