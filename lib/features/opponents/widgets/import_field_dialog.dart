/// Bring an opponent list (`opponents.json` from the MCP server, or one
/// written by hand) into a tournament. Choose the file or paste the text;
/// the preview says what will land before anything is written.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../services/opponent_list.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/file_text_reader.dart';

/// Pops with the parsed list, or null.
class ImportFieldDialog extends StatefulWidget {
  const ImportFieldDialog({super.key});

  @override
  State<ImportFieldDialog> createState() => _ImportFieldDialogState();
}

class _ImportFieldDialogState extends State<ImportFieldDialog> {
  final _text = TextEditingController();
  String? _fileName;
  OpponentList? _parsed;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text.addListener(_reparse);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );
      final path = file?.path;
      if (file == null || path == null || !mounted) return;
      final text = await readTextFile(File(path));
      if (!mounted) return;
      setState(() => _fileName = file.name);
      _text.text = text;
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read the file: $e');
    }
  }

  void _reparse() {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() {
        _parsed = null;
        _error = null;
      });
      return;
    }
    try {
      final list = OpponentList.parse(text, keepAccountless: true);
      setState(() {
        _parsed = list;
        _error = null;
      });
    } on FormatException catch (e) {
      setState(() {
        _parsed = null;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    final n = parsed?.opponents.length ?? 0;
    return AlertDialog(
      title: const Text('Import opponents'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                OutlinedButton(
                  onPressed: _pickFile,
                  child: Text(
                    _fileName == null ? 'Choose a file…' : 'Choose another…',
                  ),
                ),
                if (_fileName != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _fileName!,
                      style: AppTextStyles.caption,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('import-field-text'),
              controller: _text,
              maxLines: 6,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: AppTextStyles.monoFamily,
              ),
              decoration: const InputDecoration(
                labelText: 'Or paste the list',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
                hintText:
                    '[{"name": "Jane Doe", "uscf_id": "12345678", '
                    '"chesscom": "janed"}]',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ??
                  (parsed == null
                      ? 'An opponents.json from the chess-prep tool, or a '
                            'JSON list of name, uscf_id, chesscom, lichess.'
                      : '${parsed.event ?? 'No event name'} · '
                            '$n ${n == 1 ? 'opponent' : 'opponents'}'
                            '${parsed.warnings.isEmpty ? '' : ' · ${parsed.warnings.length} rows skipped'}'),
              key: const Key('import-field-status'),
              style: AppTextStyles.caption.copyWith(
                color: _error != null
                    ? AppColors.danger
                    : AppColors.onSurfaceMuted,
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
          key: const Key('import-field-confirm'),
          onPressed: parsed == null || n == 0
              ? null
              : () => Navigator.of(context).pop(parsed),
          child: Text(n == 0 ? 'Import' : 'Import $n'),
        ),
      ],
    );
  }
}
