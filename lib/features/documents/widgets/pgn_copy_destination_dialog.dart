import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../../design_system/theme/app_spacing.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Selects a destination only. Exclusive creation belongs to the save owner.
Future<String?> showPgnCopyDestinationDialog(
  BuildContext context, {
  required String initialDirectory,
  required String initialName,
  required Future<String?> Function(String currentDirectory) pickDirectory,
}) => showDialog<String>(
  context: context,
  builder: (_) => _DestinationDialog(
    initialDirectory: initialDirectory,
    initialName: initialName,
    pickDirectory: pickDirectory,
  ),
);

class _DestinationDialog extends StatefulWidget {
  const _DestinationDialog({
    required this.initialDirectory,
    required this.initialName,
    required this.pickDirectory,
  });
  final String initialDirectory;
  final String initialName;
  final Future<String?> Function(String) pickDirectory;
  @override
  State<_DestinationDialog> createState() => _DestinationDialogState();
}

class _DestinationDialogState extends State<_DestinationDialog> {
  late final _directory = TextEditingController(text: widget.initialDirectory);
  late final _name = TextEditingController(text: widget.initialName)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialName.length,
    );
  final _form = GlobalKey<FormState>();
  bool _picking = false;
  bool _pickFailed = false;
  @override
  void dispose() {
    _directory.dispose();
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_picking || !_form.currentState!.validate()) return;
    final name = _name.text.trim();
    Navigator.pop(
      context,
      p.join(
        _directory.text.trim(),
        p.extension(name).toLowerCase() == '.pgn' ? name : '$name.pgn',
      ),
    );
  }

  Future<void> _browse() async {
    setState(() {
      _picking = true;
      _pickFailed = false;
    });
    try {
      final selected = await widget.pickDirectory(_directory.text.trim());
      if (!mounted) return;
      if (selected != null) _directory.text = selected;
    } catch (_) {
      if (mounted) setState(() => _pickFailed = true);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.saveCopy),
      scrollable: true,
      content: SizedBox(
        width: AppSpacing.formWidth,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.documentCopyPrompt),
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                key: const ValueKey('pgn-copy-name'),
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(labelText: l10n.documentCopyName),
                validator: (value) {
                  final name = value?.trim() ?? '';
                  return name.isEmpty ||
                          name == '.' ||
                          name == '..' ||
                          name.contains(RegExp(r'[/\\\x00]'))
                      ? l10n.documentCopyInvalidName
                      : null;
                },
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                key: const ValueKey('pgn-copy-directory'),
                controller: _directory,
                decoration: InputDecoration(
                  labelText: l10n.documentCopyFolder,
                  suffixIcon: IconButton(
                    tooltip: l10n.documentBrowseFolder,
                    onPressed: _picking ? null : _browse,
                    icon: const Icon(Icons.folder_open),
                  ),
                ),
                validator: (value) =>
                    value == null || !p.isAbsolute(value.trim())
                    ? l10n.documentCopyInvalidFolder
                    : null,
              ),
              if (_pickFailed)
                Text(
                  l10n.documentFolderPickerFailed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _picking ? null : () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('pgn-copy-confirm'),
          onPressed: _picking ? null : _submit,
          child: Text(l10n.saveCopy),
        ),
      ],
    );
  }
}
