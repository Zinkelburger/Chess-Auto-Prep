import 'dart:convert';

import 'package:path/path.dart' as p;

import 'generation_namespace.dart';

import '../../features/documents/models/pgn_document.dart';
import '../../features/generation/models/generation_publication.dart';
import '../../features/generation/repositories/generation_draft_repository.dart';
import '../../services/storage/storage_service.dart';

/// One immutable output directory per run. The manifest is staged first, so
/// interruptions while writing either PGN still leave identifiable recovery
/// evidence. Source publication is permitted only after all staging completes.
class StorageGenerationDraftRepository implements GenerationDraftRepository {
  StorageGenerationDraftRepository(
    this.storage, {
    Future<void> Function(String)? prepareDirectory,
  }) : _prepareDirectory = prepareDirectory ?? prepareGenerationDirectory;
  final StorageService storage;
  final Future<void> Function(String) _prepareDirectory;

  static const directoryName = '.cap-generation';

  @override
  Future<StagedGeneration> stage(GenerationDraft draft) async {
    final source = draft.source;
    final dir = p.join(
      p.dirname(source.path),
      directoryName,
      p.basename(source.path),
      source.runId,
    );
    final manifest = p.join(dir, 'manifest.json');
    final modelPath = draft.modelGames == null
        ? null
        : p.join(dir, 'model_games.pgn');
    try {
      await _prepareDirectory(dir);
      await storage.writeFile(
        manifest,
        jsonEncode({
          'version': 1,
          'runId': source.runId,
          'state': 'proposal',
          'source': source.path,
          'baseline': _revision(source.snapshot),
          'config': source.config,
          'course': 'course.pgn',
          if (modelPath != null) 'modelGames': 'model_games.pgn',
        }),
        createOnly: true,
      );
      await storage.writeFile(
        p.join(dir, 'course.pgn'),
        draft.content,
        createOnly: true,
      );
      if (modelPath != null) {
        await storage.writeFile(modelPath, draft.modelGames!, createOnly: true);
      }
      return StagedGeneration(
        manifestPath: manifest,
        modelGamesPath: modelPath,
      );
    } catch (error) {
      throw GenerationStagingFailed(manifest, error);
    }
  }

  @override
  Future<void> recordPublication(StagedGeneration staged, PgnSnapshot saved) =>
      storage.writeFile(
        p.join(p.dirname(staged.manifestPath), 'published.json'),
        jsonEncode({'state': 'published', 'revision': _revision(saved)}),
        createOnly: true,
      );

  static Map<String, String>? _revision(PgnSnapshot? snapshot) =>
      snapshot == null
      ? null
      : {
          'documentId': snapshot.revision.documentId,
          'nativeIdentity': snapshot.revision.nativeIdentity,
          'sha256': snapshot.revision.sha256,
        };
}
