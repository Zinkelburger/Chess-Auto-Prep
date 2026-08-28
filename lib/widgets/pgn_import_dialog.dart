/// The one PGN import dialog — file picker and paste box in the same window.
///
/// Every "add PGN" entry point in the app opens this: picking a file and
/// pasting text used to be two separate menu items, which forced the user to
/// decide how they were importing before they were shown either option.
library;

import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/pgn_parsing_service.dart' as pgn;
import '../services/repertoire_color_inference.dart';
import '../services/repertoire_service.dart';
import '../services/storage/storage_factory.dart';

/// Result returned when the user confirms an import.
class PgnImportResult {
  final String pgnContent;
  final int gameCount;

  /// Name of the file this came off, or null when it was pasted in. Callers
  /// that name something after the import (a new repertoire) use it as the
  /// suggestion and fall back to their own default for pasted text.
  final String? fileName;

  const PgnImportResult({
    required this.pgnContent,
    required this.gameCount,
    this.fileName,
  });
}

/// Outcome of picking a `.pgn` off disk: either a parsed [result] with the
/// file's name, or a human-readable [error]. Cancelling the picker returns
/// null instead of an instance, so "cancelled" never looks like "failed".
class PickedPgnImport {
  const PickedPgnImport({
    this.result,
    this.error,
    this.fileName,
    this.suggestedName,
    this.suggestedColor,
  });

  final PgnImportResult? result;
  final String? error;
  final String? fileName;

  /// The file's base name, used to prefill the repertoire name so importing
  /// "Caro-Kann.pgn" doesn't produce a repertoire called "Imported".
  final String? suggestedName;

  /// 'White' / 'Black' read off the file's own move tree, or null when it
  /// does not say clearly. The colour picker starts here rather than always
  /// on White: the chosen value is written into the new repertoire's
  /// `// Color:` header, where it outranks every later guess — so a wrong
  /// default is not a wrong default for one session, it is permanent.
  final String? suggestedColor;
}

/// The side [pgnContent] looks like it trains, off the UI isolate — a course
/// export is megabytes and replaying every game blocks a frame otherwise.
Future<String?> inferImportColor(String pgnContent) async {
  try {
    return await Isolate.run(() {
      final lines = RepertoireService().parseRepertoirePgn(pgnContent);
      final guess = inferTrainingColor(lines);
      return guess == null ? null : (guess.isWhite ? 'White' : 'Black');
    });
  } catch (_) {
    // A file we cannot parse is one the picker will reject anyway; the colour
    // picker just stays where it was.
    return null;
  }
}

