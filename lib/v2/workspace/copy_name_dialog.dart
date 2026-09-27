import 'package:flutter/material.dart';

import 'session_results.dart';

/// What a Save a copy came to, in the words every place that offers one
/// (the edit strip, the Actions menu, the question on the way out) shows.
String copySaid(CopyResult result) => switch (result) {
  CopySaved(:final name, nowEditing: true) =>
    'Saved a copy as $name. Now editing the copy.',
  CopySaved(:final name) => 'Saved a copy as $name',
  CopyNameTaken() => 'That name is taken. Nothing was replaced.',
  CopyFailed(:final detail) => 'Could not save a copy: $detail',
};

/// Asks what to call the copy. Returns null when the user backs out.
Future<String?> showCopyNameDialog(BuildContext context, String suggestion) =>
    showDialog<String>(
      context: context,
      builder: (context) => _CopyNameDialog(suggestion: suggestion),
    );

class _CopyNameDialog extends StatefulWidget {
  const _CopyNameDialog({required this.suggestion});

  final String suggestion;

  @override
  State<_CopyNameDialog> createState() => _CopyNameDialogState();
}

class _CopyNameDialogState extends State<_CopyNameDialog> {
  late final _controller = TextEditingController(
    text: '${widget.suggestion} copy',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save a copy'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: 'File name',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save a copy')),
      ],
    );
  }
}
