import 'package:flutter/material.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../repositories/document_save_actions.dart';
import '../models/document_save_state.dart';
import 'document_save_panel.dart';

/// The caller decides whether leaving discards work. Native close only records
/// approval, since another document can still cancel the whole close attempt.
Future<({bool discard, Object revision})?> showDocumentLeaveDialog(
  BuildContext context, {
  required DocumentSaveActions session,
  required Object Function() revision,
  required Future<String?> Function(BuildContext) chooseCopyDestination,
}) => showDialog<({bool discard, Object revision})>(
  context: context,
  builder: (dialogContext) => StreamBuilder<DocumentSaveState>(
    stream: session.changes,
    initialData: session.state,
    builder: (context, snapshot) {
      final resolved = !snapshot.requireData.needsResolution;
      void leave({required bool discard}) {
        final approvedRevision = revision();
        // Capturing a revision can flush an editor's pending annotation.
        if (session.state.busy || (!discard && session.state.needsResolution)) {
          return;
        }
        Navigator.pop(dialogContext, (
          discard: discard,
          revision: approvedRevision,
        ));
      }

      return AlertDialog(
        title: Text(AppLocalizations.of(context).documentCollectionSaveTitle),
        scrollable: true,
        content: SizedBox(
          width: AppSpacing.formWidth,
          child: DocumentSavePanel(
            session: session,
            chooseCopyDestination: chooseCopyDestination,
            focusEditor: () => Navigator.pop(dialogContext),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          if (!resolved)
            TextButton(
              onPressed: session.state.busy ? null : () => leave(discard: true),
              child: Text(AppLocalizations.of(context).closeWithoutSaving),
            )
          else
            FilledButton(
              onPressed: () => leave(discard: false),
              child: Text(AppLocalizations.of(context).closeDocumentInspection),
            ),
        ],
      );
    },
  ),
);

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
