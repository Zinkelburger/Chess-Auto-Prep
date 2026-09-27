import '../../../chess_core/pgn/opening_book.dart';
import '../../../models/opening_tree.dart';
import '../../../models/pgn_filter_models.dart';
import 'viewer_computation.dart';

typedef ViewerOpeningResult = ({
  OpeningTree tree,
  Map<String, List<int>>? mainlineIndex,
});

abstract interface class ViewerOpeningRepository {
  Future<List<OpeningBookEntry?>> classify(List<GameRecord> source);
  ViewerComputation<ViewerOpeningResult> buildTree(
    List<GameRecord> source, {
    required bool includeVariations,
    required void Function(int processed, int total) onProgress,
  });
}
