/// Add, check, and configure the UCI engines available to tournaments.
///
/// This is the *only* place the app runs a binary the user chose. Nothing
/// gets into the list without passing [verifyUciEngine] first, and the
/// failure path is the one that matters: pointing at a wrapper script, an
/// XBoard engine, or the wrong architecture has to come back as a sentence
/// saying so, not as a match that quietly produces ten forfeits.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../controllers/engine_tournament_controller.dart';
import '../models/engine_spec.dart';

Future<void> showEngineManagerDialog(
  BuildContext context,
  EngineTournamentController controller,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: EngineManagerBody(controller: controller),
      ),
    ),
  );
}

class EngineManagerBody extends StatefulWidget {
  const EngineManagerBody({
    super.key,
    required this.controller,
    this.embedded = false,
  });
  final bool embedded;

  final EngineTournamentController controller;

  @override
  State<EngineManagerBody> createState() => _EngineManagerBodyState();
}

class _EngineManagerBodyState extends State<EngineManagerBody> {
  bool _busy = false;
  EngineSpec? _editing;
  String? _report;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final engines = widget.controller.engines;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _DialogTitle(
              icon: Icons.memory,
              title: 'Engines',
              subtitle:
                  'The bundled Stockfish is what the rest of the app uses. '
                  'Anything you add here competes in tournaments only.',
            ),
            const Divider(height: 1, color: AppColors.divider),
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: engines.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: AppColors.divider),
                itemBuilder: (context, index) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _EngineRow(
                      spec: engines[index],
                      busy: _busy,
                      onVerify: () => _verify(engines[index]),
                      onEdit: () => _edit(engines[index]),
                      onRemove: () => _remove(engines[index]),
                    ),
                    if (_editing?.id == engines[index].id)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: _EngineEditDialog(
                          key: ValueKey(engines[index].id),
                          spec: engines[index],
                          onCancel: () {
                            if (mounted) setState(() => _editing = null);
                          },
                          onSave: (updated) async {
                            await widget.controller.updateEngine(updated);
                            if (mounted) setState(() => _editing = null);
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_report != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_report!, style: AppTextStyles.body),
              ),
            const Divider(height: 1, color: AppColors.divider),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _addEngine,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add UCI engine…'),
                  ),
                  const SizedBox(width: 12),
                  if (_busy)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const Spacer(),
                  if (!widget.embedded)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _addEngine() async {
    final picked = await FilePicker.pickFile(type: FileType.any);
    final path = picked?.path;
    if (path == null || !mounted) return;

    setState(() => _busy = true);
    final report = await widget.controller.addEngine(path);
    if (!mounted) return;
    setState(() => _busy = false);
    setState(
      () => _report =
          '${report.ok ? "Engine added" : "Could not add engine"}: ${report.message}',
    );
  }

  Future<void> _verify(EngineSpec spec) async {
    setState(() => _busy = true);
    final report = await widget.controller.verifyEngine(spec);
    if (!mounted) return;
    setState(() => _busy = false);
    setState(() => _report = '${spec.name}: ${report.message}');
  }

  void _edit(EngineSpec spec) {
    if (mounted) {
      setState(() => _editing = _editing?.id == spec.id ? null : spec);
    }
  }

  Future<void> _remove(EngineSpec spec) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${spec.name}?'),
        content: const Text(
          'The binary stays where it is — this only takes it off the list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.controller.removeEngine(spec.id);
  }
}

class _EngineRow extends StatelessWidget {
  const _EngineRow({
    required this.spec,
    required this.busy,
    required this.onVerify,
    required this.onEdit,
    required this.onRemove,
  });

