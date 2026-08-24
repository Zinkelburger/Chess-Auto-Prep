/// One yes/no confirmation dialog, so a destructive action's wording and
/// colour do not depend on which call site wrote the `AlertDialog`.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Ask before doing something the user cannot undo. Returns true only on an
/// explicit confirm — dismissing the dialog (tap-away, Escape) is a "no".
///
/// [destructive] paints the confirm button in the danger colour and leaves it
/// a flat text button, so the safe choice (Cancel) is the one that looks
/// pressable. Turn it off for an "are you sure?" that merely interrupts
/// something, such as ending a training session.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = true,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
        ),
        if (destructive)
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              confirmLabel,
              style: const TextStyle(color: AppColors.danger),
            ),
          )
        else
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
      ],
    ),
  );
  return confirmed ?? false;
}
