import 'package:flutter/material.dart';

import 'theme.dart';

/// Asks [title] (a question, naming the thing in curly quotes:
/// `Delete chapter “Najdorf”?`) and answers whether the user chose
/// [confirm]. Backing out, with the button or the escape key, is a no.
///
/// The confirming button is the filled one: this dialog is only ever raised
/// for something the user asked for, and the thing they asked for is the
/// action to complete. A [destructive] one (the default: delete, remove,
/// clear, replace, discard) starts with Cancel focused, so Enter and
/// Escape both keep everything; one that only adds starts on the confirm.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool destructive = true,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: dialogNarrow, child: Text(message)),
      actions: [
        TextButton(
          autofocus: destructive,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          autofocus: !destructive,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return answer ?? false;
}