  final EngineSpec spec;
  final bool busy;
  final VoidCallback onVerify;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(spec.name, style: AppTextStyles.bodyStrong),
          Text(
            '${spec.isBundled ? "Bundled with the app" : spec.executablePath} · ${spec.hashMb} MB · ${spec.threads} CPU ${spec.threads == 1 ? 'core' : 'cores'}',
            style: AppTextStyles.caption,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: busy ? null : onVerify,
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('Test engine'),
              ),
              TextButton.icon(
                onPressed: busy ? null : onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit'),
              ),
              if (!spec.isBundled)
                TextButton.icon(
                  onPressed: busy ? null : onRemove,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Remove'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EngineEditDialog extends StatefulWidget {
  const _EngineEditDialog({
    super.key,
    required this.spec,
    required this.onSave,
    required this.onCancel,
  });
  final Future<void> Function(EngineSpec) onSave;
  final VoidCallback onCancel;

  final EngineSpec spec;

  @override
  State<_EngineEditDialog> createState() => _EngineEditDialogState();
}

class _EngineEditDialogState extends State<_EngineEditDialog> {
  String? _error;
  bool _saving = false;
  late final TextEditingController _name = TextEditingController(
    text: widget.spec.name,
  );
  late final TextEditingController _hash = TextEditingController(
    text: '${widget.spec.hashMb}',
  );
  late final TextEditingController _threads = TextEditingController(
    text: '${widget.spec.threads}',
  );
  late bool _ponder = widget.spec.ponder;

  late final TextEditingController _options = TextEditingController(
    text: widget.spec.options.entries
        .map((e) => '${e.key}=${e.value}')
        .join('\n'),
  );

  @override
  void dispose() {
    _name.dispose();
    _hash.dispose();
    _threads.dispose();
    _options.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final form = AlertDialog(
      title: Text('${widget.spec.name} settings'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'How it appears in the crosstable and the PGN.',
              ),
            ),
            if (widget.spec.isBundled)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'The bundled engine\'s path is resolved at launch, so only '
                  'these settings are stored. They apply to tournaments only '
                  '— the rest of the app has its own Stockfish settings.',
                  style: AppTextStyles.hint,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _hash,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Memory (MB)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _threads,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'CPU cores'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const SizedBox(height: 4),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _ponder,
              onChanged: (v) => setState(() => _ponder = v ?? false),
              title: const Text(
                'Think during opponent’s turn',
                style: AppTextStyles.body,
              ),
              subtitle: const Text(
                'Let it ponder on the opponent\'s clock. Off by default: on a '
                'shared machine it mostly adds noise.',
                style: AppTextStyles.hint,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _options,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Extra UCI options',
                helperText: 'One per line, as Name=Value.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        form.content!,
        if (_error != null)
          Text(
            _error!,
            style: const TextStyle(color: AppColors.danger, fontSize: 13),
          ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: form.actions!),
      ],
    );
  }

  Future<void> _save() async {
    final memory = int.tryParse(_hash.text);
    final cores = int.tryParse(_threads.text);
    if (memory == null ||
        memory < 1 ||
        memory > 65536 ||
        cores == null ||
        cores < 1 ||
        cores > 1024) {
      setState(
        () =>
            _error = 'Enter memory from 1–65536 MB and CPU cores from 1–1024.',
      );
      return;
    }
    final options = <String, String>{};
    for (final line in _options.text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final split = trimmed.indexOf('=');
      if (split <= 0) {
        setState(() => _error = 'Enter each extra option as Name=Value.');
        return;
      }
      options[trimmed.substring(0, split).trim()] = trimmed
          .substring(split + 1)
          .trim();
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        widget.spec.copyWith(
          name: _name.text.trim().isEmpty
              ? widget.spec.name
              : _name.text.trim(),
          hashMb: (int.tryParse(_hash.text) ?? widget.spec.hashMb).clamp(
            1,
            65536,
          ),
          threads: (int.tryParse(_threads.text) ?? widget.spec.threads).clamp(
            1,
            1024,
          ),
          options: options,
          ponder: _ponder,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save engine settings. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _DialogTitle extends StatelessWidget {
  const _DialogTitle({required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.onSurfaceSoft),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.title),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: AppTextStyles.hint),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
