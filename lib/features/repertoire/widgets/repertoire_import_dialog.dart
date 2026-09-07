import 'package:flutter/material.dart';

import '../../../services/pgn_parsing_service.dart' as pgn;
import '../../../services/repertoire_creation.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/safe_file_name.dart';
import '../../../widgets/pgn_import_dialog.dart';

Future<RepertoireCreationResult?> showRepertoireImportDialog(
  BuildContext context, {
  required List<String> existingNames,
  Future<PickedPgnImport?> Function() pickPgn = pickPgnImport,
}) => showDialog<RepertoireCreationResult>(
  context: context,
  builder: (_) =>
      _RepertoireImportDialog(existingNames: existingNames, pickPgn: pickPgn),
);

class _RepertoireImportDialog extends StatefulWidget {
  const _RepertoireImportDialog({
    required this.existingNames,
    required this.pickPgn,
  });

  final List<String> existingNames;
  final Future<PickedPgnImport?> Function() pickPgn;

  @override
  State<_RepertoireImportDialog> createState() =>
      _RepertoireImportDialogState();
}

class _RepertoireImportDialogState extends State<_RepertoireImportDialog> {
  final _name = TextEditingController();
  final _paste = TextEditingController();
  PgnImportResult? _file;
  String _color = 'White';
  bool _colorChosen = false;
  bool _pasting = false;
  bool _reading = false;
  bool _saving = false;
  String? _nameError;
  String? _sourceError;
  String? _saveError;

  bool get _busy => _reading || _saving;
  String get _content =>
      _pasting ? _paste.text.trim() : _file?.pgnContent ?? '';
  int get _count =>
      _pasting ? pgn.countPgnGames(_content) : _file?.gameCount ?? 0;

  @override
  void dispose() {
    _name.dispose();
    _paste.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _reading = true;
      _sourceError = null;
      _saveError = null;
    });
    try {
      final picked = await widget.pickPgn();
      if (!mounted || picked == null) return;
      setState(() {
        _sourceError = picked.error;
        if (picked.result != null) {
          _file = picked.result;
          _pasting = false;
          if (_name.text.trim().isEmpty) {
            _name.text = picked.suggestedName ?? '';
            _nameError = null;
          }
          if (!_colorChosen && picked.suggestedColor != null) {
            _color = picked.suggestedColor!;
          }
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _sourceError = 'Could not read that file. Try again.');
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _import() async {
    final name = _name.text.trim();
    final nameError =
        validateSafeFileName(name) ??
        (widget.existingNames.any((n) => n.toLowerCase() == name.toLowerCase())
            ? 'A repertoire named "$name" already exists.'
            : null);
    // A header or a comment alone cannot be trained.
    final sourceError = _count == 0 || pgn.mainlineSansOf(_content).isEmpty
        ? 'Choose a PGN file or paste PGN with moves to train.'
        : null;
    setState(() {
      _nameError = nameError;
      _sourceError = sourceError;
      _saveError = null;
    });
    if (nameError != null || sourceError != null) return;

    setState(() => _saving = true);
    try {
      final created = await createRepertoire(
        name: name,
        color: _color,
        pgnContent: _content,
        gameCount: _count,
      );
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      debugPrint('Import repertoire failed: $e');
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError =
              'Could not import the repertoire. Your PGN is still here; try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Import repertoire'),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('repertoire-import-name'),
                controller: _name,
                enabled: !_busy,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Caro-Kann',
                  errorText: _nameError,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {
                  _nameError = null;
                  _saveError = null;
                }),
              ),
              const SizedBox(height: 20),
              const Text('PGN file', style: AppTextStyles.bodyStrong),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickFile,
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.all(16),
                  side: BorderSide(color: cs.primary),
                  foregroundColor: cs.onSurface,
                ),
                icon: _reading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.folder_open, color: cs.primary),
                label: Text(
                  _reading
                      ? 'Reading PGN…'
                      : !_pasting && _file != null
                      ? _file!.fileName ?? 'Change PGN file…'
                      : 'Choose file…',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _pasting = !_pasting;
                          _sourceError = null;
                          _saveError = null;
                        }),
                  child: Text(
                    _pasting ? 'Use a file instead' : 'Paste PGN instead',
                  ),
                ),
              ),
              if (_pasting)
                TextField(
                  key: const ValueKey('repertoire-import-pgn'),
                  controller: _paste,
                  enabled: !_busy,
                  minLines: 4,
                  maxLines: 6,
                  style: AppTextStyles.mono,
                  decoration: const InputDecoration(
                    labelText: 'PGN',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {
                    _sourceError = null;
                    _saveError = null;
                  }),
                ),
              if (_sourceError != null)
                Text(
                  _sourceError!,
                  style: AppTextStyles.body.copyWith(color: cs.error),
                )
              else if (_count > 0)
                Text(
                  '${_count == 1 ? '1 game' : '$_count games'} ready to import',
                  style: AppTextStyles.muted,
                ),
              const SizedBox(height: 20),
              const Text('Train as', style: AppTextStyles.bodyStrong),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'White',
                    label: Text('White'),
                    icon: Icon(Icons.circle_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: 'Black',
                    label: Text('Black'),
                    icon: Icon(Icons.circle, size: 16),
                  ),
                ],
                selected: {_color},
                onSelectionChanged: _busy
                    ? null
                    : (selection) => setState(() {
                        _color = selection.first;
                        _colorChosen = true;
                      }),
              ),
              if (_saveError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _saveError!,
                  style: AppTextStyles.body.copyWith(color: cs.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _busy || _content.isEmpty ? null : _import,
            child: Text(_saving ? 'Importing…' : 'Import'),
          ),
        ],
      ),
    );
  }
}
