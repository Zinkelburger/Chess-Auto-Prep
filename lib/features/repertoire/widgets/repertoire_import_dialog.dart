import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../services/pgn_parsing_service.dart' as pgn;
import '../../../services/repertoire_creation.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_messages.dart';
import '../../../utils/safe_file_name.dart';
import '../../../widgets/pgn_import_dialog.dart';

/// The normal import starts at the native picker and uses the file's name.
/// Naming and training settings do not block bringing a file into the library.
Future<RepertoireCreationResult?> showRepertoireImportDialog(
  BuildContext context, {
  required List<String> existingNames,
  Future<PickedPgnImport?> Function() pickPgn = pickPgnImport,
}) async {
  try {
    final picked = await pickPgn();
    if (!context.mounted || picked == null) return null;
    final source = picked.result;
    if (picked.error != null || source == null) {
      showAppSnackBar(
        context,
        picked.error ?? 'Could not read that file.',
        isError: true,
      );
      return null;
    }
    if (source.gameCount == 0 ||
        pgn.mainlineSansOf(source.pgnContent).isEmpty) {
      showAppSnackBar(
        context,
        'That PGN has no moves to train.',
        isError: true,
      );
      return null;
    }
    final name = _availableName(
      picked.suggestedName ??
          p.basenameWithoutExtension(source.fileName ?? 'Imported repertoire'),
      existingNames,
    );
    return await createRepertoire(
      name: name,
      color: picked.suggestedColor ?? 'White',
      pgnContent: source.pgnContent,
      gameCount: source.gameCount,
    );
  } catch (e) {
    debugPrint('Import repertoire failed: $e');
    if (context.mounted) {
      showAppSnackBar(
        context,
        'Could not import the repertoire. Please try again.',
        isError: true,
      );
    }
    return null;
  }
}

String _availableName(String suggested, List<String> existingNames) {
  var base = suggested
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  // Leave room for a duplicate suffix within the shared 120-character limit.
  if (base.length > 100) base = base.substring(0, 100);
  if (validateSafeFileName(base) != null) base = 'Imported repertoire';
  final used = existingNames.map((name) => name.toLowerCase()).toSet();
  var name = base;
  for (var suffix = 2; used.contains(name.toLowerCase()); suffix++) {
    name = '$base ($suffix)';
  }
  return name;
}

Future<RepertoireCreationResult?> showRepertoirePasteDialog(
  BuildContext context, {
  required List<String> existingNames,
}) => showDialog<RepertoireCreationResult>(
  context: context,
  builder: (_) => _RepertoirePasteDialog(existingNames: existingNames),
);

class _RepertoirePasteDialog extends StatefulWidget {
  const _RepertoirePasteDialog({required this.existingNames});

  final List<String> existingNames;

  @override
  State<_RepertoirePasteDialog> createState() => _RepertoirePasteDialogState();
}

class _RepertoirePasteDialogState extends State<_RepertoirePasteDialog> {
  final _paste = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final content = _paste.text.trim();
    final count = pgn.countPgnGames(content);
    if (count == 0 || pgn.mainlineSansOf(content).isEmpty) {
      setState(() => _error = 'Paste PGN with moves to train.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final color = await inferImportColor(content);
      if (!mounted) return;
      final created = await createRepertoire(
        name: _availableName('Pasted repertoire', widget.existingNames),
        color: color ?? 'White',
        pgnContent: content,
        gameCount: count,
      );
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      debugPrint('Paste repertoire failed: $e');
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not import. Your PGN is still here; try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Paste PGN', style: AppTextStyles.title),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Add your moves now. You can rename the repertoire later.',
              style: AppTextStyles.muted,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('repertoire-import-pgn'),
              controller: _paste,
              enabled: !_saving,
              autofocus: true,
              minLines: 6,
              maxLines: 10,
              style: AppTextStyles.mono,
              decoration: InputDecoration(
                hintText: '1. e4 e5 2. Nf3 Nc6…',
                errorText: _error,
                errorMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (!mounted) return;
                setState(() => _error = null);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _paste.text.trim().isEmpty ? null : _import,
          child: Text(_saving ? 'Importing…' : 'Import'),
        ),
      ],
    ),
  );
}
