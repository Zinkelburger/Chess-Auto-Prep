import 'package:flutter/material.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../documents/controllers/document_close_coordinator.dart';
import '../../documents/widgets/document_close_scope.dart';
import '../../documents/widgets/document_save_panel.dart';
import '../controllers/study_import_controller.dart';

/// Background imports stay owned while Study is hidden. A native close settles
/// the partial publication and asks before abandoning unacknowledged bytes.
class StudyImportCloseGuard extends StatelessWidget {
  const StudyImportCloseGuard({
    super.key,
    required this.importer,
    required this.chooseCopyDestination,
    required this.child,
  });
  final StudyImportController importer;
  final Future<String?> Function(BuildContext) chooseCopyDestination;
  final Widget child;

  Future<DocumentCloseApproval?> _prepare(BuildContext context) async {
    await importer.stop();
    if (!context.mounted) return null;
    if (!importer.needsPublicationReview) {
      return DocumentCloseApproval(importer.closeRevision);
    }
    return showDialog<DocumentCloseApproval>(
      context: context,
      builder: (dialogContext) => ListenableBuilder(
        listenable: importer,
        builder: (context, _) {
          final l10n = AppLocalizations.of(context);
          final session = importer.publicationRecovery!;
          return AlertDialog(
            scrollable: true,
            title: Text(l10n.studyImportReview),
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
                child: Text(l10n.keepApplicationOpen),
              ),
              TextButton(
                key: const ValueKey('study-import-close-confirm'),
                onPressed: session.state.busy
                    ? null
                    : () => Navigator.pop(
                        dialogContext,
                        DocumentCloseApproval(importer.closeRevision),
                      ),
                child: Text(
                  importer.needsPublicationReview
                      ? l10n.closeWithoutSaving
                      : l10n.closeApplication,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DocumentCloseRegistration(
    revision: () => importer.closeRevision,
    prepare: () => _prepare(context),
    child: child,
  );
}
