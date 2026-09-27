import '../../../l10n/generated/app_localizations.dart';
import 'repertoire_messages.dart';
import '../models/repertoire_creation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../chess_core/pgn/mainline_lexer.dart' as pgn;
import '../../../chess_core/pgn/pgn_text.dart' as pgn;
import '../../../design_system/theme/app_typography.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../utils/app_messages.dart';
import '../../../utils/safe_file_name.dart';
import '../../../widgets/pgn_import_dialog.dart';

/// The normal import starts at the native picker and uses the file's name.
/// Naming and training settings do not block bringing a file into the library.
Future<RepertoireCreationResult?> showRepertoireImportDialog(
  BuildContext context, {
  required List<String> existingNames,
  required Future<RepertoireCreationResult> Function(CreateRepertoire) create,
  Future<PickedPgnImport?> Function() pickPgn = pickPgnImport,
}) async {
  final l10n = AppLocalizations.of(context);
  try {
    final picked = await pickPgn();
    if (!context.mounted || picked == null) return null;
    final source = picked.result;
    if (picked.error != null || source == null) {
      showAppSnackBar(context, l10n.fileReadFailed, isError: true);
      return null;
    }
    if (source.gameCount == 0 ||
        pgn.mainlineSansOf(source.pgnContent).isEmpty) {
      showAppSnackBar(context, l10n.importNeedsMoves, isError: true);
      return null;
    }
    final name = _availableName(
      picked.suggestedName ??
          p.basenameWithoutExtension(source.fileName ?? 'Imported repertoire'),
      existingNames,
    );
    return await create(
      CreateRepertoire(
        name: name,
        color: picked.suggestedColor ?? 'White',
        pgnContent: source.pgnContent,
        gameCount: source.gameCount,
      ),
    );
  } catch (e) {
    debugPrint('Import repertoire failed: $e');
    if (context.mounted) {
      showAppSnackBar(
        context,
        repertoireFailureMessage(l10n, e, fallback: l10n.importFailed),
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
  required Future<RepertoireCreationResult> Function(CreateRepertoire) create,
}) => showDialog<RepertoireCreationResult>(
  context: context,
  builder: (_) =>
      _RepertoirePasteDialog(existingNames: existingNames, create: create),
);

class _RepertoirePasteDialog extends StatefulWidget {
  const _RepertoirePasteDialog({
    required this.existingNames,
    required this.create,
  });

  final Future<RepertoireCreationResult> Function(CreateRepertoire) create;

  final List<String> existingNames;

  @override
  State<_RepertoirePasteDialog> createState() => _RepertoirePasteDialogState();
}

class _RepertoirePasteDialogState extends State<_RepertoirePasteDialog> {
  AppLocalizations get l10n => AppLocalizations.of(context);

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
      setState(() => _error = l10n.pasteNeedsMoves);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final color = await inferImportColor(content);
      if (!mounted) return;
      final created = await widget.create(
        CreateRepertoire(
          name: _availableName('Pasted repertoire', widget.existingNames),
          color: color ?? 'White',
          pgnContent: content,
          gameCount: count,
        ),
      );
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      debugPrint('Paste repertoire failed: $e');
      if (mounted) {
        setState(() {
          _saving = false;
          _error = repertoireFailureMessage(
            l10n,
            e,
            fallback: l10n.pasteFailed,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(l10n.pastePgn, style: AppTypography.title(context)),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.pasteHelp, style: AppTypography.secondary(context)),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              key: const ValueKey('repertoire-import-pgn'),
              controller: _paste,
              enabled: !_saving,
              autofocus: true,
              minLines: 6,
              maxLines: 10,
              style: AppTypography.mono(context),
              decoration: InputDecoration(
                hintText: l10n.pgnExample,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (!mounted) return;
                setState(() => _error = null);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _saving || _paste.text.trim().isEmpty ? null : _import,
          child: Text(_saving ? l10n.importing : l10n.importAction),
        ),
      ],
    ),
  );
}
