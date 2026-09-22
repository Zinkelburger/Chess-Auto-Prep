import '../../../models/pgn_filter_models.dart';

abstract interface class PgnCollectionFilter {
  Future<List<int>> match(
    SliceConfig config,
    List<GameRecord> games, {
    Map<String, List<int>>? fenIndex,
  });
}
