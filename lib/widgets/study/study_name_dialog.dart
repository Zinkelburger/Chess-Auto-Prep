/// Name prompt for new studies and study chapters, with the filename rules
/// a study's on-disk file has to satisfy.
library;

import 'package:flutter/material.dart';

import '../common/name_entry_dialog.dart';

/// Characters a filename cannot carry on Windows (and that no study should
/// carry anywhere, since a study *is* a file).
final RegExp _unsafeForFilename = RegExp(r'[<>:"/\\|?*]');

/// [name] with the characters a filename cannot hold collapsed to `_`.
String sanitizeStudyName(String name) => name
    .replaceAll(_unsafeForFilename, '_')
    .replaceAll(RegExp(r'_+'), '_')
    .trim();

/// Ask for a study or chapter name, returning it sanitised, or null when the
/// user cancelled.
///
/// The name-is-unusable check runs on the field rather than as a snackbar
/// after the dialog has closed, which is what it used to do: typing `///` got
/// you a dismissed dialog and an "Invalid name." message with nothing to
/// correct.
Future<String?> promptStudyName(
  BuildContext context, {
  required String title,
  String? initial,
}) async {
  final name = await showNameEntryDialog(
    context,
    title: title,
    fieldLabel: 'Name',
    confirmLabel: 'OK',
    initialValue: initial ?? '',
    allowUnchanged: true,
    validate: (value) => sanitizeStudyName(value).isEmpty
        ? 'That name has no characters a file can use.'
        : null,
  );
  return name == null ? null : sanitizeStudyName(name);
}
