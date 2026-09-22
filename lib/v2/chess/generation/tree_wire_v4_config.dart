/// What a saved tree's configuration snapshot says: whether this search can
/// read the document at all, and the settings it was built with.
///
/// The snapshot is a flat map of some seventy keys, most of them belonging to
/// modes this search does not have. Reading it is its own job, and a separate
/// one from rebuilding the tree: it decides, before a single node is read,
/// whether the file in hand is a tree this search could have built.
library;

import 'package:dartchess/dartchess.dart' show Side;

import 'search_config.dart';
import 'tree_wire_v4.dart';

/// Why this search cannot read the tree, or null when it can.
String? unsupportedTreeReason(
  Object? version,
  Map<String, Object?> config,
  Map<String, Object?> tree,
) {
  if (version is! num || version.toInt() != treeWireVersion) {
    return 'this tree was saved in format version ${version ?? 'unknown'}, '
        'and only version $treeWireVersion can be read';
  }
  // The flag on the root is what tells the two searches apart, and it is what
  // the old app itself checks before resuming a build; the version number
  // beside it is a label that some writers leave off.
  final algorithm = config['algorithm_version'];
  if (tree['history_aware'] != true ||
      (algorithm != null && algorithm != pureAlgorithmVersion)) {
    return 'this tree was built by the older heuristic search, which valued '
        'positions differently and shared values between paths; build it '
        'again to open it here';
  }
  final search = config['search_algorithm'];
  if (search != null && search != 'pure') {
    return 'this tree was built by the $search search, which this reader '
        'does not have';
  }
  // Bounded builds keep a node's moves rather than all of them: our moves
  // are not the ones the loss window admits, and the opponent's shares stop
  // short of one on purpose. Both look exactly like a complete expansion in
  // the file, so a tree read as one would be quietly wrong everywhere.
  if (config['bounded_database'] == true) {
    return 'this tree was built by the bounded database mode, which keeps '
        'only some of each position\'s moves; build it again to open it here';
  }
  // Which side the repertoire is for decides the sign of every evaluation in
  // the file, and the horizon decides which leaves are finished. Guessing
  // either would turn a wrong file into a plausible tree: one read for the
  // wrong colour prefers the moves it should reject, and one read at the
  // wrong horizon reports an unfinished build as settled.
  if (config['play_as_white'] is! bool) {
    return 'this tree does not say which side it was built for';
  }
  if (config['max_depth'] is! num) {
    return 'this tree does not say how deep it was built';
  }
  return null;
}

/// The search the document says it was built by. The side and the horizon are
/// already known to be there; the rest default, because the C builder and the
/// old app each leave out what their mode does not use.
SearchConfig configFromSnapshot(Map<String, Object?> config) {
  final side = config['play_as_white'] == true ? Side.white : Side.black;
  final defaults = SearchConfig(side: side);
  final budget = config['max_nodes'];
  return SearchConfig(
    side: side,
    horizonPlies: _intOr(config['max_depth'], defaults.horizonPlies),
    lossLimitCp: _intOr(config['max_eval_loss_cp'], defaults.lossLimitCp),
    nodeBudget: budget is num && budget > 0 ? budget.toInt() : null,
  );
}

int _intOr(Object? value, int fallback) =>
    value is num ? value.toInt() : fallback;
