import '../../../models/pgn_filter_models.dart';
import '../repositories/viewer_computation.dart';
import '../repositories/viewer_position_index_repository.dart';

/// Owns one collection's derived position index and cancels superseded workers.
/// Persisted companions are disposable and bound to exact source records.
class PgnFenIndex {
  PgnFenIndex({
    required this.repository,
    required this.isActive,
    required this.onChanged,
  });
  final ViewerPositionIndexRepository repository;
  final bool Function() isActive;
  final void Function() onChanged;
  Map<String, List<int>>? _value;
  Map<String, List<int>>? get value => _value;
  int _generation = 0;
  ViewerComputation<Map<String, List<int>>>? _task;

  void cancel() {
    _generation++;
    _task?.cancel();
    _task = null;
  }

  void reset() {
    cancel();
    _value = null;
  }

  Future<void> tryLoadPersisted(String path, List<GameRecord> source) async {
    cancel();
    final generation = _generation;
    try {
      final index = await repository.load(path, _snapshot(source));
      if (!isActive() || generation != _generation || index == null) return;
      _value = _freeze(index);
    } catch (_) {
      // Missing, corrupt or unreadable companions are cache misses.
    }
  }

  Future<void> build(
    List<GameRecord> source, {
    required String? filePath,
  }) async {
    reset();
    final generation = _generation;
    final captured = _snapshot(source);
    final task = _task = repository.build(captured);
    try {
      final result = await task.result;
      if (!isActive() || generation != _generation) return;
      final index = _value = _freeze(result);
      onChanged();
      if (!isActive() || generation != _generation || filePath == null) return;
      try {
        await repository.save(filePath, captured, index);
      } catch (_) {
        // Cache failure never blocks the loaded document or its index.
      }
    } catch (_) {
      if (!isActive() || generation != _generation) return;
      rethrow;
    } finally {
      if (identical(task, _task)) _task = null;
    }
  }

  static List<GameRecord> _snapshot(List<GameRecord> source) =>
      List.unmodifiable([
        for (final game in source)
          (
            headers: Map<String, String>.unmodifiable(game.headers),
            pgnText: game.pgnText,
          ),
      ]);
  static Map<String, List<int>> _freeze(Map<String, List<int>> index) =>
      Map.unmodifiable({
        for (final entry in index.entries)
          entry.key: List<int>.unmodifiable(entry.value),
      });
}
