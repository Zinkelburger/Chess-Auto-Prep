import 'package:flutter/material.dart';
import '../../../design_system/components/name_entry_dialog.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../documents/widgets/document_save_dialog.dart';
import '../controllers/study_controller.dart';
import 'study_selector.dart';

/// Save/recovery is reachable even for a never-saved study or a dismissed error.
class StudySaveButton extends StatelessWidget {
  const StudySaveButton({super.key, required this.study});
  final StudyController study;
  @override
  Widget build(BuildContext context) => StudySelector<bool>(
    study: study,
    select: (owner) => owner.state.outcome != null,
    builder: (context, warning) {
      final l10n = AppLocalizations.of(context);
      return TextButton.icon(
        key: const ValueKey('study-save-recovery'),
        icon: Icon(warning ? Icons.warning_amber : Icons.save_outlined),
        label: Text(l10n.studySaveRecovery),
        onPressed: () => showDocumentSaveDialog(
          context,
          title: l10n.studySaveDialogTitle(study.title.name),
          session: study,
          chooseCopyDestination: (context) =>
              chooseStudyCopyDestination(context, study),
        ),
      );
    },
  );
}

Future<String?> chooseStudyCopyDestination(
  BuildContext context,
  StudyController study,
) async {
  final l10n = AppLocalizations.of(context);
  final name = await showNameEntryDialog(
    context,
    title: l10n.saveCopy,
    fieldLabel: l10n.studyCopyName,
    prompt: l10n.studyCopyPrompt,
    initialValue: l10n.studyCopyInitial(study.title.name),
    allowUnchanged: true,
    confirmLabel: l10n.saveCopy,
    cancelLabel: l10n.cancel,
  );
  return name == null ? null : study.copyDestination(name);
}
