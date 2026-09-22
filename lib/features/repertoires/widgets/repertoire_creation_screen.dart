import '../../../l10n/generated/app_localizations.dart';
import 'repertoire_messages.dart';
import '../models/repertoire_creation.dart';
import 'package:flutter/material.dart';
import '../../../design_system/components/save_status.dart';

import '../../../chess_core/pgn/mainline_lexer.dart' as pgn;
import '../../../chess_core/pgn/pgn_text.dart' as pgn;
import '../../../design_system/theme/app_typography.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../widgets/pgn_import_dialog.dart';

/// Shared material creation. Returns the new files to the caller; it never
/// changes app mode or touches the builder's current document.
class RepertoireCreationScreen extends StatefulWidget {
  const RepertoireCreationScreen({
    super.key,
    required this.create,
    this.pickPgn = pickPgnImport,
  });

  final Future<RepertoireCreationResult> Function(CreateRepertoire) create;

  final Future<PickedPgnImport?> Function() pickPgn;

  @override
  State<RepertoireCreationScreen> createState() =>
      _RepertoireCreationScreenState();
}

class _RepertoireCreationScreenState extends State<RepertoireCreationScreen> {
  AppLocalizations get l10n => AppLocalizations.of(context);

  final _name = TextEditingController();
  final _pgn = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _nameFocus = FocusNode();
  bool _nameCollision = false;
  String _color = 'White';
  bool _empty = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameFocus.dispose();
    _name.dispose();
    _pgn.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _error = null;
      _nameCollision = false;
    });
    try {
      final picked = await widget.pickPgn();
      if (!mounted || picked == null) return;
      final source = picked.result;
      if (source == null) {
        setState(() => _error = l10n.fileReadFailed);
        return;
      }
      setState(() {
        _pgn.text = source.pgnContent;
        if (_name.text.trim().isEmpty) _name.text = picked.suggestedName ?? '';
        _color = picked.suggestedColor ?? _color;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = l10n.fileOpenFailed);
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
      setState(() => _error = l10n.creationNeedsMoves);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _nameCollision = false;
    });
    try {
      final name = _name.text.trim();
      final created = await widget.create(
        CreateRepertoire(
          name: name,
          color: _color,
          pgnContent: _empty ? null : content,
        ),
      );
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _nameCollision = e is RepertoireExistsException;
          _error = repertoireFailureMessage(
            l10n,
            e,
            fallback: l10n.creationFailed,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(titleSpacing: 16, title: Text(l10n.createRepertoire)),
      bottomNavigationBar: SafeArea(
        child: Align(
          heightFactor: 1,
          child: SizedBox(
            width: AppSpacing.formWidth,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    SaveStatus(
                      message: _error!,
                      tone: SaveStatusTone.error,
                      actions: [
                        if (_nameCollision)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () {
                                    _nameFocus.requestFocus();
                                    _name.selection = TextSelection(
                                      baseOffset: 0,
                                      extentOffset: _name.text.length,
                                    );
                                  },
                            child: Text(l10n.chooseAnotherName),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: 12,
                    overflowSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: Text(l10n.cancel),
                      ),
                      FilledButton(
                        onPressed: _busy ? null : _create,
                        child: Text(
                          _busy ? l10n.working : l10n.createRepertoire,
                        ),
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
          constraints: const BoxConstraints(maxWidth: AppSpacing.formWidth),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.creationHeading,
                    style: AppTypography.title(context),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    key: const ValueKey('repertoire-create-name'),
                    controller: _name,
                    focusNode: _nameFocus,
                    autofocus: true,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: l10n.repertoireName,
                      hintText: l10n.repertoireNameHint,
                      errorMaxLines: 3,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        repertoireNameProblem(l10n, value?.trim() ?? ''),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l10n.playingSide,
                    style: AppTypography.bodyStrong(context),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SegmentedButton<String>(
                    segments: [
                      ButtonSegment(value: 'White', label: Text(l10n.white)),
                      ButtonSegment(value: 'Black', label: Text(l10n.black)),
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
                    segments: [
                      ButtonSegment(
                        value: false,
                        label: Text(l10n.importPgn),
                        icon: const Icon(Icons.file_open_outlined),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text(l10n.emptyRepertoire),
                        icon: const Icon(Icons.add),
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
                              _nameCollision = false;
                            });
                          },
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  if (!_empty) ...[
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _pickFile,
                        icon: const Icon(Icons.folder_open),
                        label: Text(l10n.openPgnFile),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      key: const ValueKey('repertoire-create-pgn'),
                      controller: _pgn,
                      enabled: !_busy,
                      minLines: 7,
                      maxLines: 12,
                      style: AppTypography.mono(context),
                      decoration: InputDecoration(
                        labelText: l10n.pgnMoves,
                        hintText: l10n.pgnPasteHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ] else
                    Text(
                      l10n.emptyRepertoireHelp,
                      style: AppTypography.secondary(context),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
