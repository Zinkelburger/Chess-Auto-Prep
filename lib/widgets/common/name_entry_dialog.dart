/// Ask for a name, with the validation shown on the field rather than in a
/// snackbar after the dialog has already closed.
///
/// Four copies of this existed — create chapter, rename chapter, create
/// repertoire, rename repertoire — and they had drifted the way untested
/// copies do: two spelled the duplicate-name error one way and two another,
/// one used a `TextButton` for the confirm and the others a `FilledButton`,
/// and each hand-rolled the `StatefulBuilder` + error-clearing dance that is
/// the only fiddly part.
///
/// The whole shape is here so a caller writes what is actually specific to
/// it: the wording, and what counts as taken.
///
/// The dialog is a [StatefulWidget] rather than a `StatefulBuilder` over a
/// controller the caller owns, which is how the copies were written. That
/// shape disposes the [TextEditingController] as soon as `showDialog`'s
/// future completes — while the route is still running its exit animation and
/// the field is still mounted and listening. Owning the controller here means
/// it dies with the field.
library;

import 'package:flutter/material.dart';

/// Show a single-field name prompt and return the trimmed name, or null when
/// the user cancelled — or, for a rename, left the name unchanged.
///
/// The field starts focused and pre-filled with [initialValue] (selected, so
/// a rename can be typed straight over). Its error clears on the next
/// keystroke, so a rejected name does not stay marked while it is being
/// fixed.
///
/// [validate] is the caller's own rule — almost always "is this name already
/// taken" — and returns the message to show, or null to accept. Empty input
/// is rejected here, before [validate] runs, so every call site does not have
/// to remember it.
///
/// Returning null for an unchanged rename is deliberate: the caller's next
/// step is a file move, and a rename to the same name is not a no-op on every
/// filesystem. Pass [allowUnchanged] for the create case, where the initial
/// value is empty and "unchanged" has no meaning.
Future<String?> showNameEntryDialog(
  BuildContext context, {
  required String title,
  required String fieldLabel,
  required String confirmLabel,
  String? prompt,
  String initialValue = '',
  String cancelLabel = 'Cancel',
  bool allowUnchanged = false,
  String? Function(String name)? validate,
}) => showDialog<String>(
  context: context,
  builder: (_) => _NameEntryDialog(
    title: title,
    fieldLabel: fieldLabel,
    confirmLabel: confirmLabel,
    prompt: prompt,
    initialValue: initialValue,
    cancelLabel: cancelLabel,
    allowUnchanged: allowUnchanged,
    validate: validate,
  ),
);

class _NameEntryDialog extends StatefulWidget {
  const _NameEntryDialog({
    required this.title,
    required this.fieldLabel,
    required this.confirmLabel,
    required this.prompt,
    required this.initialValue,
    required this.cancelLabel,
    required this.allowUnchanged,
    required this.validate,
  });

  final String title;
  final String fieldLabel;
  final String confirmLabel;
  final String? prompt;
  final String initialValue;
  final String cancelLabel;
  final bool allowUnchanged;
  final String? Function(String name)? validate;

  @override
  State<_NameEntryDialog> createState() => _NameEntryDialogState();
}

class _NameEntryDialogState extends State<_NameEntryDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initialValue.length,
        );

  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _error = 'Please enter a name');
      return;
    }
    if (!widget.allowUnchanged && value == widget.initialValue) {
      Navigator.of(context).pop();
      return;
    }
    final problem = widget.validate?.call(value);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (prompt != null) ...[Text(prompt), const SizedBox(height: 16)],
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: widget.fieldLabel,
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
