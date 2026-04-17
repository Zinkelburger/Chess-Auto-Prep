/// PGN import dialog — file picker + paste textarea (Lichess-style).
///
/// The file picker hydrates the textarea so the user always sees and can
/// edit the PGN before importing. Works for both "create new repertoire
/// from PGN" and "append lines to the current repertoire".
library;

import 'dart:io' as io;

import 'package:dartchess/dartchess.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Result returned when the user confirms an import.
class PgnImportResult {
  final String pgnContent;
  final int gameCount;

  const PgnImportResult({required this.pgnContent, required this.gameCount});
}

/// Shows a bottom sheet for importing PGN — from file or pasted text.
///
/// Returns a [PgnImportResult] if the user confirms, or `null` on cancel.
Future<PgnImportResult?> showPgnImportDialog(
  BuildContext context, {
  String title = 'Import PGN',
  String confirmLabel = 'Import',
}) {
  return showModalBottomSheet<PgnImportResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _PgnImportSheet(
      title: title,
      confirmLabel: confirmLabel,
    ),
  );
}

class _PgnImportSheet extends StatefulWidget {
  final String title;
  final String confirmLabel;

  const _PgnImportSheet({
    required this.title,
    required this.confirmLabel,
  });

  @override
  State<_PgnImportSheet> createState() => _PgnImportSheetState();
}

class _PgnImportSheetState extends State<_PgnImportSheet> {
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
        _fileName = null;
      });
      return;
    }

    try {
      final count = _countGames(text);
      setState(() {
        _gameCount = count;
        _error = count == 0 ? 'No valid games found in PGN.' : null;
      });
    } catch (e) {
      setState(() {
        _gameCount = 0;
        _error = 'Could not parse PGN: $e';
      });
    }
  }

  int _countGames(String pgn) {
    final headerMatches = RegExp(r'\[Event\s').allMatches(pgn).length;
    if (headerMatches > 0) return headerMatches;

    // Bare movetext without headers — try parsing as a single game.
    try {
      final game = PgnGame.parsePgn(pgn);
      if (game.moves.mainline().isNotEmpty) return 1;
    } catch (_) {}
    return 0;
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pgn', 'txt'],
        withData: false,
        withReadStream: false,
      );

      if (result == null || result.files.isEmpty) return;

      final path = result.files.single.path;
      if (path == null) return;

      final content = await io.File(path).readAsString();
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

    Navigator.of(context).pop(PgnImportResult(
      pgnContent: text,
      gameCount: _gameCount,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outline.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.upload_file, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            const Divider(),

            // Body
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  // File picker row
                  OutlinedButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.file_open),
                    label: Text(_fileName ?? 'Open .pgn file'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        Expanded(child: Divider(color: cs.outlineVariant)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            'or paste PGN text',
                            style: TextStyle(
                              fontSize: 12,
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
                    maxLines: null,
                    minLines: 10,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      hintText:
                          '[Event "My Opening"]\n[White "Me"]\n[Black "Opponent"]\n'
                          '[Result "*"]\n\n1. e4 e5 2. Nf3 *',
                      hintStyle: TextStyle(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                    onChanged: (_) => _recount(),
                  ),

                  const SizedBox(height: 12),

                  // Status / error
                  if (_error != null)
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              size: 18, color: cs.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: cs.onErrorContainer,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (_gameCount > 0)
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle_outline,
                              size: 18, color: cs.onPrimaryContainer),
                          const SizedBox(width: 8),
                          Text(
                            '$_gameCount game${_gameCount == 1 ? '' : 's'} found',
                            style: TextStyle(
                              color: cs.onPrimaryContainer,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            // Footer actions
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.3)),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _gameCount > 0 ? _confirm : null,
                      icon: const Icon(Icons.download),
                      label: Text(widget.confirmLabel),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
