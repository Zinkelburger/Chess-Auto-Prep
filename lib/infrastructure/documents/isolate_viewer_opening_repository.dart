import 'package:flutter/foundation.dart';
import '../../chess_core/pgn/opening_book.dart';
import '../../chess_core/pgn/pgn_opening_headers.dart';
import '../../chess_core/pgn/pgn_position_replay.dart' as pgn;
import '../../constants/engine_defaults.dart';
import '../../features/documents/repositories/viewer_computation.dart';
import '../../features/documents/repositories/viewer_opening_repository.dart';
import '../../models/pgn_filter_models.dart';
import '../../services/opening_tree_builder.dart';
import 'isolate_viewer_computation.dart';

class IsolateViewerOpeningRepository implements ViewerOpeningRepository {
  IsolateViewerOpeningRepository({required this.loadBook});
  final Future<OpeningBook> Function() loadBook;
  @override
  Future<List<OpeningBookEntry?>> classify(List<GameRecord> source) async =>
      compute(classifyMainlineOpenings, (
        book: await loadBook(),
        games: source,
      ));
  @override
  ViewerComputation<ViewerOpeningResult> buildTree(
    List<GameRecord> source, {
    required bool includeVariations,
    required void Function(int, int) onProgress,
  }) => IsolateViewerComputation((task) async {
    final tree = await OpeningTreeBuilder.buildTree(
      pgnList: [for (final game in source) game.pgnText],
      username: '',
      userIsWhite: null,
      strictPlayerMatching: false,
      includeVariations: includeVariations,
      preserveSetupRoots: true,
      maxDepth: kOpeningTreeMaxDepth,
      onProgress: onProgress,
      task: task,
    );
    final mainlineIndex = includeVariations
        ? null
        : await task.compute(pgn.buildMainlineFenIndex, source);
    return (tree: tree, mainlineIndex: mainlineIndex);
  });
}
