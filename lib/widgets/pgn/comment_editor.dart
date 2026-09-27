/// Inline PGN comment editor shared by every movetext surface.
///
/// The PGN viewer ([PgnMovetextView]) and the repertoire builder / study
/// editor ([InteractivePgnEditor]) both render this widget in the move flow
/// when a comment is being edited, so commenting looks and behaves the same
/// everywhere: a rounded field with save (✓) and cancel (✕), Enter to save.
library;

import 'package:flutter/material.dart';
import '../../design_system/theme/app_typography.dart';
import '../../l10n/generated/app_localizations.dart';

import '../../design_system/components/confirm_dialog.dart';

class PgnCommentEditor extends StatefulWidget {
  final String initialText;
  final ValueChanged<String> onSave;
  final VoidCallback onCancel;

  /// Optional draft owner for hosts that virtualize or re-anchor this row.
  final ValueChanged<String>? onChanged;

  const PgnCommentEditor({
    super.key,
    required this.initialText,
    required this.onSave,
    required this.onCancel,
    this.onChanged,
  });

  @override
  State<PgnCommentEditor> createState() => _PgnCommentEditorState();
}

class _PgnCommentEditorState extends State<PgnCommentEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _confirming = false;

  Future<void> _save() async {
    if (_confirming) return;
    final text = _controller.text;
    if (text.trim().isEmpty && widget.initialText.trim().isNotEmpty) {
      _confirming = true;
      final confirmed = await confirmAction(
        context,
        title: AppLocalizations.of(context).pgnDeleteOneComment,
        confirmLabel: AppLocalizations.of(context).delete,
      );
      _confirming = false;
      if (!mounted || !confirmed || _controller.text != text) return;
    }
    if (!mounted) return;
    widget.onSave(text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              maxLines: null,
              style: AppTypography.secondary(
                context,
              ).copyWith(color: colors.onSurface),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                border: InputBorder.none,
              ),
              onChanged: widget.onChanged,
              onSubmitted: (_) => _save(),
            ),
          ),
          IconButton(
            onPressed: _save,
            icon: Icon(Icons.check, size: 18, color: colors.onSurfaceVariant),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            tooltip: AppLocalizations.of(context).pgnSaveComment,
          ),
          IconButton(
            onPressed: widget.onCancel,
            icon: Icon(Icons.close, size: 18, color: colors.onSurfaceVariant),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            tooltip: AppLocalizations.of(context).cancel,
          ),
        ],
      ),
    );
  }
}
