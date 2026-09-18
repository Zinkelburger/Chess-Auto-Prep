import 'package:flutter/material.dart';
import '../../../utils/app_messages.dart';
import '../../documents/models/pgn_document.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/safe_file_name.dart';
import '../models/repertoire_creation.dart';
import '../models/repertoire_recovery_required.dart';

/// Map domain failures at the presentation boundary. Exception diagnostics and
/// platform messages are never used as user-facing copy in migrated screens.
String repertoireFailureMessage(
  AppLocalizations messages,
  Object error, {
  required String fallback,
}) => switch (error) {
  RepertoireExistsException(:final name) => messages.repertoireExists(name),
  RepertoireCreationUncertain(:final createdPaths, :final pathsToInspect) => [
    messages.creationUncertain,
    if (createdPaths.isNotEmpty)
      messages.createdChapterPaths(createdPaths.join('\n')),
    if (pathsToInspect.isNotEmpty)
      messages.chapterPathsToInspect(pathsToInspect.join('\n')),
  ].join('\n\n'),
  RepertoirePreparationFailed() => messages.preparationFailed,
  RepertoireRecoveryRequired() => messages.recoveryRequired,
  _ => fallback,
};

String? repertoireNameProblem(AppLocalizations messages, String name) =>
    switch (fileNameProblem(name)) {
      null => null,
      FileNameProblem.empty => messages.nameRequired,
      FileNameProblem.trailingDotOrSpace => messages.nameTrailingDotOrSpace,
      FileNameProblem.reserved => messages.nameReserved,
      FileNameProblem.illegalCharacters => messages.nameIllegalCharacters,
      FileNameProblem.systemReserved => messages.nameSystemReserved,
      FileNameProblem.tooLong => messages.nameTooLong(120),
    };

/// Resolve the existing document result at the chapter UI boundary.
String chapterDeletionMessage(AppLocalizations messages, Object result) =>
    switch (result) {
      PgnReadFailed(error: UnsupportedError()) ||
      PgnQuarantineFailed(
        error: UnsupportedError(),
      ) => messages.chapterDeleteUnsupported,
      PgnMissing() => messages.chapterDeleteMissing,
      PgnReadFailed() => messages.chapterDeleteReadFailed,
      PgnQuarantined(:final retained) => messages.chapterDeleteSaved(
        retained.path,
      ),
      PgnQuarantineConflict() => messages.chapterDeleteConflict,
      PgnQuarantineUncertain(
        :final before,
        :final quarantinePath,
        :final recoveryPath,
      ) =>
        messages.chapterDeleteUncertain(
          {before.path, quarantinePath, recoveryPath}.join('\n'),
        ),
      _ => messages.chapterDeleteFailed,
    };

/// Uncertain deletion needs selectable recovery evidence, not a retry action.
Future<void> showChapterDeletionResult(
  BuildContext context,
  Object result, {
  required String chapterPath,
}) async {
  final messages = AppLocalizations.of(context);
  final message = messages.chapterDeleteContext(
    chapterPath,
    chapterDeletionMessage(messages, result),
  );
  if (result is PgnQuarantineUncertain) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(messages.chapterDeleteReview),
        content: SelectableText(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(messages.closeDocumentInspection),
          ),
        ],
      ),
    );
  } else {
    showAppSnackBar(
      context,
      message,
      isError: result is! PgnQuarantined,
      requiresAttention: true,
    );
  }
}
