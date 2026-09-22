/// Full source games referenced by a tactic's imported GameId.
/// Missing games return null; storage failures are distinct and may be retried.
abstract interface class StoredGameRepository {
  Future<String?> findById(String gameId);
}
