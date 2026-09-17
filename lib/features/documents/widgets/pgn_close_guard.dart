import 'package:flutter/material.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../controllers/document_close_coordinator.dart';
import '../repositories/document_save_actions.dart';
import 'document_close_scope.dart';
import 'document_save_panel.dart';

/// App-level approval for the PGN owner, including before its reader is mounted.
class PgnCloseGuard extends StatelessWidget {
  const PgnCloseGuard({
    super.key,
    required this.actions,
    required this.workspace,
    required this.revision,
    required this.flush,
    required this.chooseCopyDestination,
    required this.child,
  });
  final DocumentSaveActions actions;
  final Listenable workspace;
  final Object Function() revision;
  final Future<void> Function() flush;
  final Future<String?> Function(BuildContext) chooseCopyDestination;
  final Widget child;
  bool get resolved =>
      !actions.state.dirty &&
      !actions.state.uncertain &&
      !actions.state.busy &&
      actions.state.retainedDrafts.isEmpty;

  Future<DocumentCloseApproval?> _prepare(BuildContext context) async {
    await flush();
    if (!context.mounted) return null;
    if (resolved) return DocumentCloseApproval(revision());
    final approval = await showDialog<DocumentCloseApproval>(
      context: context,
      builder: (dialogContext) => ListenableBuilder(
        listenable: workspace,
        builder: (context, _) => AlertDialog(
          title: Text(AppLocalizations.of(context).documentCollectionSaveTitle),
          scrollable: true,
          content: SizedBox(
            width: AppSpacing.formWidth,
            child: DocumentSavePanel(
              session: actions,
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
                onPressed: actions.state.busy
                    ? null
                    : () => Navigator.pop(
                        dialogContext,
                        DocumentCloseApproval(revision()),
                      ),
                child: Text(AppLocalizations.of(context).closeWithoutSaving),
              ),
            if (resolved)
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  DocumentCloseApproval(revision()),
                ),
                child: Text(
                  AppLocalizations.of(context).closeDocumentInspection,
                ),
              ),
          ],
        ),
      ),
    );
    // Another participant can still cancel. Approval never discards the draft.
    if (approval != null) await flush();
    return approval;
  }

  @override
  Widget build(BuildContext context) => DocumentCloseRegistration(
    revision: revision,
    prepare: () => _prepare(context),
    child: child,
  );
}
