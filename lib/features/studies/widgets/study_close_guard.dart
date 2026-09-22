import 'package:flutter/material.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../documents/controllers/document_close_coordinator.dart';
import '../../documents/widgets/document_close_scope.dart';
import '../../documents/widgets/document_save_panel.dart';
import '../controllers/study_controller.dart';
import 'study_save_button.dart' show chooseStudyCopyDestination;

/// App-scoped because other modes can edit Study before its screen is visited.
class StudyCloseGuard extends StatelessWidget {
  const StudyCloseGuard({super.key, required this.study, required this.child});
  final StudyController study;
  final Widget child;
  bool get _resolved =>
      !study.dirty &&
      !study.state.uncertain &&
      !study.state.busy &&
      study.state.retainedDrafts.isEmpty;

  Future<DocumentCloseApproval?> _prepare(BuildContext context) async {
    await study.flushSave();
    if (!context.mounted) return null;
    if (_resolved) return DocumentCloseApproval(study.closeRevision);
    return showDialog<DocumentCloseApproval>(
      context: context,
      builder: (dialogContext) => ListenableBuilder(
        listenable: study,
        builder: (context, _) {
          final l10n = AppLocalizations.of(context);
          return AlertDialog(
            scrollable: true,
            title: Text(l10n.closeApplicationTitle),
            content: SizedBox(
              width: AppSpacing.formWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _resolved ? l10n.studyCloseReady : l10n.studyCloseUnsaved,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  DocumentSavePanel(
                    session: study,
                    chooseCopyDestination: (context) =>
                        chooseStudyCopyDestination(context, study),
                    focusEditor: () => Navigator.pop(dialogContext),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l10n.keepApplicationOpen),
              ),
              if (!_resolved)
                TextButton(
                  key: const ValueKey('study-close-discard'),
                  onPressed: study.state.busy
                      ? null
                      : () => Navigator.pop(
                          dialogContext,
                          DocumentCloseApproval(study.closeRevision),
                        ),
                  child: Text(
                    l10n.closeWithoutSaving,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_resolved)
                FilledButton(
                  key: const ValueKey('study-close-confirm'),
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    DocumentCloseApproval(study.closeRevision),
                  ),
                  child: Text(l10n.closeApplication),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DocumentCloseRegistration(
    revision: () => study.closeRevision,
    prepare: () => _prepare(context),
    child: child,
  );
}
