/// Shared name prompt for new studies and chapter rename.
library;

import 'package:flutter/material.dart';

import '../../utils/app_messages.dart';

Future<String?> promptStudyName(
  BuildContext context, {
  required String title,
  String? initial,
}) async {
  final controller = TextEditingController(text: initial ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: (value) => Navigator.pop(ctx, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  controller.dispose();
  final safe = result
      ?.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();
  if (safe == null) return null;
  if (safe.isEmpty) {
    if (context.mounted) {
      showAppSnackBar(context, 'Invalid name.', isError: true);
    }
    return null;
  }
  return safe;
}
