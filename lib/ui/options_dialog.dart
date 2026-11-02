import 'package:flutter/material.dart';

import 'list_row.dart';
import 'theme.dart';

/// Asks the user to take one of a few [options], each a row that answers
/// it at once, with Cancel under them. Answers null when they back out.
///
/// For a short fixed set (a side, a promotion piece, where held moves go);
/// a long or growing list is `showChoiceDialog`, which can be searched.
Future<T?> showOptionsDialog<T extends Object>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  String? message,
}) => showDialog<T>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: dialogNarrow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null) ...[
            Text(message),
            const SizedBox(height: Space.m),
          ],
          for (final (value, label) in options)
            ListRow(
              onTap: () => Navigator.of(context).pop(value),
              child: Align(alignment: Alignment.centerLeft, child: Text(label)),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
    ],
  ),
);
