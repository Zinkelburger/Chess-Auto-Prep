/// "Add Chapter" prompt for the repertoire breadcrumb.
///
/// Validates inline rather than on submit — an empty or duplicate name should
/// say so under the field, not close the dialog and surface a snackbar after
/// the user has moved on.
library;

import 'package:flutter/material.dart';

/// Asks for a new chapter name. Returns the trimmed name, or null if the user
/// cancels.
///
/// [existingNames] is compared case-insensitively; pass the names already in
/// the folder.
Future<String?> showAddChapterDialog(
  BuildContext context, {
  required Iterable<String> existingNames,
}) async {
  final taken = existingNames.map((n) => n.toLowerCase()).toSet();
  return showDialog<String>(
    context: context,
    builder: (context) => _AddChapterDialog(taken: taken),
  );
}

class _AddChapterDialog extends StatefulWidget {
  const _AddChapterDialog({required this.taken});

  final Set<String> taken;

  @override
  State<_AddChapterDialog> createState() => _AddChapterDialogState();
}

class _AddChapterDialogState extends State<_AddChapterDialog> {
  // Owned here, not by the caller: `showDialog` returns as the route starts
  // its exit animation, and the field is still being rebuilt for a few frames
  // after that — disposing on the caller's side uses it after disposal.
  final TextEditingController _controller = TextEditingController();
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
    if (widget.taken.contains(value.toLowerCase())) {
      setState(() => _error = 'A chapter named "$value" exists');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Chapter'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Name this chapter (e.g. a variation or system):'),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Chapter Name',
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
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
