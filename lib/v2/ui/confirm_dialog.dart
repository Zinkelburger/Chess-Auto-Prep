import 'package:flutter/material.dart';

/// Asks [message] and answers whether the user chose [confirm]. Backing out,
/// with the button or the escape key, is a no.
///
/// The confirming button is the filled one: this dialog is only ever raised
/// for something the user asked for, and the thing they asked for is the
/// action to complete.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return answer ?? false;
}
