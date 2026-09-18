import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../features/generation/widgets/generation_recovery_dialog.dart';
import '../l10n/generated/app_localizations.dart';
import '../features/generation/services/generation_artifacts.dart';
import '../infrastructure/generation/storage_generation_artifact_repository.dart';
import '../features/documents/repositories/pgn_document_store.dart';
import '../features/generation/controllers/generation_publication_controller.dart';
import '../infrastructure/generation/storage_generation_draft_repository.dart';
import '../services/storage/storage_factory.dart';
import '../services/storage/app_paths.dart';

GenerationPublicationController createGenerationPublication({
  required PgnDocumentStore documents,
}) {
  final storage = StorageFactory.instance;
  return GenerationPublicationController(
    documents: documents,
    drafts: StorageGenerationDraftRepository(storage),
  );
}

GenerationArtifacts createGenerationArtifacts({
  required PgnDocumentStore documents,
}) {
  final storage = StorageFactory.instance;
  return GenerationArtifacts(
    StorageGenerationArtifactRepository(
      storage: storage,
      recoveryRoot: () async =>
          (await AppPaths.repertoiresDirectory(create: false)).path,
      documents: documents,
    ),
  );
}

/// Captures a chapter path for a read-only dialog; navigation cannot redirect
/// an open recovery view or its eventual export to a different chapter.
Future<void> showGenerationRecovery(
  BuildContext context, {
  String? path,
  required GenerationArtifacts artifacts,
}) => showDialog<void>(
  context: context,
  builder: (context) => GenerationRecoveryDialog(
    path: path,
    artifacts: artifacts,
    chooseExportDestination: (kind) async {
      final directory = await FilePicker.getDirectoryPath(
        dialogTitle: AppLocalizations.of(
          context,
        ).generationRecoveryExportDirectory,
      );
      if (directory == null) return null;
      return p.join(
        directory,
        '${path == null ? 'Generated' : p.basenameWithoutExtension(path)}-recovered-${kind.name}-'
        '${DateTime.now().microsecondsSinceEpoch}.${kind.extension}',
      );
    },
  ),
);