Future<PickedPgnImport?> pickPgnImport() async {
  try {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pgn', 'txt'],
    );
    if (picked == null) return null;

    final path = picked.path;
    if (path == null) return null;

    final content = await StorageFactory.instance.readFile(path);
    if (content == null) {
      return const PickedPgnImport(error: 'Could not read that file.');
    }

    final count = pgn.countPgnGames(content);
    final name = picked.name;
    if (count == 0) {
      return PickedPgnImport(error: 'No lines found in $name.', fileName: name);
    }
    return PickedPgnImport(
      result: PgnImportResult(
        pgnContent: content,
        gameCount: count,
        fileName: name,
      ),
      fileName: name,
      suggestedName: p.basenameWithoutExtension(name),
      suggestedColor: await inferImportColor(content),
    );
  } catch (e) {
    return PickedPgnImport(error: 'Could not read file: $e');
  }
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
  final _focus = FocusNode();
  int _gameCount = 0;
  String? _error;
  String? _fileName;

  /// What the picked file held, so typing over it drops the file name rather
  /// than attributing hand-edited text to a file that no longer matches.
  String? _loadedContent;
  bool _reading = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
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
        _error = count == 0 ? 'No lines found in that PGN.' : null;
      });
    } catch (e) {
      setState(() {
        _gameCount = 0;
        _error = 'Could not parse that PGN: $e';
      });
    }
  }

  Future<void> _pickFile() async {
    setState(() => _reading = true);
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pgn', 'txt'],
      );
      if (file == null) {
        if (mounted) setState(() => _reading = false);
        return;
      }

      final path = file.path;
      if (path == null) {
        if (mounted) setState(() => _reading = false);
        return;
      }

      final content = await StorageFactory.instance.readFile(path);
      if (!mounted) return;
      if (content == null) {
        setState(() {
          _reading = false;
          _error = 'Could not read that file.';
        });
        return;
      }
      _controller.text = content;
      setState(() {
        _fileName = file.name;
        _loadedContent = content;
        _reading = false;
      });
      _recount();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = 'Could not read file: $e';
      });
    }
  }

  /// Drops the loaded file and empties the box, so a mis-picked file is one
  /// click away from gone rather than something to select-all over.
  void _clear() {
    _controller.clear();
    setState(() {
      _fileName = null;
      _loadedContent = null;
      _error = null;
      _gameCount = 0;
    });
    _focus.requestFocus();
  }

  void _confirm() {
    final text = _controller.text.trim();
    if (text.isEmpty || _gameCount == 0) return;

    Navigator.of(context).pop(
      PgnImportResult(
        pgnContent: text,
        gameCount: _gameCount,
        fileName: _fileName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasText = _controller.text.trim().isNotEmpty;

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Row(
        children: [
          Expanded(
            child: Text(
              widget.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FilePickTile(
              fileName: _fileName,
              busy: _reading,
              onPressed: _reading ? null : _pickFile,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: Divider(color: cs.outlineVariant)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    'or paste it',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ),
                Expanded(child: Divider(color: cs.outlineVariant)),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              maxLines: 8,
              minLines: 5,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding: const EdgeInsets.all(12),
                isDense: true,
              ),
              onChanged: (value) {
                if (_fileName != null && value != _loadedContent) {
                  _fileName = null;
                  _loadedContent = null;
                }
                _recount();
              },
            ),
            SizedBox(
              height: 30,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _StatusLine(
                  error: _error,
                  gameCount: _gameCount,
                  onClear: hasText ? _clear : null,
                ),
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
          onPressed: _gameCount > 0 ? _confirm : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// The file half of the dialog: one wide target that names the loaded file
/// once there is one, so the button doubles as the "what did I pick" readout.
class _FilePickTile extends StatelessWidget {
  const _FilePickTile({
    required this.fileName,
    required this.busy,
    required this.onPressed,
  });

  final String? fileName;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loaded = fileName != null;

    return Material(
      color: loaded ? cs.primaryContainer : cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  loaded ? Icons.description_outlined : Icons.folder_open,
                  size: 18,
                  color: loaded ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  fileName ?? 'Choose a .pgn file…',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: loaded ? FontWeight.w600 : FontWeight.w500,
                    color: loaded ? cs.onPrimaryContainer : cs.onSurface,
                  ),
                ),
              ),
              if (loaded)
                Text(
                  'Change',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onPrimaryContainer.withValues(alpha: 0.75),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One reserved row under the box: the parse verdict on the left, and a clear
/// button once there is anything to clear. Fixed height so typing the first
/// character does not resize the dialog.
class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.error,
    required this.gameCount,
    required this.onClear,
  });

  final String? error;
  final int gameCount;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      children: [
        if (error != null) ...[
          Icon(Icons.warning_amber, size: 14, color: cs.error),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              error!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
          ),
        ] else if (gameCount > 0) ...[
          Icon(Icons.check_circle_outline, size: 14, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            '$gameCount line${gameCount == 1 ? '' : 's'} ready to import',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: cs.primary,
            ),
          ),
        ],
        const Spacer(),
        if (onClear != null)
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Clear', style: TextStyle(fontSize: 11)),
          ),
      ],
    );
  }
}
