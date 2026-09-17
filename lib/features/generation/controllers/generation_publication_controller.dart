import 'dart:math';

import '../../documents/models/pgn_document.dart';
import '../../documents/repositories/pgn_document_store.dart';
import '../models/generation_publication.dart';
import '../repositories/generation_draft_repository.dart';

/// Creates an independent publication owner for each generation session.
typedef GenerationPublicationFactory =
    GenerationPublicationController Function();

/// Owns one run's publication capability from source capture through commit.
/// Cancellation invalidates that capability; an already-started atomic commit
/// is reconciled by its typed result, never blindly retried.
class GenerationPublicationController {
  GenerationPublicationController({
    required PgnDocumentStore documents,
    required GenerationDraftRepository drafts,
  }) : _documents = documents,
       _drafts = drafts;

  final PgnDocumentStore _documents;
  final GenerationDraftRepository _drafts;
  String? _activeId;
  GenerationSource? _activeSource;
  bool _publishing = false;

  Future<GenerationSource> begin(
    String path,
    Map<String, dynamic> config,
  ) async {
    if (_activeId != null || _publishing) {
      throw StateError('A generation already owns publication');
    }
    final random = Random.secure();
    final id =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-'
        '${random.nextInt(1 << 32).toRadixString(16)}-'
        '${random.nextInt(1 << 32).toRadixString(16)}';
    _activeId = id;
    final capturedConfig = GenerationSource.snapshotConfig(config);
    try {
      final opened = await _documents.open(path);
      if (_activeId != id) throw StateError('Generation was cancelled');
      return _activeSource = GenerationSource(
        runId: id,
        path: path,
        snapshot: switch (opened) {
          PgnOpened(:final snapshot) => snapshot,
          PgnMissing() => null,
          PgnReadFailed(:final error) => throw error,
        },
        config: capturedConfig,
      );
    } catch (_) {
      if (_activeId == id) _activeId = null;
      rethrow;
    }
  }

  void cancel() {
    _activeId = null;
    _activeSource = null;
  }

  void finish(GenerationSource source) {
    if (identical(_activeSource, source)) cancel();
  }

  Future<GenerationPublicationResult> publish(
    GenerationSource source, {
    required Iterable<String> games,
    String? modelGames,
  }) async {
    if (!identical(_activeSource, source) ||
        _activeId != source.runId ||
        _publishing) {
      throw StateError('Generation no longer owns publication');
    }
    _publishing = true;
    try {
      final content = StringBuffer(source.snapshot?.content ?? '');
      for (final game in games) {
        content.writeln();
        content.write(game);
      }
      final draft = GenerationDraft(
        source: source,
        content: content.toString(),
        modelGames: modelGames,
      );
      // The complete proposal and companion survive conflicts, interrupted
      // commits, cancellation during staging, and uncertain native outcomes.
      final staged = await _drafts.stage(draft);
      if (_activeId != source.runId) {
        return GenerationPublicationRefused(staged, 'Generation was cancelled');
      }
      final baseline = source.snapshot;
      final PgnWriteResult write;
      if (baseline != null && draft.content == baseline.content) {
        // A run with no new lines must not silently replace the document's
        // native identity and invalidate its editor's unchanged baseline.
        final current = await _documents.open(source.path);
        write = switch (current) {
          PgnOpened(:final snapshot)
              when snapshot.revision == baseline.revision =>
            PgnSaved(before: baseline, after: snapshot),
          PgnOpened(:final snapshot) => PgnConflict(snapshot),
          PgnMissing() => const PgnConflict(null),
          PgnReadFailed(:final error) => PgnWriteFailed(error),
        };
      } else {
        write = baseline == null
            ? await _documents.create(source.path, draft.content)
            : await _documents.save(baseline, draft.content);
      }
      switch (write) {
        case PgnSaved(:final after):
          try {
            await _drafts.recordPublication(staged, after);
            return GenerationPublished(staged, after);
          } catch (error) {
            return GenerationPublished(staged, after, receiptError: error);
          }
        case PgnWriteUncertain():
          return GenerationPublicationUncertain(staged, write);
        case PgnConflict():
        case PgnNameCollision():
          return GenerationPublicationRefused(staged, 'The source PGN changed');
        case PgnWriteFailed(:final error):
          return GenerationPublicationRefused(staged, error);
      }
    } finally {
      // A publication is single-use even when its result is uncertain.
      finish(source);
      _publishing = false;
    }
  }
}
