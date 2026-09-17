import '../../features/documents/repositories/stored_game_repository.dart';
import '../../services/game_store/game_store.dart';

/// Indexed adapter for the existing tactics archive. The app supplies its
/// connection owner; this reader neither creates a singleton nor closes it.
/// Retire the GameStore bridge with the training/ingestion migration (4/5).
class ArchiveStoredGameRepository implements StoredGameRepository {
  const ArchiveStoredGameRepository(this._open);

  final Future<GameStore> Function() _open;

  @override
  Future<String?> findById(String gameId) async {
    if (gameId.isEmpty) return null;
    final store = await _open();
    return store.byKey(GameCollections.tactics, gameId)?.pgn;
  }
}
