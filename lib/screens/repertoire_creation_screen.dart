import 'package:flutter/material.dart';

import '../services/pgn_parsing_service.dart' as pgn;
import '../services/repertoire_creation.dart';
import '../services/storage/storage_factory.dart';
import '../theme/app_text_styles.dart';
import '../utils/safe_file_name.dart';
import '../widgets/pgn_import_dialog.dart';

/// Shared material creation. Returns the new files to the caller; it never
/// changes app mode or touches the builder's current document.
class RepertoireCreationScreen extends StatefulWidget {
  const RepertoireCreationScreen({super.key, this.pickPgn = pickPgnImport});

  final Future<PickedPgnImport?> Function() pickPgn;

  @override
  State<RepertoireCreationScreen> createState() =>
      _RepertoireCreationScreenState();
}

class _RepertoireCreationScreenState extends State<RepertoireCreationScreen> {
  final _name = TextEditingController();
  final _pgn = TextEditingController();
  final _form = GlobalKey<FormState>();
  String _color = 'White';
  bool _empty = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _pgn.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picked = await widget.pickPgn();
      if (!mounted || picked == null) return;
      final source = picked.result;
      if (source == null) {
        setState(() => _error = picked.error ?? 'Could not read that file.');
        return;
      }
      setState(() {
        _pgn.text = source.pgnContent;
        if (_name.text.trim().isEmpty) _name.text = picked.suggestedName ?? '';
        _color = picked.suggestedColor ?? _color;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not open that file. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (_busy || !_form.currentState!.validate()) return;
    final content = _pgn.text.trim();
    if (!_empty &&
        (pgn.countPgnGames(content) == 0 ||
            pgn.mainlineSansOf(content).isEmpty)) {
      setState(() => _error = 'Open or paste a PGN with moves to train.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = _name.text.trim();
      final existing = await StorageFactory.instance.listRepertoires();
      if (existing.any((r) => r.name.toLowerCase() == name.toLowerCase())) {
        throw RepertoireExistsException(name);
      }
      final created = await createRepertoire(
        name: name,
        color: _color,
        pgnContent: _empty ? null : content,
      );
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is RepertoireExistsException
              ? e.toString()
              : 'Could not create the repertoire. Your input is still here; try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(titleSpacing: 16, title: const Text('Create repertoire')),
      bottomNavigationBar: SafeArea(
        child: Align(
          heightFactor: 1,
          child: SizedBox(
            width: 680,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _busy ? null : _create,
                        child: Text(_busy ? 'Working…' : 'Create repertoire'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Bring your lines. Start training.',
                    style: AppTextStyles.title,
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    key: const ValueKey('repertoire-create-name'),
                    controller: _name,
                    autofocus: true,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Repertoire name',
                      hintText: 'My Sicilian',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        validateSafeFileName(value?.trim() ?? ''),
                  ),
                  const SizedBox(height: 20),
                  const Text('Playing side', style: AppTextStyles.bodyStrong),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'White', label: Text('White')),
                      ButtonSegment(value: 'Black', label: Text('Black')),
                    ],
                    selected: {_color},
                    onSelectionChanged: _busy
                        ? null
                        : (value) {
                            if (!mounted) return;
                            setState(() => _color = value.single);
                          },
                  ),
                  const SizedBox(height: 20),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('Import PGN'),
                        icon: Icon(Icons.file_open_outlined),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text('Empty repertoire'),
                        icon: Icon(Icons.add),
                      ),
                    ],
                    selected: {_empty},
                    onSelectionChanged: _busy
                        ? null
                        : (value) {
                            if (!mounted) return;
                            setState(() {
                              _empty = value.single;
                              _error = null;
                            });
                          },
                  ),
                  const SizedBox(height: 16),
                  if (!_empty) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _pickFile,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open PGN file…'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('repertoire-create-pgn'),
                      controller: _pgn,
                      enabled: !_busy,
                      minLines: 7,
                      maxLines: 12,
                      style: AppTextStyles.mono,
                      decoration: const InputDecoration(
                        labelText: 'PGN moves',
                        hintText: 'Paste your PGN here',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ] else
                    const Text(
                      'Create a place for chapters and lines. Add moves before training.',
                      style: AppTextStyles.muted,
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
