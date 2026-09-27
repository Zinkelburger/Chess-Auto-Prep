import '../../../models/pgn_filter_models.dart';
import 'viewer_computation.dart';

/// Disposable index cache keyed by exact immutable source records, never by a
/// file's later modification time. An old cache can only cause a miss.
abstract interface class ViewerPositionIndexRepository {
  Future<Map<String, List<int>>?> load(String path, List<GameRecord> source);
  ViewerComputation<Map<String, List<int>>> build(List<GameRecord> source);
  Future<void> save(
    String path,
    List<GameRecord> source,
    Map<String, List<int>> index,
  );
}
