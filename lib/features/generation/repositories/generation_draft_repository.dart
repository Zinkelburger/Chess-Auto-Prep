import '../../documents/models/pgn_document.dart';
import '../models/generation_publication.dart';

/// Durable recovery output. Stage is create-only and preserves every older run,
/// including a companion PGN that the user edited after a previous generation.
abstract interface class GenerationDraftRepository {
  Future<StagedGeneration> stage(GenerationDraft draft);
  Future<void> recordPublication(StagedGeneration staged, PgnSnapshot saved);
}
