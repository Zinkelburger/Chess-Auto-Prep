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
import '../services/engine_verification.dart';

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
        child: _EngineManagerBody(controller: controller),
      ),
    ),
  );
}

class _EngineManagerBody extends StatefulWidget {
  const _EngineManagerBody({required this.controller});

  final EngineTournamentController controller;

  @override
  State<_EngineManagerBody> createState() => _EngineManagerBodyState();
}

class _EngineManagerBodyState extends State<_EngineManagerBody> {
  bool _busy = false;

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
                itemBuilder: (context, index) => _EngineRow(
                  spec: engines[index],
                  busy: _busy,
                  onVerify: () => _verify(engines[index]),
                  onEdit: () => _edit(engines[index]),
                  onRemove: () => _remove(engines[index]),
                ),
              ),
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
    await _showVerificationResult(context, path, report);
  }

  Future<void> _verify(EngineSpec spec) async {
    setState(() => _busy = true);
    final report = await widget.controller.verifyEngine(spec);
    if (!mounted) return;
    setState(() => _busy = false);
    await _showVerificationResult(
      context,
      spec.executablePath ?? 'bundled Stockfish',
      report,
    );
  }

  Future<void> _edit(EngineSpec spec) async {
    final updated = await showDialog<EngineSpec>(
      context: context,
      builder: (_) => _EngineEditDialog(spec: spec),
    );
    if (updated == null) return;
    await widget.controller.updateEngine(updated);
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

Future<void> _showVerificationResult(
  BuildContext context,
  String path,
  EngineVerification report,
) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(
        report.ok ? Icons.check_circle_outline : Icons.error_outline,
        color: report.ok ? AppColors.success : AppColors.danger,
      ),
      title: Text(report.ok ? 'Engine verified' : 'Not a usable UCI engine'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(path, style: AppTextStyles.caption),
              const SizedBox(height: 10),
              Text(report.message, style: AppTextStyles.body),
              if (report.ok) ...[
                const SizedBox(height: 12),
                _Fact('Reports itself as', report.name),
                if (report.author.isNotEmpty) _Fact('Author', report.author),
                _Fact('UCI options', '${report.options.length}'),
                _Fact(
                  'Hash / Threads',
                  '${report.supportsHash ? "Hash" : "no Hash"}, '
                      '${report.supportsThreads ? "Threads" : "no Threads"}',
                ),
              ],
              if (!report.ok && report.transcript.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('What it said:', style: AppTextStyles.caption),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceInset,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    report.transcript.take(12).join('\n'),
                    style: AppTextStyles.caption.copyWith(
                      fontFamily: 'SourceCodePro',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: AppTextStyles.caption),
          ),
          Expanded(child: Text(value, style: AppTextStyles.body)),
        ],
      ),
    );
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
    return ListTile(
      dense: true,
      leading: Icon(
        spec.isBundled ? Icons.verified_outlined : Icons.terminal,
        color: spec.isBundled ? AppColors.success : AppColors.onSurfaceSoft,
      ),
      title: Text(spec.name, style: AppTextStyles.bodyStrong),
      subtitle: Text(
        spec.isBundled
            ? 'Bundled with the app · Hash ${spec.hashMb} MB · '
                  '${spec.threads} thread${spec.threads == 1 ? "" : "s"}'
            : '${spec.executablePath} · Hash ${spec.hashMb} MB · '
                  '${spec.threads} thread${spec.threads == 1 ? "" : "s"}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.caption,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: busy ? null : onVerify,
            child: const Text('Verify'),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune, size: 18),
            onPressed: busy ? null : onEdit,
          ),
          IconButton(
            tooltip: spec.isBundled
                ? 'The bundled engine cannot be removed'
                : 'Remove',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: busy || spec.isBundled ? null : onRemove,
          ),
        ],
      ),
    );
  }
}

class _EngineEditDialog extends StatefulWidget {
  const _EngineEditDialog({required this.spec});

  final EngineSpec spec;

  @override
  State<_EngineEditDialog> createState() => _EngineEditDialogState();
}

class _EngineEditDialogState extends State<_EngineEditDialog> {
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
    return AlertDialog(
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
                    decoration: const InputDecoration(labelText: 'Hash (MB)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _threads,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Threads'),
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
                'Permanent thinking',
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  void _save() {
    final options = <String, String>{};
    for (final line in _options.text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final split = trimmed.indexOf('=');
      if (split <= 0) continue;
      options[trimmed.substring(0, split).trim()] = trimmed
          .substring(split + 1)
          .trim();
    }
    Navigator.of(context).pop(
      widget.spec.copyWith(
        name: _name.text.trim().isEmpty ? widget.spec.name : _name.text.trim(),
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
