import '../features/studies/repositories/study_import_repository.dart';
import 'package:flutter/widgets.dart';
import '../l10n/generated/app_localizations.dart';
import '../features/studies/controllers/study_import_controller.dart';
import '../infrastructure/studies/storage_study_import_repository.dart';
import 'study_import_jobs.dart';
import '../services/jobs/repertoire_job.dart';
import '../services/lichess_auth_service.dart';
import 'package:chess_auto_prep/infrastructure/studies/study_recovery_codec.dart';
import 'package:chess_auto_prep/features/studies/models/study_workspace_snapshot.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../features/documents/repositories/workspace_recovery_store.dart';
import '../infrastructure/documents/file_workspace_recovery_store.dart';
import '../services/storage/app_paths.dart';
import '../features/documents/repositories/pgn_document_store.dart';
import '../features/studies/controllers/study_controller.dart';
import '../infrastructure/studies/legacy_study_library_repository.dart';
import '../services/storage/storage_factory.dart';

/// App-lifetime editor with explicitly injected document and library adapters.
StudyController createStudyController({required PgnDocumentStore documents}) {
  final storage = StorageFactory.instance;
  return StudyController(
    library: LegacyStudyLibraryRepository(storage, documents),
    documents: documents,
  );
}

WorkspaceRecoveryStore<StudyWorkspaceSnapshot> createStudyRecoveryStore() =>
    FileWorkspaceRecoveryStore<StudyWorkspaceSnapshot>(
      codec: const StudyRecoveryCodec(),
      directory: () async => Directory(
        p.join((await AppPaths.supportDirectory()).path, 'study-recovery-v1'),
      ),
    );

/// Downloads belong to the application and use its selected document store.
StudyImportRepository createStudyImportRepository({
  required PgnDocumentStore documents,
}) {
  final storage = StorageFactory.instance;
  return StorageStudyImportRepository(
    library: LegacyStudyLibraryRepository(storage, documents),
    documents: documents,
    cacheDirectory: () => AppPaths.chessgamesCacheDirectory(create: true),
    authHeaders: () => LichessAuthService.instance.getHeaders(),
  );
}

StudyImportController createStudyImportController({
  required PgnDocumentStore documents,
  required StudyImportRepository repository,
}) => StudyImportController(
  documents: documents,
  repository: repository,
  jobs: RepertoireStudyImportJobs(
    JobManager.instance,
    () => lookupAppLocalizations(
      basicLocaleListResolution(
        WidgetsBinding.instance.platformDispatcher.locales,
        AppLocalizations.supportedLocales,
      ),
    ),
  ),
);
