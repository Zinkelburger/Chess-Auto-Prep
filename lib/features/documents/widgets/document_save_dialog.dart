import 'package:flutter/material.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../repositories/document_save_actions.dart';
import 'document_save_panel.dart';

Future<void> showDocumentSaveDialog(
  BuildContext context, {
  required String title,
  required DocumentSaveActions session,
  required Future<String?> Function(BuildContext) chooseCopyDestination,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    scrollable: true,
    title: Text(title),
    content: SizedBox(
      width: AppSpacing.formWidth,
      child: DocumentSavePanel(
        session: session,
        chooseCopyDestination: chooseCopyDestination,
        focusEditor: () => Navigator.of(dialogContext).pop(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: Text(AppLocalizations.of(dialogContext).closeDocumentInspection),
      ),
    ],
  ),
);
