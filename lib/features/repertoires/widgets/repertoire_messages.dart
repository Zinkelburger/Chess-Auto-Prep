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
